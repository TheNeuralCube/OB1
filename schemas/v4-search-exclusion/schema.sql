CREATE OR REPLACE FUNCTION public.match_thoughts(query_embedding vector, match_threshold double precision DEFAULT 0.7, match_count integer DEFAULT 10, filter jsonb DEFAULT '{}'::jsonb)
 RETURNS TABLE(id uuid, content text, metadata jsonb, similarity double precision, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    t.id,
    t.content,
    t.metadata,
    1 - (t.embedding <=> query_embedding) AS similarity,
    t.created_at
  FROM public.thoughts t
  WHERE 1 - (t.embedding <=> query_embedding) > match_threshold
    AND (filter = '{}'::jsonb OR t.metadata @> filter)
    AND CASE
      WHEN t.metadata IS NULL OR jsonb_typeof(t.metadata) <> 'object' THEN false
      WHEN t.metadata ? 'sensitivity'
           AND jsonb_typeof(t.metadata->'sensitivity') <> 'string' THEN false
      WHEN lower(btrim(t.metadata->>'sensitivity')) = 'restricted' THEN false
      WHEN strpos(lower(t.metadata::text), 'journal') > 0 THEN false
      ELSE true
    END
  ORDER BY t.embedding <=> query_embedding
  LIMIT match_count;
END;
$function$
