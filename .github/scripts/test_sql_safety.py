import unittest
from sql_safety import issues

class SQLSafety(unittest.TestCase):
    def test_parameter_comment_preserves_parenthesis_depth(self):
        accepted="CREATE FUNCTION f(x text /* id */ DEFAULT 'ok') RETURNS void LANGUAGE plpgsql AS $$ BEGIN NULL; END $$;"
        rejected="CREATE FUNCTION f(x text /* id */ DEFAULT 'ok') RETURNS void LANGUAGE plpgsql AS $$ BEGIN TRUNCATE thoughts; END $$;"
        self.assertEqual(issues(accepted), [])
        self.assertIn('destructive SQL token outside data literals', issues(rejected))

    def test_statement_scope_bodies(self):
        rejected=[
          "DO LANGUAGE plpgsql 'BEGIN TRUNCATE public.thoughts; END';",
          "do language PlPgSqL 'begin truncate thoughts; end';",
          "DO LANGUAGE \"plpgsql\" 'BEGIN TRUNCATE thoughts; END';",
          "DO /* comment */ LANGUAGE\nplpgsql\n'BEGIN TRUNCATE thoughts; END';",
          "DO 'BEGIN TRUNCATE thoughts; END' LANGUAGE plpgsql;",
          "CREATE FUNCTION f() RETURNS void LANGUAGE plpgsql AS 'BEGIN TRUNCATE thoughts; END';",
          "CREATE OR REPLACE PROCEDURE p() LANGUAGE plpgsql AS 'BEGIN TRUNCATE thoughts; END';",
          "CREATE FUNCTION f() RETURNS void AS 'BEGIN TRUNCATE thoughts; END' LANGUAGE plpgsql;",
          "DO LANGUAGE unknown_lang 'benign body';",
          "CREATE FUNCTION f() RETURNS text LANGUAGE c AS 'library', 'symbol';",
          "CREATE FUNCTION f() RETURNS int LANGUAGE SQL BEGIN ATOMIC SELECT 1; END;",
          "DO LANGUAGE 'plpgsql' 'BEGIN NULL; END';",
        ]
        for sql in rejected:
            with self.subTest(sql=sql):self.assertTrue(issues(sql))
        for sql in ["DO LANGUAGE plpgsql 'BEGIN NULL; END';",
                    "DO 'BEGIN NULL; END' LANGUAGE \"plpgsql\";",
                    "CREATE FUNCTION f(x text DEFAULT 'ordinary data') RETURNS text LANGUAGE sql AS 'SELECT x';",
                    "CREATE OR REPLACE PROCEDURE p() LANGUAGE plpgsql AS 'BEGIN NULL; END';",
                    "SELECT language, 'TRUNCATE thoughts' FROM example;",
                    "SELECT 'DO LANGUAGE plpgsql', 'CREATE FUNCTION';"]:
            with self.subTest(sql=sql):self.assertEqual(issues(sql),[])

    def test_table_if_exists(self):
        for sql in ['ALTER TABLE IF EXISTS public.thoughts DROP COLUMN content;',
                    'ALTER TABLE IF EXISTS ONLY thoughts DROP content;',
                    'ALTER TABLE IF EXISTS ONLY "public"."thoughts" DROP COLUMN IF EXISTS content;',
                    'ALTER TABLE IF EXISTS thoughts ALTER content TYPE text;',
                    'ALTER TABLE IF EXISTS thoughts RENAME content TO other;']:
            with self.subTest(sql=sql):self.assertTrue(issues(sql))
        for sql in ['ALTER TABLE IF EXISTS public.thoughts DROP CONSTRAINT example;',
                    'ALTER TABLE IF EXISTS ONLY thoughts ENABLE TRIGGER example;',
                    'ALTER TABLE IF EXISTS thoughts DISABLE RULE example;']:
            with self.subTest(sql=sql):self.assertEqual(issues(sql),[])

    def test_escape_unicode_fail_closed(self):
        for prefix in ['E','e','U&','u&']:
            for body in ['BEGIN TRUNCATE thoughts; END','BEGIN RETURN; END']:
                with self.subTest(prefix=prefix,body=body):
                    self.assertTrue(issues(f"CREATE FUNCTION f() RETURNS void AS {prefix}'{body}' LANGUAGE plpgsql;"))
                    self.assertTrue(issues(f"DO {prefix}'{body}';"))
            self.assertTrue(issues(f"SELECT {prefix}'benign data';"))
        self.assertEqual(issues("SELECT 'E prefix is ordinary data', 'U& is ordinary data';"),[])
        self.assertEqual(issues("SELECT example, e FROM source;"),[])
        self.assertTrue(issues('ALTER TABLE U&"public".thoughts DROP content;'))

    def test_quoted_identifiers_are_not_verbs(self):
        for sql in ['CREATE TABLE example ("truncate" text, "drop" text);',
                    'ALTER TABLE example RENAME COLUMN a TO "drop";',
                    'SELECT "delete", "where", "execute" FROM example;',
                    'ALTER TABLE "Thoughts" DROP content;']:
            with self.subTest(sql=sql):self.assertEqual(issues(sql),[])
        for sql in ['TRUNCATE "truncate";', 'DROP TABLE "drop";',
                    'DELETE FROM thoughts "where";', 'ALTER TABLE "public"."thoughts" DROP "constraint";']:
            with self.subTest(sql=sql):self.assertTrue(issues(sql))

    def test_optional_column_and_controls(self):
        for sql in ['ALTER TABLE public.thoughts DROP content;',
                    'ALTER TABLE thoughts DROP IF EXISTS content;',
                    'ALTER TABLE thoughts ALTER content TYPE jsonb;',
                    'ALTER TABLE thoughts RENAME content TO other;',
                    'ALTER TABLE ONLY "public"."thoughts" DROP COLUMN IF EXISTS "content";',
                    'ALTER TABLE thoughts DROP CONSTRAINT old, DROP content;',
                    'ALTER TABLE thoughts ALTER "rule" TYPE text;']:
            with self.subTest(sql=sql):self.assertTrue(issues(sql))
        for sql in ['ALTER TABLE thoughts DROP CONSTRAINT example;',
                    'ALTER TABLE thoughts ALTER CONSTRAINT example DEFERRABLE;',
                    'ALTER TABLE thoughts RENAME CONSTRAINT example TO next_example;',
                    'ALTER TABLE thoughts ENABLE TRIGGER example;',
                    'ALTER TABLE thoughts DISABLE RULE example;',
                    'ALTER TRIGGER example ON thoughts RENAME TO next_example;',
                    'ALTER RULE example ON thoughts RENAME TO next_example;']:
            with self.subTest(sql=sql):self.assertEqual(issues(sql),[])

    def test_accepted(self):
        for sql in ["SELECT has_table_privilege('anon','public.thoughts','TRUNCATE');",
                    "DO $$ BEGIN ASSERT NOT has_table_privilege('anon','t','TRUNCATE'); END; $$;",
                    "-- DROP TABLE t\nSELECT 'TRUNCATE'; /* nested /* DELETE FROM t */ comment */",
                    "DELETE FROM public.thoughts\nWHERE id='example';",
                    "CREATE TRIGGER t BEFORE UPDATE ON thoughts FOR EACH ROW EXECUTE FUNCTION audit();",
                    "GRANT EXECUTE ON FUNCTION census(text) TO service_role;",
                    "ALTER TABLE public.thoughts ADD COLUMN example text;",
                    "ALTER TABLE thoughts DROP CONSTRAINT example;",
                    "SELECT 'it''s TRUNCATE';"]:
            with self.subTest(sql=sql):self.assertEqual(issues(sql),[])
    def test_rejected(self):
        for sql in ['TRUNCATE\nthoughts;', 'SELECT 1; TRUNCATE TABLE thoughts;',
                    'DROP /*comment*/ TABLE thoughts;', 'DROP\nDATABASE example;',
                    'DO $body$ BEGIN TRUNCATE thoughts; END; $body$;',
                    "CREATE FUNCTION x() RETURNS void AS 'BEGIN TRUNCATE thoughts; END' LANGUAGE plpgsql;",
                    "DO $$ BEGIN EXECUTE 'TRUN' || 'CATE thoughts'; END; $$;",
                    'DO $$ BEGIN EXECUTE format(command_from_table); END; $$;',
                    'DO $$ BEGIN EXECUTE function || suffix; END; $$;',
                    "DELETE FROM thoughts; SELECT 'WHERE';",'DELETE FROM thoughts /*WHERE id=1*/;',
                    'WITH removed AS (DELETE FROM thoughts RETURNING *) SELECT * FROM removed;',
                    'DELETE FROM thoughts USING (SELECT * FROM other WHERE id=1) other;',
                    'ALTER TABLE public.thoughts ALTER COLUMN content TYPE jsonb;',
                    'ALTER TABLE ONLY "public"."thoughts" DROP COLUMN content;',
                    'ALTER TABLE thoughts RENAME COLUMN content TO other;',
                    "DO $$ BEGIN EXECUTE E'TRUNCATE\\nthoughts'; END; $$;",'/* unterminated',"SELECT 'unterminated"]:
            with self.subTest(sql=sql):self.assertTrue(issues(sql))

if __name__=='__main__':unittest.main()
