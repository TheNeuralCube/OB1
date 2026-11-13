-- ============================================================
-- Hybrid search v5: match_thoughts_v5 (additive, flag-gated, v4 untouched)
--
-- Adds:
--   1. thoughts.content_tsv  generated full-text column (simple + english)
--   2. thoughts_content_tsv_idx  GIN index on it
--   3. thoughts_safe_date_v5(text)  helper: a date or NULL, never an error
--   4. match_thoughts_v5(...)  vector + lexical search fused by reciprocal rank,
--      bounded recency, and a FIXED fail-closed exclusion inside the function:
--        X1 metadata is NULL or not a JSON object
--        X2 a sensitivity key is present but is not a JSON string
--        X3 lower(btrim(sensitivity)) = 'restricted'
--        X4 the word "journal" appears anywhere in lower(metadata::text)
--      The exclusion is applied BEFORE both legs rank, pool and fuse. No parameter and no
--      filter value can turn it off. Over-exclusion (a row that merely mentions the word) is
--      accepted: it is the safe direction.
--
-- Nothing existing is dropped, renamed or rewritten. match_thoughts (v4) is not changed.
-- Safe to run more than once.
-- ============================================================

SET search_path TO public, extensions;

ALTER TABLE public.thoughts
  ADD COLUMN IF NOT EXISTS content_tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('simple', content) || to_tsvector('english', content)) STORED;

CREATE INDEX IF NOT EXISTS thoughts_content_tsv_idx
  ON public.thoughts USING gin (content_tsv);

-- A bad date string must fall back to created_at, never raise an error.
CREATE OR REPLACE FUNCTION public.thoughts_safe_date_v5(p_text text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, extensions
AS $$
BEGIN
  RETURN p_text::date;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.match_thoughts_v5(
  query_text      text,
  query_embedding vector,
  match_threshold double precision DEFAULT 0.7,
  match_count     integer          DEFAULT 10,
  filter          jsonb            DEFAULT '{}',
  use_recency     boolean          DEFAULT true,
  pool_size       integer          DEFAULT 50
)
RETURNS TABLE (
  id         uuid,
  content    text,
  metadata   jsonb,
  similarity double precision,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, extensions
AS $$
  WITH
  p AS (
    SELECT greatest(coalesce(pool_size, 50), 1) AS ps
  ),
  -- One eligible set that BOTH legs select from, before ranking, the pool LIMIT and fusion.
  eligible AS (
    SELECT t.id, t.content, t.metadata, t.embedding, t.created_at, t.content_tsv
    FROM public.thoughts t
    WHERE NOT (
      -- BEGIN EXCLUSION X1-X4 (fail-closed; the seed script uses this exact text)
      t.metadata IS NULL
      OR jsonb_typeof(t.metadata) <> 'object'
      OR (t.metadata ? 'sensitivity' AND jsonb_typeof(t.metadata -> 'sensitivity') <> 'string')
      OR coalesce(lower(btrim(t.metadata ->> 'sensitivity')) = 'restricted', false)
      OR strpos(lower(t.metadata::text), 'journal') > 0
      -- END EXCLUSION X1-X4
    )
    -- The caller filter narrows the eligible set; it can never widen it.
    AND (coalesce(filter, '{}'::jsonb) = '{}'::jsonb OR t.metadata @> filter)
  ),
  vec AS (
    SELECT e.id,
           row_number() OVER (ORDER BY e.embedding <=> query_embedding, e.id) AS r
    FROM eligible e, p
    WHERE e.embedding IS NOT NULL
    ORDER BY e.embedding <=> query_embedding, e.id
    LIMIT (SELECT ps FROM p)
  ),
  q AS (
    SELECT CASE
             WHEN btrim(coalesce(query_text, '')) = '' THEN NULL::tsquery
             ELSE websearch_to_tsquery('simple', query_text) || websearch_to_tsquery('english', query_text)
           END AS tsq
  ),
  lex AS (
    SELECT e.id,
           row_number() OVER (ORDER BY ts_rank_cd(e.content_tsv, q.tsq) DESC, e.id) AS r
    FROM eligible e, q
    WHERE q.tsq IS NOT NULL AND e.content_tsv @@ q.tsq
    ORDER BY ts_rank_cd(e.content_tsv, q.tsq) DESC, e.id
    LIMIT (SELECT ps FROM p)
  ),
  fused AS (
    SELECT coalesce(v.id, l.id) AS id,
           coalesce(1.0 / (60 + v.r), 0) + coalesce(1.0 / (60 + l.r), 0) AS rrf,
           (l.id IS NOT NULL) AS has_lex
    FROM vec v
    FULL OUTER JOIN lex l ON l.id = v.id
  ),
  scored AS (
    SELECT e.id, e.content, e.metadata, e.created_at, f.rrf, f.has_lex,
           CASE WHEN e.embedding IS NULL THEN 0::double precision
                ELSE 1 - (e.embedding <=> query_embedding) END AS sim,
           greatest(0, extract(epoch FROM (now() - coalesce(
             public.thoughts_safe_date_v5(e.metadata ->> 'last_verified')::timestamptz, e.created_at))) / 86400.0) AS age_days,
           (   e.metadata ->> 'evidence_type' = 'operator_ruling'
            OR e.metadata ->> 'type' = 'rule'
            OR (e.metadata ->> 'subtype' ~* 'ruling|rule'
                AND e.metadata ->> 'subtype' !~* 'pending|unruled|proposed|lean|recommendation|awaiting|request|owed|expectation|not-')
            OR (jsonb_typeof(e.metadata -> 'tags') = 'array'
                AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(e.metadata -> 'tags') tg(v)
                            WHERE tg.v IN ('ruling', 'rulings', 'his ruling', 'operator ruling',
                                           'operator-ruling', 'standing rule', 'standing-rule')))
           ) AS is_ruling
    FROM fused f
    JOIN eligible e ON e.id = f.id
  )
  SELECT s.id, s.content, s.metadata, s.sim AS similarity, s.created_at
  FROM scored s
  WHERE s.sim >= match_threshold OR s.has_lex
  ORDER BY s.rrf * (CASE WHEN coalesce(use_recency, true) AND NOT coalesce(s.is_ruling, false)
                         THEN 0.85 + 0.15 * exp(-ln(2.0) * s.age_days / 90.0)
                         ELSE 1.0 END) DESC,
           s.sim DESC,
           s.id
  LIMIT greatest(coalesce(match_count, 10), 0)
$$;
