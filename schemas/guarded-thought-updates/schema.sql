-- Apply after ../thought-audit/schema.sql in the SAME transaction.
-- Requires the core updated_at trigger. No existing thought data is rewritten.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'public.thoughts'::regclass
      AND tgname = 'thoughts_updated_at' AND tgenabled = 'O'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'GUARD_PREREQUISITE: enabled thoughts_updated_at trigger required';
  END IF;
END;
$$;

-- Defeat inherited deployment defaults on the new audit relation. The pinned
-- upstream schema is unchanged; this companion layer enforces its stated intent.
REVOKE ALL ON public.thought_audit FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON public.thought_audit TO service_role;
COMMENT ON TABLE public.thought_audit IS
  'Transactional old-row audit on UPDATE and DELETE; failures abort the mutation. No capture trigger. Owner-controlled retention.';
COMMENT ON COLUMN public.thought_audit.diff IS
  'Full OLD thought row minus embedding. Re-embed content when restoring a deleted row.';

CREATE FUNCTION public.audit_thought_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.thought_audit
    (thought_id, action, source, author_session_id, diff, actor_context)
  VALUES
    (OLD.id, lower(TG_OP), OLD.metadata->>'source',
     OLD.metadata->>'author_session_id', to_jsonb(OLD) - 'embedding',
     jsonb_build_object('origin', 'trigger'));
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.audit_thought_change() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER thoughts_audit_before_change
BEFORE UPDATE OR DELETE ON public.thoughts
FOR EACH ROW EXECUTE FUNCTION public.audit_thought_change();

CREATE FUNCTION public.guard_thought_sensitivity()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public
AS $$
DECLARE
  old_tier text := OLD.metadata->>'sensitivity';
  new_tier text := NEW.metadata->>'sensitivity';
  old_rank integer := array_position(ARRAY['open','internal','confidential','restricted'], old_tier);
  new_rank integer := array_position(ARRAY['open','internal','confidential','restricted'], new_tier);
  declaration jsonb := NEW.metadata->'declassified';
  declared_at timestamptz;
BEGIN
  -- Legacy untagged rows never block an update. For tagged rows, reject unknown
  -- new tiers so a typo cannot evade the ordering. Missing/JSON-null is rank 0.
  IF old_tier IS NULL THEN RETURN NEW; END IF;
  IF old_tier IS NOT DISTINCT FROM new_tier THEN RETURN NEW; END IF;
  IF old_rank IS NULL OR (new_tier IS NOT NULL AND new_rank IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'SENSITIVITY_INVALID_TIER: expected open, internal, confidential or restricted';
  END IF;
  IF coalesce(new_rank, 0) >= old_rank THEN RETURN NEW; END IF;

  -- SQL NULL must fail closed. A missing target is represented by explicit
  -- JSON null in the declaration, not an absent "to" field.
  IF jsonb_typeof(declaration) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'SENSITIVITY_DOWNGRADE: valid declassified {from,to,reason,at} required';
  END IF;
  IF NOT (declaration ?& ARRAY['from','to','reason','at'])
     OR (SELECT count(*) FROM jsonb_object_keys(declaration)) <> 4
     OR declaration->'from' IS DISTINCT FROM to_jsonb(old_tier)
     OR declaration->'to' IS DISTINCT FROM coalesce(to_jsonb(new_tier), 'null'::jsonb)
     OR jsonb_typeof(declaration->'reason') IS DISTINCT FROM 'string'
     OR declaration->>'reason' !~ '[^[:space:]]'
     OR jsonb_typeof(declaration->'at') IS DISTINCT FROM 'string'
     OR declaration->>'at' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$'
  THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'SENSITIVITY_DOWNGRADE: valid declassified {from,to,reason,at} required';
  END IF;
  BEGIN
    declared_at := (declaration->>'at')::timestamptz;
  EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'SENSITIVITY_DOWNGRADE: invalid declassification timestamp';
  END;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_thought_sensitivity() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER thoughts_sensitivity_before_update
BEFORE UPDATE ON public.thoughts
FOR EACH ROW EXECUTE FUNCTION public.guard_thought_sensitivity();

REVOKE ALL ON public.thoughts FROM anon;

CREATE FUNCTION public.thought_census(p_key text, p_filter jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE result jsonb;
BEGIN
  IF p_key IS NULL OR length(btrim(p_key)) = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'CENSUS_INVALID_KEY: nonempty metadata key required';
  END IF;
  IF jsonb_typeof(p_filter) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'CENSUS_INVALID_FILTER: JSON object required';
  END IF;
  SELECT jsonb_build_object(
    'key', p_key, 'filter', p_filter,
    'total', coalesce(sum(n), 0),
    'groups', coalesce(jsonb_object_agg(bucket, n), '{}'::jsonb)
  ) INTO result FROM (
    SELECT coalesce(metadata ->> p_key, '(none)') AS bucket, count(*) AS n
    FROM public.thoughts
    WHERE metadata @> p_filter
    GROUP BY coalesce(metadata ->> p_key, '(none)')
  ) counts;
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.thought_census(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.thought_census(text,jsonb) TO service_role;
NOTIFY pgrst, 'reload schema';
