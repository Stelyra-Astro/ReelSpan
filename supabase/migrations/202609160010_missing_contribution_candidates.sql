-- Browse films requiring a story time or place, without admitting edits to the live tables.
CREATE OR REPLACE FUNCTION public.reelspan_missing_films(p_category text DEFAULT 'place_no_time',p_limit integer DEFAULT 30,p_offset integer DEFAULT 0)
RETURNS TABLE(movie_qid text,title text,tmdb_id bigint,imdb_id text,has_time boolean,has_place boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
 SELECT sm.movie_qid,coalesce(nullif(md.title,''),nullif(md.original_title,''),sm.movie_qid),
 sm.tmdb_id,sm.imdb_id,
 EXISTS(SELECT 1 FROM public.story_movie_periods t WHERE t.movie_qid=sm.movie_qid AND t.is_deleted=false AND (t.start_year IS NOT NULL OR t.end_year IS NOT NULL)),
 EXISTS(SELECT 1 FROM public.story_movie_locations p WHERE p.movie_qid=sm.movie_qid AND p.is_deleted=false AND p.raw_place_qid IS NOT NULL)
 FROM public.story_movies sm LEFT JOIN public.movies md ON md.tmdb_id=sm.tmdb_id
 WHERE sm.is_deleted=false AND p_category IN ('time_no_place','place_no_time','neither')
 AND (CASE p_category
 WHEN 'time_no_place' THEN
     EXISTS(SELECT 1 FROM public.story_movie_periods t WHERE t.movie_qid=sm.movie_qid AND t.is_deleted=false AND (t.start_year IS NOT NULL OR t.end_year IS NOT NULL))
     AND NOT EXISTS(SELECT 1 FROM public.story_movie_locations p WHERE p.movie_qid=sm.movie_qid AND p.is_deleted=false AND p.raw_place_qid IS NOT NULL)
 WHEN 'place_no_time' THEN
     NOT EXISTS(SELECT 1 FROM public.story_movie_periods t WHERE t.movie_qid=sm.movie_qid AND t.is_deleted=false AND (t.start_year IS NOT NULL OR t.end_year IS NOT NULL))
     AND EXISTS(SELECT 1 FROM public.story_movie_locations p WHERE p.movie_qid=sm.movie_qid AND p.is_deleted=false AND p.raw_place_qid IS NOT NULL)
 ELSE NOT EXISTS(SELECT 1 FROM public.story_movie_periods t WHERE t.movie_qid=sm.movie_qid AND t.is_deleted=false AND (t.start_year IS NOT NULL OR t.end_year IS NOT NULL))
     AND NOT EXISTS(SELECT 1 FROM public.story_movie_locations p WHERE p.movie_qid=sm.movie_qid AND p.is_deleted=false AND p.raw_place_qid IS NOT NULL)
 END)
 ORDER BY sm.legacy_id LIMIT greatest(1,least(coalesce(p_limit,30),50)) OFFSET greatest(0,least(coalesce(p_offset,0),100000));
$fn$;
REVOKE ALL ON FUNCTION public.reelspan_missing_films(text,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_missing_films(text,integer,integer) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.reelspan_missing_counts()
RETURNS TABLE(category text,film_count integer) LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
 WITH counts AS (SELECT sm.movie_qid,
 EXISTS(SELECT 1 FROM public.story_movie_periods t WHERE t.movie_qid=sm.movie_qid AND t.is_deleted=false AND (t.start_year IS NOT NULL OR t.end_year IS NOT NULL)) ht,
 EXISTS(SELECT 1 FROM public.story_movie_locations p WHERE p.movie_qid=sm.movie_qid AND p.is_deleted=false AND p.raw_place_qid IS NOT NULL) hp
 FROM public.story_movies sm WHERE sm.is_deleted=false)
 SELECT 'time_no_place'::text, count(*) filter(where ht AND NOT hp)::integer FROM counts UNION ALL
 SELECT 'place_no_time', count(*) filter(where hp AND NOT ht)::integer FROM counts UNION ALL
 SELECT 'neither', count(*) filter(where NOT ht AND NOT hp)::integer FROM counts;
$fn$;
REVOKE ALL ON FUNCTION public.reelspan_missing_counts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_missing_counts() TO anon,authenticated;
