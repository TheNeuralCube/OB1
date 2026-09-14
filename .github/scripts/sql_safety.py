"""Conservative lexical SQL policy. Never executes SQL; uncertain dynamic SQL fails closed."""
from pathlib import Path
import re,sys

def tokens(sql):
    out=[]; statement=[]; bodies=0; depth=0; i=0
    def routine():
        lead=statement[:]
        if lead[:3]==['CREATE','OR','REPLACE']:lead=lead[:1]+lead[3:]
        return lead[:2] in (['CREATE','FUNCTION'],['CREATE','PROCEDURE'])
    def body_context():
        return statement[:1]==['DO'] or (routine() and depth==0 and 'AS' in statement)
    def finish_statement():
        if statement[:1]!=['DO'] and not routine():return
        languages=[statement[n+1] if n+1<len(statement) else None for n,t in enumerate(statement) if t=='LANGUAGE']
        if bodies!=1 or len(languages)>1 or (routine() and not languages):
            raise ValueError('unsupported DO/routine body grammar requires manual SQL review')
        for language in languages:
            if language not in ('SQL','PLPGSQL',('IDENT','sql'),('IDENT','plpgsql')):
                raise ValueError('unsupported routine language requires manual SQL review')
    def emit(token):
        out.append(token);statement.append(token)
    while i<len(sql):
        if sql[i].isspace(): i+=1; continue
        if sql.startswith('--',i):
            end=sql.find('\n',i);i=len(sql) if end<0 else end+1;continue
        if sql.startswith('/*',i):
            comment_depth=1;i+=2
            while i<len(sql) and comment_depth:
                if sql.startswith('/*',i): comment_depth+=1;i+=2
                elif sql.startswith('*/',i): comment_depth-=1;i+=2
                else:i+=1
            if comment_depth:raise ValueError('unterminated comment')
            continue
        if sql[i] in "'\"":
            # Deliberately reject all escape/unicode prefixed literals, including
            # benign data and bodies without backslashes. Decoding is not guessed.
            if out and (out[-1]=='E' or out[-2:]==['U','&']):
                raise ValueError('E/e and U& prefixed strings/identifiers require manual SQL review')
            quote=sql[i];i+=1;value='';closed=False
            while i<len(sql):
                if sql[i]==quote:
                    if i+1<len(sql) and sql[i+1]==quote:value+=quote;i+=2;continue
                    i+=1;closed=True;break
                # Fail closed on escape strings: no ambiguity over literal boundaries.
                if sql[i]=='\\' and quote=="'" and out and out[-1]=='E':
                    raise ValueError('escape string requires manual SQL review')
                value+=sql[i];i+=1
            if not closed:raise ValueError('unterminated literal/identifier')
            if quote=='"':emit(('IDENT',value))
            elif body_context():
                out.extend(tokens(value));statement.append('<body>');bodies+=1
            else:emit('<literal>')
            continue
        dollar=re.match(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$',sql[i:])
        if dollar:
            tag=dollar.group();start=i+len(tag);end=sql.find(tag,start)
            if end<0:raise ValueError('unterminated dollar block')
            # Dollar bodies are inspected conservatively even if used as data.
            out.extend(tokens(sql[start:end]))
            if body_context():statement.append('<body>');bodies+=1
            else:statement.append('<literal>')
            i=end+len(tag);continue
        word=re.match(r'[A-Za-z_][A-Za-z_0-9$]*',sql[i:])
        if word:emit(word.group().upper());i+=len(word.group());continue
        if sql[i]==';':
            finish_statement();out.append(';');statement=[];bodies=0;depth=0
        else:
            if sql[i]=='(':depth+=1
            elif sql[i]==')':depth-=1
            emit(sql[i])
        i+=1
    finish_statement()
    return out

def issues(sql):
    try:t=tokens(sql)
    except ValueError as e:return [str(e)]
    errors=[]
    for i,word in enumerate(t):
        nxt=t[i+1] if i+1<len(t) else ''
        if word=='TRUNCATE' or (word=='DROP' and nxt in ('TABLE','DATABASE')):
            errors.append('destructive SQL token outside data literals')
        trigger_call=nxt in ('FUNCTION','PROCEDURE') and t[max(0,i-3):i] in (['FOR','EACH','ROW'],['FOR','EACH','STATEMENT'])
        privilege=nxt=='ON' and i>0 and t[i-1] in ('GRANT','REVOKE')
        if word=='EXECUTE' and not (trigger_call or privilege):
            errors.append('dynamic/prepared EXECUTE requires manual review; static safety cannot be proved')
        if word=='DELETE' and nxt=='FROM':
            depth=0;qualified=False
            for x in t[i+2:]:
                if x==';' and depth==0:break
                if x==')':
                    if depth==0:break
                    depth-=1
                elif x=='(':depth+=1
                elif x=='WHERE' and depth==0:qualified=True
            if not qualified:errors.append('DELETE FROM without a same-level WHERE')
        if word=='ALTER' and nxt=='TABLE':
            j=i+2
            if t[j:j+2]==['IF','EXISTS']:j+=2
            if j<len(t) and t[j]=='ONLY':j+=1
            def named(token,name):return token==name.upper() or token==('IDENT',name)
            if j+1<len(t) and named(t[j],'public') and t[j+1]=='.':j+=2
            if j<len(t) and named(t[j],'thoughts'):
                end=t.index(';',j) if ';' in t[j:] else len(t)
                clause=t[j+1:end]
                depth=0
                for k,token in enumerate(clause):
                    if token=='(':depth+=1
                    elif token==')':depth-=1
                    if depth or token not in ('DROP','ALTER','RENAME'):continue
                    following=clause[k+1:]
                    if not following:errors.append('incomplete core table alteration');continue
                    # COLUMN is optional. Quoted names are identifiers even when
                    # their text is constraint/trigger/rule, so they are rejected.
                    if following[0] in ('CONSTRAINT','TRIGGER','RULE'):continue
                    if token=='RENAME' and following[0]=='TO':continue # table rename, not a column
                    errors.append('existing thoughts column modification (COLUMN may be omitted)')
    return sorted(set(errors))

if __name__=='__main__':
    failures=issues(Path(sys.argv[1]).read_text(encoding='utf-8'))
    for error in failures:print(error)
    raise SystemExit(bool(failures))
