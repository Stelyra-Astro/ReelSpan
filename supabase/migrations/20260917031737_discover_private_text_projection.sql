-- Internal search projection: no raw movie-table rewrite and no client access.
CREATE SCHEMA IF NOT EXISTS reelspan_private;
REVOKE ALL ON SCHEMA reelspan_private FROM PUBLIC, anon, authenticated;
CREATE TABLE reelspan_private.movie_search (
 tmdb_id bigint PRIMARY KEY,
 title text NOT NULL, original_title text NOT NULL, genres text NOT NULL,
 director text NOT NULL, cast_members text NOT NULL, overview text NOT NULL,
 search_text text NOT NULL
);
ALTER TABLE reelspan_private.movie_search ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON reelspan_private.movie_search FROM PUBLIC, anon, authenticated;
ALTER TABLE reelspan_private.movie_search ALTER COLUMN title SET STORAGE EXTERNAL;
ALTER TABLE reelspan_private.movie_search ALTER COLUMN original_title SET STORAGE EXTERNAL;
ALTER TABLE reelspan_private.movie_search ALTER COLUMN genres SET STORAGE EXTERNAL;
ALTER TABLE reelspan_private.movie_search ALTER COLUMN director SET STORAGE EXTERNAL;
ALTER TABLE reelspan_private.movie_search ALTER COLUMN cast_members SET STORAGE EXTERNAL;
ALTER TABLE reelspan_private.movie_search ALTER COLUMN overview SET STORAGE EXTERNAL;
ALTER TABLE reelspan_private.movie_search ALTER COLUMN search_text SET STORAGE EXTERNAL;
CREATE FUNCTION reelspan_private.refresh_movie_search() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $trigger$
DECLARE t text; o text; g text; d text; c text; v text;
BEGIN
 IF TG_OP='DELETE' THEN
   DELETE FROM reelspan_private.movie_search WHERE tmdb_id=OLD.tmdb_id;
   RETURN OLD;
 END IF;
 t:=lower(coalesce(NEW.title,'')); o:=lower(coalesce(NEW.original_title,'')); g:=lower(coalesce(NEW.genres::text,'')); d:=lower(coalesce(NEW.director::text,'')); c:=lower(coalesce(NEW.cast_members::text,'')); v:=lower(coalesce(NEW.overview,''));
 IF TG_OP='UPDATE' AND OLD.tmdb_id<>NEW.tmdb_id THEN
   DELETE FROM reelspan_private.movie_search WHERE tmdb_id=OLD.tmdb_id;
 END IF;
 INSERT INTO reelspan_private.movie_search VALUES (NEW.tmdb_id,t,o,g,d,c,v,t||E'\n'||o||E'\n'||g||E'\n'||d||E'\n'||c||E'\n'||v)
 ON CONFLICT (tmdb_id) DO UPDATE SET title=EXCLUDED.title,original_title=EXCLUDED.original_title,
 genres=EXCLUDED.genres,director=EXCLUDED.director,cast_members=EXCLUDED.cast_members,
 overview=EXCLUDED.overview,search_text=EXCLUDED.search_text;
 RETURN NEW;
END;
$trigger$;
REVOKE ALL ON FUNCTION reelspan_private.refresh_movie_search() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER reelspan_movie_search_refresh AFTER INSERT OR UPDATE OF tmdb_id,title,original_title,genres,director,cast_members,overview OR DELETE
 ON public.movies FOR EACH ROW EXECUTE FUNCTION reelspan_private.refresh_movie_search();
INSERT INTO reelspan_private.movie_search
 SELECT tmdb_id,lower(coalesce(title,'')),lower(coalesce(original_title,'')),lower(coalesce(genres::text,'')),lower(coalesce(director::text,'')),lower(coalesce(cast_members::text,'')),lower(coalesce(overview,'')),reelspan_discover_text
 FROM public.movies;
CREATE INDEX movie_search_text_trgm ON reelspan_private.movie_search USING gin(search_text extensions.gin_trgm_ops);
ANALYZE reelspan_private.movie_search;
-- Re-plan using actual bound parameters: avoid generic OR/NULL filter plans.
-- No user input is interpolated into SQL; EXECUTE uses typed bound values.
CREATE OR REPLACE FUNCTION public.reelatlas_discover_search(p_query text DEFAULT ''::text, p_start_year integer DEFAULT NULL::integer, p_end_year integer DEFAULT NULL::integer, p_concept_qid text DEFAULT NULL::text, p_place_qid text DEFAULT NULL::text, p_country_qid text DEFAULT NULL::text, p_genre text DEFAULT NULL::text, p_sort text DEFAULT 'recommended'::text, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
 RETURNS TABLE(movie_qid text, legacy_id bigint, tmdb_id bigint, imdb_id text, title text, overview text, release_date date, genres jsonb, match_score integer, match_reason text, time_ranges jsonb, story_locations jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 RETURN QUERY EXECUTE $query$
WITH input AS (SELECT lower(trim(left(coalesce($1,''),80))) q,greatest(1,least(coalesce($9,20),50)) page_size,greatest(0,least(coalesce($10,0),100000)) page_start, '%' || replace(replace(replace(lower(trim(left(coalesce($1,''),80))), chr(92), chr(92)||chr(92)), '%', chr(92)||'%'), '_', chr(92)||'_') || '%' pattern),
selected AS (SELECT c.concept_qid,c.start_year,c.end_year FROM public.story_time_concepts c CROSS JOIN input i WHERE c.is_deleted=false AND (($4 IS NOT NULL AND c.concept_qid=$4) OR ($4 IS NULL AND i.q<>'' AND (lower(c.name_en)=i.q OR lower(c.name_zh)=i.q OR EXISTS(SELECT 1 FROM jsonb_each_text(c.labels) a WHERE lower(a.value)=i.q)))) ORDER BY CASE WHEN c.concept_qid=$4 THEN 0 ELSE 1 END,c.concept_qid LIMIT 1),
tagged AS MATERIALIZED (SELECT DISTINCT t.movie_qid FROM public.story_movie_concept_tags t JOIN selected s ON s.concept_qid=t.concept_qid WHERE t.is_deleted=false),
contemporaries AS MATERIALIZED (SELECT DISTINCT mp.movie_qid FROM public.story_movie_periods mp JOIN selected s ON s.start_year IS NOT NULL AND s.end_year IS NOT NULL AND mp.start_year<=s.end_year AND mp.end_year>=s.start_year WHERE mp.is_deleted=false),
metadata_matches AS MATERIALIZED (
 SELECT md.tmdb_id,
 CASE WHEN md.title=i.q OR md.original_title=i.q THEN 120
 WHEN position(i.q IN md.title)>0 OR position(i.q IN md.original_title)>0 THEN 110
 WHEN (position(i.q IN md.genres)>0 OR position(i.q IN md.director)>0 OR position(i.q IN md.cast_members)>0) THEN 65
 WHEN position(i.q IN md.overview)>0 THEN 45 ELSE 0 END score
 FROM reelspan_private.movie_search md CROSS JOIN input i
 WHERE i.q<>'' AND length(i.q)>=3 AND md.search_text LIKE i.pattern ESCAPE chr(92)
 UNION ALL
 SELECT md.tmdb_id,
 CASE WHEN md.title=i.q OR md.original_title=i.q THEN 120
 WHEN position(i.q IN md.title)>0 OR position(i.q IN md.original_title)>0 THEN 110
 WHEN (position(i.q IN md.genres)>0 OR position(i.q IN md.director)>0 OR position(i.q IN md.cast_members)>0) THEN 65
 WHEN position(i.q IN md.overview)>0 THEN 45 ELSE 0 END score
 FROM reelspan_private.movie_search md CROSS JOIN input i
 WHERE i.q<>'' AND length(i.q)<3 AND position(i.q IN md.search_text)>0
), index_matches AS MATERIALIZED (
 SELECT idx.movie_qid, CASE WHEN position(i.q IN idx.period_search)>0 THEN 100
 WHEN position(i.q IN idx.place_search)>0 THEN 95 ELSE 0 END score
 FROM public.reelatlas_search_index idx CROSS JOIN input i
 WHERE i.q<>'' AND length(i.q)>=3 AND idx.reelspan_discover_text LIKE i.pattern ESCAPE chr(92)
 UNION ALL
 SELECT idx.movie_qid, CASE WHEN position(i.q IN idx.period_search)>0 THEN 100
 WHEN position(i.q IN idx.place_search)>0 THEN 95 ELSE 0 END score
 FROM public.reelatlas_search_index idx CROSS JOIN input i
 WHERE i.q<>'' AND length(i.q)<3 AND position(i.q IN idx.reelspan_discover_text)>0
), relevance AS MATERIALIZED (
 SELECT hits.movie_qid, max(hits.score)::integer score FROM (
 SELECT sm.movie_qid, mm.score FROM metadata_matches mm JOIN public.story_movies sm ON sm.tmdb_id=mm.tmdb_id
 UNION ALL SELECT movie_qid,score FROM index_matches
 UNION ALL SELECT sm.movie_qid,120 FROM public.story_movies sm CROSS JOIN input i WHERE i.q<>'' AND lower(sm.movie_qid)=i.q
 UNION ALL SELECT movie_qid,105 FROM tagged
 UNION ALL SELECT movie_qid,10 FROM contemporaries
 ) hits GROUP BY hits.movie_qid
), scoped AS MATERIALIZED (
 SELECT DISTINCT ml.movie_qid FROM public.story_movie_locations ml
 WHERE ($5 IS NOT NULL OR $6 IS NOT NULL) AND ml.is_deleted=false
 AND ($6 IS NULL OR ml.country_qid=$6)
 AND (
 (left(coalesce($5,''),length('__city_unspecified__:'))<>'__city_unspecified__:'
  AND ($5 IS NULL OR $5 IN (ml.modern_place_qid,ml.city_qid,ml.admin1_qid,ml.country_qid,
       CASE WHEN ml.modern_place_qid IS NULL THEN ml.raw_place_qid END)))
 OR
 ($5='__city_unspecified__:'||ml.country_qid
  AND EXISTS (SELECT 1 FROM public.reelspan_country_continents cc WHERE cc.country_qid=ml.country_qid)
  AND NOT EXISTS (SELECT 1 FROM public.story_movie_locations ml2
                  JOIN public.story_places city ON city.place_qid=ml2.city_qid AND city.is_deleted=false
                  WHERE ml2.movie_qid=ml.movie_qid AND ml2.country_qid=ml.country_qid AND ml2.is_deleted=false))
 )
), candidates AS MATERIALIZED (
 SELECT sm.movie_qid,1::integer score FROM public.story_movies sm CROSS JOIN input i
 WHERE sm.is_deleted=false AND i.q='' AND $4 IS NULL
 UNION ALL
 SELECT r.movie_qid,r.score FROM relevance r CROSS JOIN input i WHERE (i.q<>'' OR $4 IS NOT NULL) AND r.score>0
), scored AS (
 SELECT sm.movie_qid,sm.legacy_id,sm.tmdb_id,sm.imdb_id,
 coalesce(nullif(md.title,''),nullif(md.original_title,''),sm.movie_qid) movie_title,
 md.release_date,ca.score,i.q
 FROM candidates ca JOIN public.story_movies sm ON sm.movie_qid=ca.movie_qid CROSS JOIN input i
 JOIN public.reelatlas_search_index idx ON idx.movie_qid=sm.movie_qid
 LEFT JOIN public.movies md ON md.tmdb_id=sm.tmdb_id
 WHERE sm.is_deleted=false
 AND ($5 IS NULL AND $6 IS NULL OR sm.movie_qid IN (SELECT movie_qid FROM scoped))
 AND ($2 IS NULL OR $3 IS NULL OR EXISTS (
 SELECT 1 FROM public.story_movie_periods mp WHERE mp.movie_qid=sm.movie_qid AND mp.is_deleted=false
 AND mp.start_year<=$3 AND mp.end_year>=$2))
 AND ($4 IS NULL OR EXISTS (
 SELECT 1 FROM selected s JOIN public.story_movie_periods mp ON mp.movie_qid=sm.movie_qid AND mp.is_deleted=false
 WHERE s.start_year IS NOT NULL AND s.end_year IS NOT NULL AND mp.start_year<=s.end_year AND mp.end_year>=s.start_year))
 AND ($7 IS NULL OR position(lower($7) IN lower(coalesce(md.genres::text,'')))>0)
),
chosen AS (SELECT s.* FROM scored s WHERE (s.q='' AND $4 IS NULL) OR s.score>0 ORDER BY CASE WHEN $8='newest' THEN 0 ELSE s.score END DESC,CASE WHEN $8='oldest' THEN s.release_date END ASC NULLS LAST,CASE WHEN $8='newest' THEN s.release_date END DESC NULLS LAST,CASE WHEN $8='title' THEN lower(s.movie_title) END ASC NULLS LAST,CASE WHEN $8 LIKE 'country:%' THEN EXISTS(SELECT 1 FROM public.story_movie_locations local_place WHERE local_place.movie_qid=s.movie_qid AND local_place.is_deleted=false AND local_place.country_qid=substring($8 from 9)) ELSE false END DESC,s.legacy_id ASC LIMIT (SELECT page_size FROM input) OFFSET (SELECT page_start FROM input))
SELECT c.movie_qid,c.legacy_id,c.tmdb_id,c.imdb_id,c.movie_title,coalesce(detail.overview,''),c.release_date,coalesce(detail.genres,'[]'::jsonb),c.score,CASE WHEN c.score>=110 THEN 'title' WHEN c.score=105 THEN 'tag' WHEN c.score=100 THEN 'period' WHEN c.score=95 THEN 'place' WHEN c.score=65 THEN 'metadata' WHEN c.score=45 THEN 'overview' WHEN c.score=10 THEN 'same-era' ELSE 'browse' END,
coalesce((SELECT jsonb_agg(jsonb_build_object('start',mp.start_year,'end',mp.end_year,'qid',mp.period_qid) ORDER BY mp.start_year,mp.end_year) FROM public.story_movie_periods mp WHERE mp.movie_qid=c.movie_qid AND mp.is_deleted=false AND mp.start_year IS NOT NULL AND mp.end_year IS NOT NULL),'[]'::jsonb),
coalesce((SELECT jsonb_agg(jsonb_build_object('qid',loc.raw_place_qid,'name',loc.raw_place_name_en,'name_zh',loc.raw_place_name_zh,'latitude',pl.latitude,'longitude',pl.longitude)) FROM (SELECT DISTINCT ON (ml.raw_place_qid) ml.raw_place_qid,ml.raw_place_name_en,ml.raw_place_name_zh FROM public.story_movie_locations ml WHERE ml.movie_qid=c.movie_qid AND ml.is_deleted=false ORDER BY ml.raw_place_qid LIMIT 8) loc LEFT JOIN public.story_places pl ON pl.place_qid=loc.raw_place_qid),'[]'::jsonb)
FROM chosen c LEFT JOIN public.movies detail ON detail.tmdb_id=c.tmdb_id ORDER BY CASE WHEN $8='newest' THEN 0 ELSE c.score END DESC,CASE WHEN $8='oldest' THEN c.release_date END ASC NULLS LAST,CASE WHEN $8='newest' THEN c.release_date END DESC NULLS LAST,CASE WHEN $8='title' THEN lower(c.movie_title) END ASC NULLS LAST,CASE WHEN $8 LIKE 'country:%' THEN EXISTS(SELECT 1 FROM public.story_movie_locations local_place WHERE local_place.movie_qid=c.movie_qid AND local_place.is_deleted=false AND local_place.country_qid=substring($8 from 9)) ELSE false END DESC,c.legacy_id ASC;
$query$ USING p_query, p_start_year, p_end_year, p_concept_qid, p_place_qid, p_country_qid, p_genre, p_sort, p_limit, p_offset;
END;
$function$;
