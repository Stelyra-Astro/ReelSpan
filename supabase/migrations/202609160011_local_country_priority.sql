-- Preserve the existing RPC signature for released clients. New clients pass p_sort='country:<QID>'.
-- Relevance remains primary for an explicit text query; regional preference breaks ties.
DO $migration$
DECLARE definition text; prioritized text;
BEGIN
 definition := pg_get_functiondef('public.reelatlas_discover(text,integer,integer,text,text,text,text,text,integer,integer)'::regprocedure);
 IF position('s.legacy_id ASC' IN definition)=0 OR position('c.legacy_id ASC' IN definition)=0 THEN
    RAISE EXCEPTION 'Discovery query changed; inspect sort before applying regional priority';
 END IF;
 prioritized := replace(definition, 's.legacy_id ASC',
  $$CASE WHEN p_sort LIKE 'country:%' THEN EXISTS(
    SELECT 1 FROM public.story_movie_locations local_place
    WHERE local_place.movie_qid=s.movie_qid AND local_place.is_deleted=false
    AND local_place.country_qid=substring(p_sort from 9)) ELSE false END DESC,s.legacy_id ASC$$);
 prioritized := replace(prioritized, 'c.legacy_id ASC',
  $$CASE WHEN p_sort LIKE 'country:%' THEN EXISTS(
    SELECT 1 FROM public.story_movie_locations local_place
    WHERE local_place.movie_qid=c.movie_qid AND local_place.is_deleted=false
    AND local_place.country_qid=substring(p_sort from 9)) ELSE false END DESC,c.legacy_id ASC$$);
 EXECUTE prioritized;
END;
$migration$;
