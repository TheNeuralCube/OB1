-- ARTIFICIAL DATABASE ONLY. Requires core thoughts plus the reviewed bundle.
-- Each assertion raises on failure. The transaction rolls back every fixture.
BEGIN;
DO $$ BEGIN
  IF EXISTS (SELECT FROM public.thoughts) THEN
    RAISE EXCEPTION 'Tests require an EMPTY disposable thoughts table';
  END IF;
END; $$;

INSERT INTO public.thoughts (id, content, embedding, metadata)
VALUES ('00000000-0000-4000-8000-000000000001', 'Artificial guarded record', '[1,2]',
        '{"sensitivity":"restricted","source":"synthetic","author_session_id":"test-session"}');

SET LOCAL ROLE service_role;
UPDATE public.thoughts SET content = 'Artificial revised record'
WHERE id = '00000000-0000-4000-8000-000000000001';
RESET ROLE;
DO $$ DECLARE a public.thought_audit; BEGIN
  SELECT * INTO STRICT a FROM public.thought_audit;
  ASSERT a.action = 'update' AND a.source = 'synthetic';
  ASSERT a.author_session_id = 'test-session';
  ASSERT a.actor_context = '{"origin":"trigger"}'::jsonb;
  ASSERT a.diff->>'content' = 'Artificial guarded record';
  ASSERT NOT (a.diff ? 'embedding');
  ASSERT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(a.diff) k) =
    (SELECT array_agg(attname::text ORDER BY attname::text) FROM pg_catalog.pg_attribute
     WHERE attrelid='public.thoughts'::regclass AND attnum>0 AND NOT attisdropped AND attname<>'embedding');
END; $$;

-- Role enforcement, including inherited default audit-table grants.
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE',
    'TRUNCATE','REFERENCES','TRIGGER','MAINTAIN']) p WHERE has_table_privilege('anon','public.thoughts',p));
  ASSERT NOT has_table_privilege('service_role','public.thought_audit','UPDATE');
  ASSERT NOT has_table_privilege('service_role','public.thought_audit','DELETE');
  ASSERT NOT has_table_privilege('service_role','public.thought_audit','TRUNCATE');
  ASSERT NOT has_table_privilege('authenticated','public.thought_audit','SELECT');
  ASSERT NOT has_function_privilege('anon','public.thought_census(text,jsonb)','EXECUTE');
  ASSERT NOT has_function_privilege('authenticated','public.thought_census(text,jsonb)','EXECUTE');
  ASSERT NOT has_function_privilege('service_role','public.audit_thought_change()','EXECUTE');
END; $$;
SET LOCAL ROLE anon;
DO $$ BEGIN
  BEGIN
    UPDATE public.thoughts SET content = 'must not land' WHERE id = '00000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'Anon update unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM public.thought_census('sensitivity');
    RAISE EXCEPTION 'Anon census unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END; $$;
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.thought_audit) = 1; END; $$;

-- Every ordered tier transition; missing-key removal is below even open.
DO $$ DECLARE old_tier text; new_tier text; fixture uuid; before_audit bigint; BEGIN
  FOREACH old_tier IN ARRAY ARRAY['open','internal','confidential','restricted'] LOOP
    FOREACH new_tier IN ARRAY ARRAY['open','internal','confidential','restricted',NULL] LOOP
      INSERT INTO public.thoughts(content,metadata)
        VALUES ('Artificial tier matrix', jsonb_build_object('sensitivity',old_tier)) RETURNING id INTO fixture;
      SELECT count(*) INTO before_audit FROM public.thought_audit;
      IF coalesce(array_position(ARRAY['open','internal','confidential','restricted'],new_tier),0)
         < array_position(ARRAY['open','internal','confidential','restricted'],old_tier) THEN
        BEGIN
          UPDATE public.thoughts SET metadata = CASE WHEN new_tier IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('sensitivity',new_tier) END WHERE id = fixture;
          RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'Downgrade accepted';
        EXCEPTION WHEN SQLSTATE 'P0001' THEN
          ASSERT SQLERRM LIKE 'SENSITIVITY_DOWNGRADE:%';
        END;
        ASSERT (SELECT count(*) FROM public.thought_audit) = before_audit;
        UPDATE public.thoughts SET metadata = jsonb_build_object('sensitivity',new_tier,
          'declassified',jsonb_build_object('from',old_tier,'to',new_tier,'reason','Artificial approval','at','2026-01-01T00:00:00Z'))
        WHERE id = fixture;
      ELSE
        UPDATE public.thoughts SET metadata = jsonb_build_object('sensitivity',new_tier) WHERE id = fixture;
      END IF;
      ASSERT (SELECT count(*) FROM public.thought_audit) = before_audit + 1;
    END LOOP;
  END LOOP;
END; $$;

-- Absent, null, scalar, incomplete, stale-from, wrong-to and malformed flags.
DO $$ DECLARE flag jsonb; bad jsonb; fixture uuid; BEGIN
  INSERT INTO public.thoughts(content,metadata) VALUES ('Artificial flag checks','{"sensitivity":"restricted"}') RETURNING id INTO fixture;
  FOREACH flag IN ARRAY ARRAY[
    'null'::jsonb, 'true'::jsonb, '[]'::jsonb, '{}'::jsonb,
    '{"from":"confidential","to":"internal","reason":"test","at":"2026-01-01T00:00:00Z"}'::jsonb,
    '{"from":"restricted","to":"open","reason":"test","at":"2026-01-01T00:00:00Z"}'::jsonb,
    '{"from":"restricted","to":"internal","reason":" ","at":"2026-01-01T00:00:00Z"}'::jsonb,
    '{"from":"restricted","to":"internal","reason":"\t\n","at":"2026-01-01T00:00:00Z"}'::jsonb,
    '{"from":"restricted","to":"internal","reason":null,"at":"2026-01-01T00:00:00Z"}'::jsonb,
    '{"from":"restricted","to":"internal","reason":"test","at":"not-a-date"}'::jsonb,
    '{"from":"restricted","to":"internal","reason":"test","at":"2026-99-01T00:00:00Z"}'::jsonb,
    '{"from":"restricted","to":"internal","reason":"test","at":"2026-01-01T00:00:00Z","extra":true}'::jsonb
  ] LOOP
    BEGIN
      UPDATE public.thoughts SET metadata = jsonb_build_object('sensitivity','internal','declassified',flag) WHERE id=fixture;
      RAISE EXCEPTION USING ERRCODE='ZX001', MESSAGE='Invalid flag accepted';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN ASSERT SQLERRM LIKE 'SENSITIVITY_DOWNGRADE:%'; END;
  END LOOP;
  FOREACH bad IN ARRAY ARRAY['null'::jsonb,'[]'::jsonb,'{"sensitivity":null}'::jsonb,'{"sensitivity":"typo"}'::jsonb] LOOP
    BEGIN
      UPDATE public.thoughts SET metadata=bad WHERE id=fixture;
      RAISE EXCEPTION USING ERRCODE='ZX001', MESSAGE='Invalid metadata accepted';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN ASSERT SQLERRM LIKE 'SENSITIVITY_%'; END;
  END LOOP;
  UPDATE public.thoughts SET metadata='{"sensitivity":"confidential","declassified":{"from":"restricted","to":"confidential","reason":"test","at":"2026-01-01T00:00:00Z"}}' WHERE id=fixture;
  BEGIN
    UPDATE public.thoughts SET metadata=jsonb_set(metadata,'{sensitivity}','"internal"') WHERE id=fixture;
    RAISE EXCEPTION USING ERRCODE='ZX001', MESSAGE='Stale declaration reused';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN ASSERT SQLERRM LIKE 'SENSITIVITY_DOWNGRADE:%'; END;
END; $$;

-- Untagged legacy rows do not block. Inserts do not produce audit records.
DO $$ DECLARE fixture uuid; before_audit bigint; BEGIN
  SELECT count(*) INTO before_audit FROM public.thought_audit;
  INSERT INTO public.thoughts(content,metadata) VALUES ('Artificial legacy record','{}') RETURNING id INTO fixture;
  ASSERT (SELECT count(*) FROM public.thought_audit)=before_audit;
  UPDATE public.thoughts SET metadata='{"sensitivity":"internal"}' WHERE id=fixture;
  ASSERT (SELECT count(*) FROM public.thought_audit)=before_audit+1;
END; $$;

-- Definer trigger succeeds even when its caller cannot insert audit rows.
REVOKE INSERT ON public.thought_audit FROM service_role;
SET LOCAL ROLE service_role;
UPDATE public.thoughts SET content='Artificial definer test' WHERE id='00000000-0000-4000-8000-000000000001';
RESET ROLE;
GRANT INSERT ON public.thought_audit TO service_role;

-- Audit failure aborts the thought change instead of losing history.
ALTER TABLE public.thought_audit ADD CONSTRAINT artificial_audit_failure CHECK (action <> 'update') NOT VALID;
DO $$ BEGIN
  BEGIN
    UPDATE public.thoughts SET content='must roll back' WHERE id='00000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION USING ERRCODE='ZX001', MESSAGE='Audit failure allowed update';
  EXCEPTION WHEN check_violation THEN NULL; END;
  ASSERT (SELECT content FROM public.thoughts WHERE id='00000000-0000-4000-8000-000000000001')='Artificial definer test';
END; $$;
ALTER TABLE public.thought_audit DROP CONSTRAINT artificial_audit_failure;

-- Host owner delete leaves a complete old-row audit without embedding.
DELETE FROM public.thoughts WHERE id='00000000-0000-4000-8000-000000000001';
DO $$ BEGIN
  ASSERT EXISTS (SELECT FROM public.thought_audit WHERE thought_id='00000000-0000-4000-8000-000000000001'
    AND action='delete' AND diff->>'content'='Artificial definer test' AND NOT diff ? 'embedding');
END; $$;

-- More rows AND distinct buckets than the REST row cap, nested containment,
-- malicious-looking keys as values, empty results, and RLS invoker semantics.
INSERT INTO public.thoughts(content,metadata)
SELECT 'Artificial census record '||g,
  jsonb_build_object('suite','census','supersedes',gen_random_uuid(),'nested',jsonb_build_object('a',1),
    'sensitivity',CASE WHEN g<=1205 THEN 'internal' ELSE NULL END)
FROM generate_series(1,1210) g;
INSERT INTO public.thoughts(content,metadata) VALUES ('Artificial missing key','{"suite":"census","nested":{"a":1}}');
SET LOCAL ROLE service_role;
DO $$ DECLARE c jsonb; BEGIN
  c:=public.thought_census('sensitivity','{"suite":"census","nested":{"a":1}}');
  ASSERT (c->>'total')::integer=1211;
  ASSERT (c->'groups'->>'internal')::integer=1205;
  ASSERT (c->'groups'->>'(none)')::integer=6;
  ASSERT (c->>'missing')::integer=6;
  c:=public.thought_census('supersedes','{"suite":"census"}');
  ASSERT (SELECT count(*) FROM jsonb_object_keys(c->'groups'))=1211;
  c:=public.thought_census('x''; SELECT 1; --','{"suite":"census"}');
  ASSERT (c->'groups'->>'(none)')::integer=1211;
  c:=public.thought_census('project','{"suite":"absent"}');
  ASSERT c->'groups'='{}'::jsonb AND (c->>'total')::integer=0;
  ASSERT (c->>'missing')::integer=0;
  BEGIN
    PERFORM public.thought_census('key','null');
    RAISE EXCEPTION USING ERRCODE='ZX001', MESSAGE='Null filter accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END; $$;
RESET ROLE;
-- SQL NULL joins the empty-filter population. Display collisions are not missing.
INSERT INTO public.thoughts(content,metadata) VALUES
  ('Artificial SQL-null metadata',NULL),
  ('Artificial absent census key','{"suite":"collisions"}'),
  ('Artificial JSON-null census key','{"suite":"collisions","collision":null}'),
  ('Artificial literal none','{"suite":"collisions","collision":"(none)"}'),
  ('Artificial number','{"suite":"collisions","collision":1}'),
  ('Artificial numeric string','{"suite":"collisions","collision":"1"}'),
  ('Artificial boolean','{"suite":"collisions","collision":true}'),
  ('Artificial boolean string','{"suite":"collisions","collision":"true"}');
SET LOCAL ROLE service_role;
DO $$ DECLARE c jsonb; expected_groups jsonb; BEGIN
  c:=public.thought_census('collision');
  ASSERT (c->>'total')::bigint=(SELECT count(*) FROM public.thoughts);
  ASSERT (c->>'missing')::bigint=(SELECT count(*) FROM public.thoughts WHERE metadata->>'collision' IS NULL);
  SELECT jsonb_object_agg(bucket,n) INTO expected_groups FROM (
    SELECT coalesce(metadata->>'collision','(none)') bucket,count(*) n FROM public.thoughts GROUP BY 1
  ) independent_counts;
  ASSERT c->'groups'=expected_groups;
  ASSERT (c->'groups'->>'(none)')::bigint=(c->>'missing')::bigint+1;
  c:=public.thought_census('collision','{"suite":"collisions"}');
  ASSERT c->'groups'='{"(none)":3,"1":2,"true":2}'::jsonb;
  ASSERT (c->>'total')::integer=7 AND (c->>'missing')::integer=2;
  ASSERT NOT EXISTS (SELECT FROM public.thoughts WHERE metadata IS NULL AND coalesce(metadata,'{}'::jsonb) @> '{"suite":"collisions"}'::jsonb);
END; $$;
RESET ROLE;
-- Temporarily grant execute for this test only: invoker must still obey RLS.
GRANT EXECUTE ON FUNCTION public.thought_census(text,jsonb) TO authenticated;
SET LOCAL ROLE authenticated;
DO $$ BEGIN ASSERT (public.thought_census('sensitivity')->>'total')::integer=0; END; $$;
RESET ROLE;
ROLLBACK;
SELECT 'PASS: audit, guards, roles, rollback and census (artificial SQL)' AS result;
