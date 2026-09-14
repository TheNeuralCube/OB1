"""Exact reviewed fork bundle; no broad server-directory exception."""
import os,sys
FILES=frozenset(['server/index.ts','server/census.test.ts',
 'schemas/guarded-thought-updates/schema.sql','schemas/guarded-thought-updates/tests.sql',
 'schemas/guarded-thought-updates/README.md','schemas/guarded-thought-updates/metadata.json'])
def allowed(repository,head_repository,head_ref,files):
    return repository==head_repository=='TheNeuralCube/OB1' and head_ref=='feat/ob1-hub-mods' and set(files)==FILES
if __name__=='__main__':
    raise SystemExit(0 if allowed(os.environ.get('GITHUB_REPOSITORY'),os.environ.get('PR_HEAD_REPOSITORY'),os.environ.get('PR_HEAD_REF'),os.environ.get('CHANGED_FILES','').splitlines()) else 1)
