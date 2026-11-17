-- ARTIFICIAL DATABASE ONLY. Requires an EMPTY disposable core thoughts table (id, content,
-- embedding vector, metadata jsonb, created_at), pgvector, v4 match_thoughts, and schema.sql
-- from this folder. Every fixture is synthetic. The transaction rolls everything back.
--
-- Run:  psql -v ON_ERROR_STOP=1 -f tests.sql
-- Output: one line per test (PASS or FAIL), then a non-zero exit if any test failed.
--
-- Tests are fail-first: the exclusion tests (X1-X4, filter, pool slot) fail on a function that
-- lacks the section 3a exclusion; the control tests (matcher, fusion, recency) must pass either way.
BEGIN;
SET LOCAL search_path TO public, extensions;
-- Test helpers call match_thoughts_v5; skip body checks so a missing function is a test FAIL, not a setup error.
SET LOCAL check_function_bodies = off;
DO $$ BEGIN
  IF EXISTS (SELECT FROM public.thoughts) THEN
    RAISE EXCEPTION 'Tests require an EMPTY disposable thoughts table';
  END IF;
END; $$;

CREATE TEMP TABLE test_results (name text, ok boolean, detail text);
CREATE TEMP TABLE fx (label text PRIMARY KEY, id uuid DEFAULT gen_random_uuid());

-- 2-dimension direction padded to 1536 dimensions (the core column width).
CREATE FUNCTION pg_temp.e(x float8, y float8) RETURNS vector LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY[x, y] || array_fill(0::float8, ARRAY[1534]))::float8[]::vector
$$;
CREATE PROCEDURE pg_temp.ins(lbl text, txt text, emb vector, meta jsonb,
                             made timestamptz DEFAULT now()) LANGUAGE sql AS $$
  WITH f AS (INSERT INTO fx (label) VALUES (lbl) RETURNING id)
  INSERT INTO public.thoughts (id, content, embedding, metadata, created_at)
  SELECT f.id, txt, emb, meta, made FROM f
$$;
CREATE FUNCTION pg_temp.fid(lbl text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM fx WHERE label = lbl $$;
CREATE FUNCTION pg_temp.fids(VARIADIC lbls text[]) RETURNS uuid[] LANGUAGE sql AS
  $$ SELECT coalesce(array_agg(id), '{}') FROM fx WHERE label = ANY (lbls) $$;
CREATE FUNCTION pg_temp.v5ids(qt text, qe vector, thr float8 DEFAULT 0.7, cnt int DEFAULT 50,
                              f jsonb DEFAULT '{}', rec boolean DEFAULT true, ps int DEFAULT 50)
RETURNS uuid[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg(r.id ORDER BY o), '{}')
  FROM public.match_thoughts_v5(qt, qe, thr, cnt, f, rec, ps) WITH ORDINALITY AS r(id, content, metadata, similarity, created_at, o)
$$;
CREATE FUNCTION pg_temp.rec(n text, ok boolean, d text DEFAULT '') RETURNS void LANGUAGE sql AS
  $$ INSERT INTO test_results VALUES (n, coalesce(ok, false), d) $$;

-- ---- Group A: exclusion fixtures (all share the word zebra and the query direction) ----
-- Eligible controls sit slightly BELOW the excluded rows on cosine, so an unfiltered pool would
-- fill with excluded rows first.
CALL pg_temp.ins('E1', 'zebra eligible, no sensitivity key', pg_temp.e(1, 0.1), '{}');
CALL pg_temp.ins('E2', 'zebra eligible, internal',            pg_temp.e(1, 0.1), '{"sensitivity":"internal"}');
CALL pg_temp.ins('E3', 'zebra eligible, plain tags',          pg_temp.e(1, 0.1), '{"tags":["alpha"],"sensitivity":"open"}');
-- X1: metadata NULL or not a JSON object
CALL pg_temp.ins('X1a', 'zebra x1 null',    pg_temp.e(1, 0), NULL);
CALL pg_temp.ins('X1b', 'zebra x1 array',   pg_temp.e(1, 0), '[]');
CALL pg_temp.ins('X1c', 'zebra x1 string',  pg_temp.e(1, 0), '"text"');
CALL pg_temp.ins('X1d', 'zebra x1 number',  pg_temp.e(1, 0), '3');
-- X2: sensitivity present but not a string
CALL pg_temp.ins('X2a', 'zebra x2 array',   pg_temp.e(1, 0), '{"sensitivity":["restricted"]}');
CALL pg_temp.ins('X2b', 'zebra x2 null',    pg_temp.e(1, 0), '{"sensitivity":null}');
CALL pg_temp.ins('X2c', 'zebra x2 number',  pg_temp.e(1, 0), '{"sensitivity":5}');
CALL pg_temp.ins('X2d', 'zebra x2 object',  pg_temp.e(1, 0), '{"sensitivity":{"v":"restricted"}}');
-- X3: restricted after lower() and btrim()
CALL pg_temp.ins('X3a', 'zebra x3 exact',   pg_temp.e(1, 0), '{"sensitivity":"restricted"}');
CALL pg_temp.ins('X3b', 'zebra x3 case and space', pg_temp.e(1, 0), '{"sensitivity":" Restricted "}');
CALL pg_temp.ins('X3c', 'zebra x3 upper',   pg_temp.e(1, 0), '{"sensitivity":"RESTRICTED"}');
-- X4: the word journal anywhere in metadata text, any case, keys or values, nested
CALL pg_temp.ins('X4a', 'zebra x4 tag',     pg_temp.e(1, 0), '{"tags":["journal"]}');
CALL pg_temp.ins('X4b', 'zebra x4 source',  pg_temp.e(1, 0), '{"source":"journal-import"}');
CALL pg_temp.ins('X4c', 'zebra x4 key',     pg_temp.e(1, 0), '{"Journal":1}');
CALL pg_temp.ins('X4d', 'zebra x4 nested',  pg_temp.e(1, 0), '{"a":{"b":"My JOURNAL entry"}}');

-- Each exclusion test also asserts the eligible controls ARE returned, so a function that
-- errors or returns nothing cannot pass.
DO $$ DECLARE r uuid[]; BEGIN
  r := pg_temp.v5ids('zebra', pg_temp.e(1, 0), 0.0);
  PERFORM pg_temp.rec('X1 null or non-object metadata is excluded',
    NOT (r && pg_temp.fids('X1a','X1b','X1c','X1d')) AND r @> pg_temp.fids('E1','E2','E3'),
    'returned=' || cardinality(r));
  PERFORM pg_temp.rec('X2 non-string sensitivity is excluded',
    NOT (r && pg_temp.fids('X2a','X2b','X2c','X2d')) AND r @> pg_temp.fids('E1','E2','E3'));
  PERFORM pg_temp.rec('X3 restricted after lower and btrim is excluded',
    NOT (r && pg_temp.fids('X3a','X3b','X3c')) AND r @> pg_temp.fids('E1','E2','E3'));
  PERFORM pg_temp.rec('X4 journal anywhere in metadata is excluded',
    NOT (r && pg_temp.fids('X4a','X4b','X4c','X4d')) AND r @> pg_temp.fids('E1','E2','E3'));
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.rec('X1 null or non-object metadata is excluded', false, SQLERRM);
  PERFORM pg_temp.rec('X2 non-string sensitivity is excluded', false, SQLERRM);
  PERFORM pg_temp.rec('X3 restricted after lower and btrim is excluded', false, SQLERRM);
  PERFORM pg_temp.rec('X4 journal anywhere in metadata is excluded', false, SQLERRM);
END; $$;

-- A filter value cannot re-include an excluded row (containment is applied AFTER the exclusion).
DO $$ DECLARE r uuid[]; f jsonb; bad boolean := false; fl text := ''; BEGIN
  FOREACH f IN ARRAY ARRAY['{"sensitivity":"restricted"}', '{"sensitivity":" Restricted "}',
                           '{"tags":["journal"]}', '{"source":"journal-import"}',
                           '{"sensitivity":["restricted"]}', '{"Journal":1}']::jsonb[] LOOP
    r := pg_temp.v5ids('zebra', pg_temp.e(1, 0), 0.0, 50, f);
    IF cardinality(r) > 0 THEN bad := true; fl := fl || f::text || ' '; END IF;
  END LOOP;
  PERFORM pg_temp.rec('filter cannot re-include an excluded row', NOT bad, 'leaked for filter ' || fl);
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.rec('filter cannot re-include an excluded row', false, SQLERRM);
END; $$;

-- Excluded rows never take a pool slot: with pool_size 3 the 16 excluded rows (higher cosine)
-- must not crowd the 3 eligible rows out of either leg.
DO $$ DECLARE r uuid[]; BEGIN
  r := pg_temp.v5ids('zebra', pg_temp.e(1, 0), 0.0, 50, '{}', true, 3);
  PERFORM pg_temp.rec('excluded rows never take a pool slot',
    r @> pg_temp.fids('E1','E2','E3') AND cardinality(r) = 3, 'returned=' || cardinality(r));
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.rec('excluded rows never take a pool slot', false, SQLERRM);
END; $$;

-- ---- Group B: controls that must pass with or without the exclusion ----
-- Lexical-only hit under the cosine threshold (the v4 deficit this build fixes).
CALL pg_temp.ins('L1', 'plain note about ABC-123 handling', pg_temp.e(0, 1), '{"grp":"lex"}');
CALL pg_temp.ins('L2', 'unrelated gardening text',          pg_temp.e(0, 1), '{"grp":"lex"}');
DO $$ DECLARE v5 uuid[]; v4 uuid[]; BEGIN
  v5 := pg_temp.v5ids('ABC-123', pg_temp.e(1, 0), 0.7, 50, '{"grp":"lex"}');
  SELECT coalesce(array_agg(m.id), '{}') INTO v4 FROM public.match_thoughts(pg_temp.e(1, 0), 0.7, 50, '{"grp":"lex"}') m;
  PERFORM pg_temp.rec('control: v4 misses the exact-token row under the threshold', NOT (v4 @> pg_temp.fids('L1')));
  PERFORM pg_temp.rec('control: v5 returns the lexical-only row under the threshold', v5 @> pg_temp.fids('L1'));
  PERFORM pg_temp.rec('control: v5 drops a row with low cosine and no lexical hit', NOT (v5 @> pg_temp.fids('L2')));
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.rec('control: v5 returns the lexical-only row under the threshold', false, SQLERRM);
END; $$;

-- Exact-token forms named in the design note (default parser must not break them).
CALL pg_temp.ins('T1', 'card ABC-123 closed',                pg_temp.e(0, 1), '{"grp":"tok"}');
CALL pg_temp.ins('T2', 'commit 3f9a1c0e merged',             pg_temp.e(0, 1), '{"grp":"tok"}');
CALL pg_temp.ins('T3', 'runs sample_git_watch.py in a loop',    pg_temp.e(0, 1), '{"grp":"tok"}');
CALL pg_temp.ins('T4', 'tag v1.2.9 released',                pg_temp.e(0, 1), '{"grp":"tok"}');
CALL pg_temp.ins('T5', 'upgrade to widget-kit 0.6.0 ok', pg_temp.e(0, 1), '{"grp":"tok"}');
DO $$ DECLARE q record; r uuid[]; BEGIN
  FOR q IN SELECT * FROM (VALUES ('ABC-123','T1'), ('3f9a1c0e','T2'), ('sample_git_watch.py','T3'),
                                 ('v1.2.9','T4'), ('widget-kit 0.6.0','T5')) v(tok, lbl) LOOP
    r := pg_temp.v5ids(q.tok, pg_temp.e(1, 0), 0.7, 5, '{"grp":"tok"}');
    PERFORM pg_temp.rec('lexical leg alone finds token ' || q.tok, r @> pg_temp.fids(q.lbl), 'returned=' || cardinality(r));
  END LOOP;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.rec('lexical leg alone finds token (error)', false, SQLERRM);
END; $$;

-- Empty query text: vector leg only, no error. Result count and cosine value.
DO $$ DECLARE n int; s float8; want float8; BEGIN
  SELECT count(*) INTO n FROM public.match_thoughts_v5('', pg_temp.e(1, 0), 0.7, 50, '{"grp":"lex"}');
  PERFORM pg_temp.rec('control: empty query text runs and uses the vector leg only', n = 0, 'rows=' || n);
  SELECT m.similarity INTO s FROM public.match_thoughts_v5('zebra', pg_temp.e(1, 0), 0.0, 50, '{}') m WHERE m.id = pg_temp.fid('E1');
  want := 1 - (pg_temp.e(1, 0.1) <=> pg_temp.e(1, 0));
  PERFORM pg_temp.rec('control: similarity stays the cosine value', abs(s - want) < 1e-9, 's=' || s || ' want=' || want);
  SELECT count(*) INTO n FROM public.match_thoughts_v5('zebra', pg_temp.e(1, 0), 0.0, 2);
  PERFORM pg_temp.rec('control: match_count is honored', n = 2, 'rows=' || n);
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.rec('control: empty query / similarity / match_count', false, SQLERRM);
END; $$;

-- ---- Group C: bounded recency (all rows: same text, same embedding) ----
-- Ids are chosen so that a pure tie breaks to the OLD row, so "new first" can only come from recency.
INSERT INTO fx (label, id) VALUES
  ('R_old',  '00000000-0000-4000-8000-0000000000a1'),
  ('R_rule', '00000000-0000-4000-8000-0000000000a2'),
  ('R_ref',  '00000000-0000-4000-8000-0000000000a3'),
  ('R_bad',  '00000000-0000-4000-8000-0000000000a4'),
  ('R_prop', '00000000-0000-4000-8000-0000000000a5'),
  ('R_opr',  '00000000-0000-4000-8000-0000000000a6'),
  ('R_sub',  '00000000-0000-4000-8000-0000000000a7'),
  ('R_new',  '00000000-0000-4000-8000-0000000000b1');
INSERT INTO public.thoughts (id, content, embedding, metadata, created_at)
SELECT pg_temp.fid(l), 'quokka recency probe', pg_temp.e(1, 0), m::jsonb, c FROM (VALUES
  ('R_old',  '{"grp":"rec"}',                                     now() - interval '400 days'),
  ('R_rule', '{"grp":"rec","evidence_type":"operator_ruling"}',   now() - interval '400 days'),
  ('R_ref',  '{"grp":"rec","type":"reference"}',                  now() - interval '400 days'),
  ('R_bad',  '{"grp":"rec","last_verified":"not-a-date"}',        now() - interval '1 days'),
  ('R_prop', '{"grp":"rec","subtype":"Proposed rule"}',           now() - interval '400 days'),
  ('R_opr',  '{"grp":"rec","subtype":"Operator Ruling"}',          now() - interval '400 days'),
  ('R_sub',  '{"grp":"rec","subtype":"ruling"}',                   now() - interval '400 days'),
  ('R_new',  '{"grp":"rec"}',                                     now())) v(l, m, c);
DO $$ DECLARE on_ids uuid[]; off_ids uuid[]; BEGIN
  on_ids  := pg_temp.v5ids('quokka', pg_temp.e(1, 0), 0.0, 50, '{"grp":"rec"}', true);
  off_ids := pg_temp.v5ids('quokka', pg_temp.e(1, 0), 0.0, 50, '{"grp":"rec"}', false);
  PERFORM pg_temp.rec('recency off: pure tie breaks by id (old row first)', off_ids[1] = pg_temp.fid('R_old'));
  PERFORM pg_temp.rec('recency on: newer row ranks above the older twin', array_position(on_ids, pg_temp.fid('R_new')) < array_position(on_ids, pg_temp.fid('R_old')));
  PERFORM pg_temp.rec('recency on: a ruling is exempt and stays first among equals', on_ids[1] = pg_temp.fid('R_rule'));
  PERFORM pg_temp.rec('recency on: a reference is NOT exempt', array_position(on_ids, pg_temp.fid('R_new')) < array_position(on_ids, pg_temp.fid('R_ref')));
  -- M1: the subtype patterns are case-insensitive on both the positive and the negative side.
  PERFORM pg_temp.rec('recency on: subtype "Proposed rule" is NOT exempt (negative list is case-insensitive)', array_position(on_ids, pg_temp.fid('R_new')) < array_position(on_ids, pg_temp.fid('R_prop')));
  PERFORM pg_temp.rec('recency on: subtype "Operator Ruling" IS exempt (positive pattern is case-insensitive)', array_position(on_ids, pg_temp.fid('R_opr')) < array_position(on_ids, pg_temp.fid('R_new')));
  PERFORM pg_temp.rec('control: lowercase subtype "ruling" is exempt', array_position(on_ids, pg_temp.fid('R_sub')) < array_position(on_ids, pg_temp.fid('R_new')));
  PERFORM pg_temp.rec('recency on: a bad last_verified falls back and does not error', on_ids @> pg_temp.fids('R_bad'));
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.rec('recency group', false, SQLERRM);
END; $$;

-- ---- Report ----
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM test_results ORDER BY ok, name;
DO $$ DECLARE n_fail int; n_all int; BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO n_fail, n_all FROM test_results;
  RAISE NOTICE 'tests=% failed=%', n_all, n_fail;
  IF n_fail > 0 THEN RAISE EXCEPTION '% of % tests failed', n_fail, n_all; END IF;
END; $$;
ROLLBACK;
