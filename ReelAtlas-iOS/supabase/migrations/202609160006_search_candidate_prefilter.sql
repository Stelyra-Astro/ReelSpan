-- Restrict relevance ranking to actual text/era candidates before pagination.
CREATE OR REPLACE FUNCTION public.reelatlas_discover(
  p_query text DEFAULT '', p_start_year integer DEFAULT NULL, p_end_year integer DEFAULT NULL,
  p_concept_qid text DEFAULT NULL, p_place_qid text DEFAULT NULL,
  p_country_qid text DEFAULT NULL, p_genre text DEFAULT NULL,
  p_sort text DEFAULT 'recommended', p_limit integer DEFAULT 20, p_offset integer DEFAULT 0
)
RETURNS TABLE (
  movie_qid text, legacy_id bigint, tmdb_id bigint, imdb_id text,
  title text, overview text, release_date date, genres jsonb,
  match_score integer, match_reason text, time_ranges jsonb, story_locations jsonb
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $function$
WITH input AS (
  SELECT lower(trim(left(coalesce(p_query,''),80))) AS q,
         greatest(1, least(coalesce(p_limit,20),50)) AS page_size,
         greatest(0, least(coalesce(p_offset,0),100000)) AS page_start
), selected AS (
  SELECT c.concept_qid,c.start_year,c.end_year
  FROM public.story_time_concepts c, input i
  WHERE c.is_deleted=false AND (
      (p_concept_qid IS NOT NULL AND c.concept_qid=p_concept_qid)
      OR (p_concept_qid IS NULL AND i.q<>'' AND
          (lower(c.name_en)=i.q OR lower(c.name_zh)=i.q OR
           EXISTS (SELECT 1 FROM jsonb_each_text(c.labels) a WHERE lower(a.value)=i.q)))
  )
  ORDER BY CASE WHEN c.concept_qid=p_concept_qid THEN 0 ELSE 1 END,c.concept_qid LIMIT 1
), tagged AS MATERIALIZED (
  SELECT DISTINCT t.movie_qid FROM public.story_movie_concept_tags t
  JOIN selected s ON s.concept_qid=t.concept_qid WHERE t.is_deleted=false
), contemporaries AS MATERIALIZED (
  SELECT DISTINCT mp.movie_qid FROM public.story_movie_periods mp
  JOIN selected s ON s.start_year IS NOT NULL AND s.end_year IS NOT NULL
    AND mp.start_year<=s.end_year AND mp.end_year>=s.start_year
  WHERE mp.is_deleted=false
), candidates AS MATERIALIZED (
 SELECT idx.movie_qid FROM public.reelatlas_search_index idx CROSS JOIN input i
 WHERE i.q='' AND p_concept_qid IS NULL
 UNION
 SELECT idx.movie_qid FROM public.reelatlas_search_index idx CROSS JOIN input i
 WHERE i.q<>'' AND (position(i.q IN idx.period_search)>0 OR position(i.q IN idx.place_search)>0)
 UNION
 SELECT sm.movie_qid FROM public.story_movies sm JOIN public.movies md ON md.tmdb_id=sm.tmdb_id CROSS JOIN input i
 WHERE i.q<>'' AND (position(i.q IN lower(coalesce(md.title,'')))>0
 OR position(i.q IN lower(coalesce(md.original_title,'')))>0
 OR position(i.q IN lower(coalesce(md.genres::text,'')))>0
 OR position(i.q IN lower(coalesce(md.director::text,'')))>0
 OR position(i.q IN lower(coalesce(md.cast_members::text,'')))>0
 OR position(i.q IN lower(coalesce(md.overview,'')))>0)
 UNION
 SELECT sm.movie_qid FROM public.story_movies sm CROSS JOIN input i WHERE i.q<>'' AND lower(sm.movie_qid)=i.q
 UNION SELECT movie_qid FROM tagged
 UNION SELECT movie_qid FROM contemporaries
), scored AS (
  SELECT sm.movie_qid,sm.legacy_id,sm.tmdb_id,sm.imdb_id,
         coalesce(nullif(md.title,''),nullif(md.original_title,''),sm.movie_qid) AS movie_title,
         coalesce(md.overview,'') AS movie_overview,md.release_date,coalesce(md.genres,'[]'::jsonb) AS movie_genres,
         CASE
           WHEN i.q='' AND p_concept_qid IS NULL THEN 1
           WHEN i.q<>'' AND (lower(coalesce(md.title,''))=i.q OR lower(coalesce(md.original_title,''))=i.q) THEN 120
           WHEN i.q<>'' AND (position(i.q IN lower(coalesce(md.title,'')))>0 OR position(i.q IN lower(coalesce(md.original_title,'')))>0) THEN 110
           WHEN t.movie_qid IS NOT NULL THEN 105
           WHEN i.q<>'' AND position(i.q IN idx.period_search)>0 THEN 100
           WHEN i.q<>'' AND position(i.q IN idx.place_search)>0 THEN 95
           WHEN i.q<>'' AND (position(i.q IN lower(coalesce(md.genres::text,'')))>0 OR
                               position(i.q IN lower(coalesce(md.director::text,'')))>0 OR
                               position(i.q IN lower(coalesce(md.cast_members::text,'')))>0) THEN 65
           WHEN i.q<>'' AND position(i.q IN lower(coalesce(md.overview,'')))>0 THEN 45
           WHEN era.movie_qid IS NOT NULL THEN 10
           ELSE 0 END AS score,
         i.q
  FROM candidates ca JOIN public.story_movies sm ON sm.movie_qid=ca.movie_qid
  CROSS JOIN input i
  JOIN public.reelatlas_search_index idx ON idx.movie_qid=sm.movie_qid
  LEFT JOIN tagged t ON t.movie_qid=sm.movie_qid
  LEFT JOIN contemporaries era ON era.movie_qid=sm.movie_qid
  LEFT JOIN public.movies md ON md.tmdb_id=sm.tmdb_id
  WHERE sm.is_deleted=false
    AND (p_start_year IS NULL OR p_end_year IS NULL OR EXISTS (
      SELECT 1 FROM public.story_movie_periods mp
      WHERE mp.movie_qid=sm.movie_qid AND mp.is_deleted=false
        AND mp.start_year<=p_end_year AND mp.end_year>=p_start_year))
    AND (p_concept_qid IS NULL OR EXISTS (SELECT 1 FROM selected s JOIN public.story_movie_periods mp
      ON mp.movie_qid=sm.movie_qid AND mp.is_deleted=false
      WHERE s.start_year IS NOT NULL AND s.end_year IS NOT NULL
        AND mp.start_year<=s.end_year AND mp.end_year>=s.start_year))
    AND (p_place_qid IS NULL AND p_country_qid IS NULL OR EXISTS (
      SELECT 1 FROM public.story_movie_locations ml
      WHERE ml.movie_qid=sm.movie_qid AND ml.is_deleted=false
        AND (p_place_qid IS NULL OR p_place_qid IN
          (ml.modern_place_qid,ml.city_qid,ml.admin1_qid,ml.country_qid,
           CASE WHEN ml.modern_place_qid IS NULL THEN ml.raw_place_qid END))
        AND (p_country_qid IS NULL OR ml.country_qid=p_country_qid)))
    AND (p_genre IS NULL OR position(lower(p_genre) IN lower(coalesce(md.genres::text,'')))>0)
), chosen AS (
  SELECT s.* FROM scored s
  WHERE (s.q='' AND p_concept_qid IS NULL) OR s.score>0
  ORDER BY
    CASE WHEN p_sort='newest' THEN 0 ELSE s.score END DESC,
    CASE WHEN p_sort='oldest' THEN s.release_date END ASC NULLS LAST,
    CASE WHEN p_sort='newest' THEN s.release_date END DESC NULLS LAST,
    CASE WHEN p_sort='title' THEN lower(s.movie_title) END ASC NULLS LAST,
    s.legacy_id ASC
  LIMIT (SELECT page_size FROM input) OFFSET (SELECT page_start FROM input)
)
SELECT c.movie_qid,c.legacy_id,c.tmdb_id,c.imdb_id,c.movie_title,c.movie_overview,c.release_date,c.movie_genres,c.score,
  CASE WHEN c.score>=110 THEN 'title' WHEN c.score=105 THEN 'tag'
       WHEN c.score=100 THEN 'period' WHEN c.score=95 THEN 'place'
       WHEN c.score=65 THEN 'metadata' WHEN c.score=45 THEN 'overview'
       WHEN c.score=10 THEN 'same-era' ELSE 'browse' END,
  coalesce((SELECT jsonb_agg(jsonb_build_object('start',mp.start_year,'end',mp.end_year,'qid',mp.period_qid)
                       ORDER BY mp.start_year,mp.end_year)
           FROM public.story_movie_periods mp WHERE mp.movie_qid=c.movie_qid AND mp.is_deleted=false
                AND mp.start_year IS NOT NULL AND mp.end_year IS NOT NULL),'[]'::jsonb),
  coalesce((SELECT jsonb_agg(jsonb_build_object('qid',loc.raw_place_qid,'name',loc.raw_place_name_en,
                 'name_zh',loc.raw_place_name_zh,'latitude',pl.latitude,'longitude',pl.longitude))
           FROM (SELECT DISTINCT ON (ml.raw_place_qid) ml.raw_place_qid,ml.raw_place_name_en,ml.raw_place_name_zh
                 FROM public.story_movie_locations ml WHERE ml.movie_qid=c.movie_qid AND ml.is_deleted=false
                 ORDER BY ml.raw_place_qid LIMIT 8) loc
           LEFT JOIN public.story_places pl ON pl.place_qid=loc.raw_place_qid),'[]'::jsonb)
FROM chosen c
ORDER BY
  CASE WHEN p_sort='newest' THEN 0 ELSE c.score END DESC,
  CASE WHEN p_sort='oldest' THEN c.release_date END ASC NULLS LAST,
  CASE WHEN p_sort='newest' THEN c.release_date END DESC NULLS LAST,
  CASE WHEN p_sort='title' THEN lower(c.movie_title) END ASC NULLS LAST,
  c.legacy_id ASC;
$function$;
REVOKE ALL ON FUNCTION public.reelatlas_discover(text,integer,integer,text,text,text,text,text,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelatlas_discover(text,integer,integer,text,text,text,text,text,integer,integer) TO anon, authenticated;
