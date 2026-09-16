-- A per-film projection avoids correlated scans of 57k location and 6k period rows on every search.
-- It is private; callers only execute the restricted reelatlas_discover RPC.
CREATE TABLE public.reelatlas_search_index (
 movie_qid text PRIMARY KEY REFERENCES public.story_movies(movie_qid) ON DELETE CASCADE,
 period_search text NOT NULL DEFAULT '',
 place_search text NOT NULL DEFAULT ''
);
ALTER TABLE public.reelatlas_search_index ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.reelatlas_refresh_search_row(p_movie_qid text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $refresh$
BEGIN
 IF EXISTS(SELECT 1 FROM public.story_movies WHERE movie_qid=p_movie_qid AND is_deleted=false) THEN
  INSERT INTO public.reelatlas_search_index(movie_qid,period_search,place_search)
  SELECT sm.movie_qid,
    coalesce((SELECT lower(string_agg(concat_ws(' ',mp.period_name_en,mp.period_name_zh,mp.period_labels::text),' '))
      FROM public.story_movie_periods mp WHERE mp.movie_qid=sm.movie_qid AND mp.is_deleted=false),''),
    coalesce((SELECT lower(string_agg(concat_ws(' ',ml.raw_place_name_en,ml.raw_place_name_zh,ml.raw_place_labels::text,
        ml.city_name_en,ml.city_name_zh,ml.admin1_name_en,ml.admin1_name_zh,ml.country_name_en,ml.country_name_zh), ' '))
      FROM public.story_movie_locations ml WHERE ml.movie_qid=sm.movie_qid AND ml.is_deleted=false),'')
  FROM public.story_movies sm WHERE sm.movie_qid=p_movie_qid
  ON CONFLICT (movie_qid) DO UPDATE SET period_search=EXCLUDED.period_search,place_search=EXCLUDED.place_search;
 ELSE
  DELETE FROM public.reelatlas_search_index WHERE movie_qid=p_movie_qid;
 END IF;
END; $refresh$;
REVOKE ALL ON FUNCTION public.reelatlas_refresh_search_row(text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.reelatlas_search_change_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $trigger$
BEGIN
 IF TG_OP='DELETE' THEN
  PERFORM public.reelatlas_refresh_search_row(OLD.movie_qid);
  RETURN OLD;
 END IF;
 IF TG_OP='UPDATE' AND NEW.movie_qid IS DISTINCT FROM OLD.movie_qid THEN
  PERFORM public.reelatlas_refresh_search_row(OLD.movie_qid);
 END IF;
 PERFORM public.reelatlas_refresh_search_row(NEW.movie_qid);
 RETURN NEW;
END; $trigger$;
REVOKE ALL ON FUNCTION public.reelatlas_search_change_trigger() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER reelatlas_story_movies_search AFTER INSERT OR UPDATE OR DELETE ON public.story_movies
FOR EACH ROW EXECUTE FUNCTION public.reelatlas_search_change_trigger();
CREATE TRIGGER reelatlas_story_locations_search AFTER INSERT OR UPDATE OR DELETE ON public.story_movie_locations
FOR EACH ROW EXECUTE FUNCTION public.reelatlas_search_change_trigger();
CREATE TRIGGER reelatlas_story_periods_search AFTER INSERT OR UPDATE OR DELETE ON public.story_movie_periods
FOR EACH ROW EXECUTE FUNCTION public.reelatlas_search_change_trigger();

-- Populate existing dataset once; triggers maintain subsequent incoming or changed rows.
INSERT INTO public.reelatlas_search_index(movie_qid,period_search,place_search)
SELECT sm.movie_qid,
 coalesce(p.period_search,''),coalesce(l.place_search,'')
FROM public.story_movies sm
LEFT JOIN (
 SELECT movie_qid, lower(string_agg(concat_ws(' ',period_name_en,period_name_zh,period_labels::text),' ')) period_search
 FROM public.story_movie_periods WHERE is_deleted=false GROUP BY movie_qid
) p ON p.movie_qid=sm.movie_qid
LEFT JOIN (
 SELECT movie_qid, lower(string_agg(concat_ws(' ',raw_place_name_en,raw_place_name_zh,raw_place_labels::text,
    city_name_en,city_name_zh,admin1_name_en,admin1_name_zh,country_name_en,country_name_zh),' ')) place_search
 FROM public.story_movie_locations WHERE is_deleted=false GROUP BY movie_qid
) l ON l.movie_qid=sm.movie_qid
WHERE sm.is_deleted=false;

-- Optimized full-catalog discovery routine (same signature as migration 002).
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
  FROM public.story_movies sm
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
