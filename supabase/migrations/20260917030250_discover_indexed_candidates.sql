-- Candidate-first search; preserve the actual released ranking and filter rules.
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
ALTER TABLE public.movies ADD COLUMN IF NOT EXISTS reelspan_discover_text text
  GENERATED ALWAYS AS (lower(coalesce(title,'') || E'\n' || coalesce(original_title,'') || E'\n' || coalesce(genres::text,'') || E'\n' || coalesce(director::text,'') || E'\n' || coalesce(cast_members::text,'') || E'\n' || coalesce(overview,''))) STORED;
ALTER TABLE public.reelatlas_search_index ADD COLUMN IF NOT EXISTS reelspan_discover_text text
  GENERATED ALWAYS AS (period_search || E'\n' || place_search) STORED;
CREATE INDEX IF NOT EXISTS idx_reelspan_metadata_search_trgm ON public.movies USING gin (reelspan_discover_text extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_reelspan_story_search_trgm ON public.reelatlas_search_index USING gin (reelspan_discover_text extensions.gin_trgm_ops);
CREATE OR REPLACE FUNCTION public.reelatlas_discover_search(p_query text DEFAULT ''::text, p_start_year integer DEFAULT NULL::integer, p_end_year integer DEFAULT NULL::integer, p_concept_qid text DEFAULT NULL::text, p_place_qid text DEFAULT NULL::text, p_country_qid text DEFAULT NULL::text, p_genre text DEFAULT NULL::text, p_sort text DEFAULT 'recommended'::text, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
 RETURNS TABLE(movie_qid text, legacy_id bigint, tmdb_id bigint, imdb_id text, title text, overview text, release_date date, genres jsonb, match_score integer, match_reason text, time_ranges jsonb, story_locations jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
WITH input AS (SELECT lower(trim(left(coalesce(p_query,''),80))) q,greatest(1,least(coalesce(p_limit,20),50)) page_size,greatest(0,least(coalesce(p_offset,0),100000)) page_start, '%' || replace(replace(replace(lower(trim(left(coalesce(p_query,''),80))), chr(92), chr(92)||chr(92)), '%', chr(92)||'%'), '_', chr(92)||'_') || '%' pattern),
selected AS (SELECT c.concept_qid,c.start_year,c.end_year FROM public.story_time_concepts c CROSS JOIN input i WHERE c.is_deleted=false AND ((p_concept_qid IS NOT NULL AND c.concept_qid=p_concept_qid) OR (p_concept_qid IS NULL AND i.q<>'' AND (lower(c.name_en)=i.q OR lower(c.name_zh)=i.q OR EXISTS(SELECT 1 FROM jsonb_each_text(c.labels) a WHERE lower(a.value)=i.q)))) ORDER BY CASE WHEN c.concept_qid=p_concept_qid THEN 0 ELSE 1 END,c.concept_qid LIMIT 1),
tagged AS MATERIALIZED (SELECT DISTINCT t.movie_qid FROM public.story_movie_concept_tags t JOIN selected s ON s.concept_qid=t.concept_qid WHERE t.is_deleted=false),
contemporaries AS MATERIALIZED (SELECT DISTINCT mp.movie_qid FROM public.story_movie_periods mp JOIN selected s ON s.start_year IS NOT NULL AND s.end_year IS NOT NULL AND mp.start_year<=s.end_year AND mp.end_year>=s.start_year WHERE mp.is_deleted=false),
candidates AS MATERIALIZED (
 SELECT sm.movie_qid FROM public.story_movies sm CROSS JOIN input i
 WHERE i.q='' AND p_concept_qid IS NULL AND sm.is_deleted=false
   AND (p_country_qid IS NULL OR sm.movie_qid IN (
     SELECT ml.movie_qid FROM public.story_movie_locations ml
     WHERE ml.country_qid=p_country_qid AND ml.is_deleted=false))
 UNION
 SELECT idx.movie_qid FROM public.reelatlas_search_index idx CROSS JOIN input i
 WHERE i.q<>'' AND idx.reelspan_discover_text LIKE i.pattern ESCAPE chr(92)
 UNION
 SELECT sm.movie_qid FROM public.movies md CROSS JOIN input i
 JOIN public.story_movies sm ON sm.tmdb_id=md.tmdb_id AND sm.is_deleted=false
 WHERE i.q<>'' AND md.reelspan_discover_text LIKE i.pattern ESCAPE chr(92)
 UNION
 SELECT sm.movie_qid FROM public.story_movies sm CROSS JOIN input i
 WHERE i.q<>'' AND lower(sm.movie_qid)=i.q
 UNION SELECT movie_qid FROM tagged
 UNION SELECT movie_qid FROM contemporaries
),
scored AS (SELECT sm.movie_qid,sm.legacy_id,sm.tmdb_id,sm.imdb_id,coalesce(nullif(md.title,''),nullif(md.original_title,''),sm.movie_qid) movie_title,md.release_date,
CASE WHEN i.q='' AND p_concept_qid IS NULL THEN 1 WHEN i.q<>'' AND (lower(coalesce(md.title,''))=i.q OR lower(coalesce(md.original_title,''))=i.q OR lower(sm.movie_qid)=i.q) THEN 120 WHEN i.q<>'' AND (position(i.q IN lower(coalesce(md.title,'')))>0 OR position(i.q IN lower(coalesce(md.original_title,'')))>0) THEN 110 WHEN t.movie_qid IS NOT NULL THEN 105 WHEN i.q<>'' AND position(i.q IN idx.period_search)>0 THEN 100 WHEN i.q<>'' AND position(i.q IN idx.place_search)>0 THEN 95 WHEN i.q<>'' AND (position(i.q IN lower(coalesce(md.genres::text,'')))>0 OR position(i.q IN lower(coalesce(md.director::text,'')))>0 OR position(i.q IN lower(coalesce(md.cast_members::text,'')))>0) THEN 65 WHEN i.q<>'' AND position(i.q IN lower(coalesce(md.overview,'')))>0 THEN 45 WHEN era.movie_qid IS NOT NULL THEN 10 ELSE 0 END score,i.q
FROM candidates ca JOIN public.story_movies sm ON sm.movie_qid=ca.movie_qid CROSS JOIN input i JOIN public.reelatlas_search_index idx ON idx.movie_qid=sm.movie_qid LEFT JOIN tagged t ON t.movie_qid=sm.movie_qid LEFT JOIN contemporaries era ON era.movie_qid=sm.movie_qid LEFT JOIN public.movies md ON md.tmdb_id=sm.tmdb_id WHERE sm.is_deleted=false AND (p_start_year IS NULL OR p_end_year IS NULL OR EXISTS(SELECT 1 FROM public.story_movie_periods mp WHERE mp.movie_qid=sm.movie_qid AND mp.is_deleted=false AND mp.start_year<=p_end_year AND mp.end_year>=p_start_year)) AND (p_concept_qid IS NULL OR EXISTS(SELECT 1 FROM selected s JOIN public.story_movie_periods mp ON mp.movie_qid=sm.movie_qid AND mp.is_deleted=false WHERE s.start_year IS NOT NULL AND s.end_year IS NOT NULL AND mp.start_year<=s.end_year AND mp.end_year>=s.start_year)) AND ((left(coalesce(p_place_qid,''),length('__city_unspecified__:'))='__city_unspecified__:' AND EXISTS(SELECT 1 FROM public.story_movie_locations ml JOIN public.reelspan_country_continents cc ON cc.country_qid=ml.country_qid WHERE ml.movie_qid=sm.movie_qid AND ml.is_deleted=false AND p_place_qid='__city_unspecified__:'||ml.country_qid AND (p_country_qid IS NULL OR ml.country_qid=p_country_qid) AND NOT EXISTS(SELECT 1 FROM public.story_movie_locations ml2 JOIN public.story_places city ON city.place_qid=ml2.city_qid AND city.is_deleted=false WHERE ml2.movie_qid=sm.movie_qid AND ml2.country_qid=ml.country_qid AND ml2.is_deleted=false))) OR (left(coalesce(p_place_qid,''),length('__city_unspecified__:'))<>'__city_unspecified__:' AND (p_place_qid IS NULL AND p_country_qid IS NULL OR EXISTS(SELECT 1 FROM public.story_movie_locations ml WHERE ml.movie_qid=sm.movie_qid AND ml.is_deleted=false AND (p_place_qid IS NULL OR p_place_qid IN (ml.modern_place_qid,ml.city_qid,ml.admin1_qid,ml.country_qid,CASE WHEN ml.modern_place_qid IS NULL THEN ml.raw_place_qid END)) AND (p_country_qid IS NULL OR ml.country_qid=p_country_qid))))) AND (p_genre IS NULL OR position(lower(p_genre) IN lower(coalesce(md.genres::text,'')))>0)),
chosen AS (SELECT s.* FROM scored s WHERE (s.q='' AND p_concept_qid IS NULL) OR s.score>0 ORDER BY CASE WHEN p_sort='newest' THEN 0 ELSE s.score END DESC,CASE WHEN p_sort='oldest' THEN s.release_date END ASC NULLS LAST,CASE WHEN p_sort='newest' THEN s.release_date END DESC NULLS LAST,CASE WHEN p_sort='title' THEN lower(s.movie_title) END ASC NULLS LAST,CASE WHEN p_sort LIKE 'country:%' THEN EXISTS(SELECT 1 FROM public.story_movie_locations local_place WHERE local_place.movie_qid=s.movie_qid AND local_place.is_deleted=false AND local_place.country_qid=substring(p_sort from 9)) ELSE false END DESC,s.legacy_id ASC LIMIT (SELECT page_size FROM input) OFFSET (SELECT page_start FROM input))
SELECT c.movie_qid,c.legacy_id,c.tmdb_id,c.imdb_id,c.movie_title,coalesce(detail.overview,''),c.release_date,coalesce(detail.genres,'[]'::jsonb),c.score,CASE WHEN c.score>=110 THEN 'title' WHEN c.score=105 THEN 'tag' WHEN c.score=100 THEN 'period' WHEN c.score=95 THEN 'place' WHEN c.score=65 THEN 'metadata' WHEN c.score=45 THEN 'overview' WHEN c.score=10 THEN 'same-era' ELSE 'browse' END,
coalesce((SELECT jsonb_agg(jsonb_build_object('start',mp.start_year,'end',mp.end_year,'qid',mp.period_qid) ORDER BY mp.start_year,mp.end_year) FROM public.story_movie_periods mp WHERE mp.movie_qid=c.movie_qid AND mp.is_deleted=false AND mp.start_year IS NOT NULL AND mp.end_year IS NOT NULL),'[]'::jsonb),
coalesce((SELECT jsonb_agg(jsonb_build_object('qid',loc.raw_place_qid,'name',loc.raw_place_name_en,'name_zh',loc.raw_place_name_zh,'latitude',pl.latitude,'longitude',pl.longitude)) FROM (SELECT DISTINCT ON (ml.raw_place_qid) ml.raw_place_qid,ml.raw_place_name_en,ml.raw_place_name_zh FROM public.story_movie_locations ml WHERE ml.movie_qid=c.movie_qid AND ml.is_deleted=false ORDER BY ml.raw_place_qid LIMIT 8) loc LEFT JOIN public.story_places pl ON pl.place_qid=loc.raw_place_qid),'[]'::jsonb)
FROM chosen c LEFT JOIN public.movies detail ON detail.tmdb_id=c.tmdb_id ORDER BY CASE WHEN p_sort='newest' THEN 0 ELSE c.score END DESC,CASE WHEN p_sort='oldest' THEN c.release_date END ASC NULLS LAST,CASE WHEN p_sort='newest' THEN c.release_date END DESC NULLS LAST,CASE WHEN p_sort='title' THEN lower(c.movie_title) END ASC NULLS LAST,CASE WHEN p_sort LIKE 'country:%' THEN EXISTS(SELECT 1 FROM public.story_movie_locations local_place WHERE local_place.movie_qid=c.movie_qid AND local_place.is_deleted=false AND local_place.country_qid=substring(p_sort from 9)) ELSE false END DESC,c.legacy_id ASC;
$function$;

-- The public wrapper remains the only client-callable entry point.
REVOKE ALL ON FUNCTION public.reelatlas_discover_search(text,integer,integer,text,text,text,text,text,integer,integer) FROM PUBLIC, anon, authenticated;
ALTER ROLE anon SET statement_timeout='5s';
NOTIFY pgrst, 'reload config';
ANALYZE public.movies;
ANALYZE public.reelatlas_search_index;
