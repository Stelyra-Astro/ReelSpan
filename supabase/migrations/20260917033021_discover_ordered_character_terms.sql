-- Explicitly order adjacency; equivalent to regexp_split_to_table's current sequence.
CREATE OR REPLACE FUNCTION reelspan_private.short_search_terms(input_text text) RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT SET search_path='' AS $terms$
 WITH chars AS MATERIALIZED (
 SELECT c,lead(c) OVER (ORDER BY ordinal) following
 FROM regexp_split_to_table(input_text,'') WITH ORDINALITY AS pieces(c,ordinal)
 )
 SELECT coalesce(array_agg(DISTINCT token),'{}'::text[]) FROM (
 SELECT c token FROM chars
 UNION ALL SELECT c||following FROM chars WHERE following IS NOT NULL
 ) tokens;
$terms$;
