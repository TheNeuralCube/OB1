-- SYNTHETIC DATABASE ONLY: empty thoughts table, vector(1536), and the candidate function.
-- Run with psql -X -v ON_ERROR_STOP=1 -f tests.sql. Fixtures always roll back.
-- The unchanged baseline must fail T1-T5 while every C control passes.
\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
  IF EXISTS (SELECT FROM public.thoughts) THEN
    RAISE EXCEPTION 'Tests require an EMPTY disposable thoughts table';
  END IF;
  IF (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
      WHERE attrelid = 'public.thoughts'::regclass AND attname = 'embedding') <> 'vector(1536)' THEN
    RAISE EXCEPTION 'Tests require vector(1536)';
  END IF;
END; $$;

CREATE TEMP TABLE checks (name text PRIMARY KEY, passed boolean NOT NULL) ON COMMIT DROP;
CREATE FUNCTION pg_temp.check_result(label text, condition boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
  INSERT INTO checks VALUES (label, coalesce(condition, false));
  RAISE NOTICE '%: %', label, CASE WHEN coalesce(condition, false) THEN 'PASS' ELSE 'FAIL' END;
END; $$;
CREATE FUNCTION pg_temp.vec(x real, y real) RETURNS vector
LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY[x, y] || array_fill(0::real, ARRAY[1534]))::vector(1536)
$$;
CREATE FUNCTION pg_temp.fixture_id(n integer) RETURNS uuid
LANGUAGE sql IMMUTABLE AS $$
  SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;
CREATE TEMP TABLE fixtures (n integer PRIMARY KEY, metadata jsonb, embedding vector(1536)) ON COMMIT DROP;

-- X1: SQL NULL and every non-object JSON type.
INSERT INTO fixtures SELECT n, metadata, pg_temp.vec(1, 0) FROM (VALUES
  (1, NULL::jsonb), (2, 'null'::jsonb), (3, '[]'::jsonb),
  (4, '"synthetic"'::jsonb), (5, '42'::jsonb), (6, 'true'::jsonb)
) AS rows(n, metadata);
-- X2: present sensitivity with every non-string JSON type.
INSERT INTO fixtures SELECT n, metadata, pg_temp.vec(1, 0) FROM (VALUES
  (11, '{"sensitivity":null}'::jsonb), (12, '{"sensitivity":3}'::jsonb),
  (13, '{"sensitivity":[]}'::jsonb), (14, '{"sensitivity":{}}'::jsonb),
  (15, '{"sensitivity":true}'::jsonb)
) AS rows(n, metadata);
-- X3: exact spelling and case/space normalization.
INSERT INTO fixtures SELECT n, metadata, pg_temp.vec(1, 0) FROM (VALUES
  (21, '{"sensitivity":"restricted"}'::jsonb),
  (22, '{"sensitivity":" ReStRiCtEd "}'::jsonb)
) AS rows(n, metadata);
-- X4: tags, another value, a key, and a nested mixed-case value.
INSERT INTO fixtures SELECT n, metadata, pg_temp.vec(1, 0) FROM (VALUES
  (31, '{"tags":["journal"]}'::jsonb),
  (32, '{"source":"JoUrNaL-import"}'::jsonb),
  (33, '{"JournalIndex":false}'::jsonb),
  (34, '{"nested":{"note":"synthetic JOURNAL marker"}}'::jsonb)
) AS rows(n, metadata);

-- Eligible controls have lower similarity than every excluded candidate.
INSERT INTO fixtures VALUES
  (101, '{}', pg_temp.vec(1, 0.5)),
  (102, '{"sensitivity":"internal","topic":"eligible"}', pg_temp.vec(0.8, 0.6)),
  (103, '{"sensitivity":"open","topic":"eligible"}', pg_temp.vec(0.6, 0.8)),
  (104, '{"topic":"orthogonal"}', pg_temp.vec(0, 1)),
  (105, '{"topic":"opposite"}', pg_temp.vec(-1, 0)),
  (106, '{"topic":"null-vector"}', NULL),
  (107, '{"sensitivity":"not-restricted"}', pg_temp.vec(0, 1)),
  (108, '{"sensitivity":""}', pg_temp.vec(0, 1)),
  (109, '{"sensitivity":"confidential","details":{"safe":true}}', pg_temp.vec(0, 1));
INSERT INTO fixtures
SELECT 201 + i, '{"sensitivity":"open","topic":"limit-control"}'::jsonb,
       pg_temp.vec(1, (20 + i)::real)
FROM generate_series(0, 11) AS series(i);
INSERT INTO public.thoughts (id, content, metadata, embedding, created_at)
SELECT pg_temp.fixture_id(n), 'SYNTHETIC fixture ' || n, metadata, embedding,
       '2026-01-01 00:00:00+00'::timestamptz
FROM fixtures;

-- Materialize actual function output once; no implementation predicate in the oracle.
CREATE TEMP TABLE hits ON COMMIT DROP AS
SELECT * FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{}');
SELECT pg_temp.check_result('T1-X1', NOT EXISTS (
  SELECT FROM hits WHERE id IN (SELECT pg_temp.fixture_id(n) FROM fixtures WHERE n BETWEEN 1 AND 6)));
SELECT pg_temp.check_result('T2-X2', NOT EXISTS (
  SELECT FROM hits WHERE id IN (SELECT pg_temp.fixture_id(n) FROM fixtures WHERE n BETWEEN 11 AND 15)));
SELECT pg_temp.check_result('T3-X3', NOT EXISTS (
  SELECT FROM hits WHERE id IN (pg_temp.fixture_id(21), pg_temp.fixture_id(22))));
SELECT pg_temp.check_result('T4-X4', NOT EXISTS (
  SELECT FROM hits WHERE id IN (SELECT pg_temp.fixture_id(n) FROM fixtures WHERE n BETWEEN 31 AND 34)));
SELECT pg_temp.check_result('T5-filter-bypass-and-before-limit',
  NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{"sensitivity":"restricted"}'))
  AND NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{"tags":["journal"]}'))
  AND NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{"sensitivity":null}'))
  AND NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{"source":"JoUrNaL-import"}'))
  AND NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, 'null'))
  AND NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '42'))
  AND (SELECT id FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1, '{}')) = pg_temp.fixture_id(101));

SELECT pg_temp.check_result('C01-fixture-count-and-types',
  (SELECT count(*) FROM public.thoughts) = 38
  AND (SELECT count(*) FROM fixtures WHERE metadata IS NULL) = 1
  AND (SELECT count(*) FROM fixtures WHERE jsonb_typeof(metadata) = 'null') = 1
  AND (SELECT count(*) FROM fixtures WHERE embedding IS NULL) = 1);
SELECT pg_temp.check_result('C02-safe-empty-object', EXISTS (SELECT FROM hits WHERE id = pg_temp.fixture_id(101)));
SELECT pg_temp.check_result('C03-ordinary-string',
  (SELECT array_agg(id) FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{"sensitivity":"internal"}'))
  = ARRAY[pg_temp.fixture_id(102)]);
SELECT pg_temp.check_result('C04-nested-containment',
  (SELECT array_agg(id) FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{"details":{"safe":true}}'))
  = ARRAY[pg_temp.fixture_id(109)]);
SELECT pg_temp.check_result('C05-filtered-ranking',
  (SELECT array_agg(id) FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{"topic":"eligible"}'))
  = ARRAY[pg_temp.fixture_id(102), pg_temp.fixture_id(103)]);
SELECT pg_temp.check_result('C06-empty-filter-eligible-set',
  (SELECT array_agg(id ORDER BY id) FROM hits
   WHERE id >= pg_temp.fixture_id(101) AND id <= pg_temp.fixture_id(109))
  = ARRAY[pg_temp.fixture_id(101), pg_temp.fixture_id(102), pg_temp.fixture_id(103),
          pg_temp.fixture_id(104), pg_temp.fixture_id(107), pg_temp.fixture_id(108), pg_temp.fixture_id(109)]);
SELECT pg_temp.check_result('C07-return-types-and-values',
  (SELECT bool_and(pg_typeof(id)::text = 'uuid' AND pg_typeof(content)::text = 'text'
    AND pg_typeof(metadata)::text = 'jsonb' AND pg_typeof(similarity)::text = 'double precision'
    AND pg_typeof(created_at)::text = 'timestamp with time zone'
    AND content = 'SYNTHETIC fixture 102' AND created_at = '2026-01-01 00:00:00+00'::timestamptz
    AND abs(similarity - 0.8) < 0.000001)
   FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{"sensitivity":"internal"}')));
SELECT pg_temp.check_result('C08-null-filter',
  NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, NULL::jsonb)));
SELECT pg_temp.check_result('C09-null-threshold',
  NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), NULL::double precision, 1000, '{}')));
SELECT pg_temp.check_result('C10-null-query-vector',
  NOT EXISTS (SELECT FROM public.match_thoughts(NULL::vector, -1, 1000, '{}')));
SELECT pg_temp.check_result('C11-strict-threshold-boundary',
  NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), 0, 1000, '{"topic":"orthogonal"}'))
  AND (SELECT count(*) FROM public.match_thoughts(pg_temp.vec(1, 0), -0.01, 1000, '{"topic":"orthogonal"}')) = 1);
SELECT pg_temp.check_result('C12-limit-one-and-zero',
  (SELECT array_agg(id) FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1, '{"topic":"eligible"}'))
  = ARRAY[pg_temp.fixture_id(102)]
  AND NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 0, '{"topic":"eligible"}')));
SELECT pg_temp.check_result('C13-default-threshold',
  (SELECT array_agg(id) FROM public.match_thoughts(pg_temp.vec(1, 0), filter => '{"topic":"eligible"}'))
  = ARRAY[pg_temp.fixture_id(102)]);
SELECT pg_temp.check_result('C14-default-and-null-limit',
  (SELECT count(*) FROM public.match_thoughts(pg_temp.vec(1, 0), match_threshold => -1, filter => '{"topic":"limit-control"}')) = 10
  AND (SELECT count(*) FROM public.match_thoughts(pg_temp.vec(1, 0), -1, NULL::integer, '{"topic":"limit-control"}')) = 12);
SELECT pg_temp.check_result('C15-no-eligible-hits',
  NOT EXISTS (SELECT FROM public.match_thoughts(pg_temp.vec(1, 0), -1, 1000, '{"topic":"absent"}')));
SELECT pg_temp.check_result('C16-null-embedding-and-opposite-threshold',
  NOT EXISTS (SELECT FROM hits WHERE id IN (pg_temp.fixture_id(105), pg_temp.fixture_id(106))));
SELECT pg_temp.check_result('C17-empty-and-nonrestricted-strings',
  (SELECT count(*) FROM hits WHERE id IN (pg_temp.fixture_id(107), pg_temp.fixture_id(108))) = 2);

SELECT name, passed FROM checks ORDER BY name;
SELECT count(*) AS total, count(*) FILTER (WHERE passed) AS passed,
       count(*) FILTER (WHERE NOT passed) AS failed FROM checks;
DO $$ DECLARE failures integer; BEGIN
  SELECT count(*) INTO failures FROM checks WHERE NOT passed;
  IF failures <> 0 THEN
    RAISE EXCEPTION 'EXCLUSION_ASSERTIONS_FAILED: %', failures;
  END IF;
END; $$;
ROLLBACK;
