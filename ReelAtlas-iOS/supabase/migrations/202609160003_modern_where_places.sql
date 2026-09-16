-- Modern administrative and settlement QIDs only; no historical polygon inference.
CREATE OR REPLACE FUNCTION public.reelatlas_where_places(p_query text DEFAULT '', p_limit integer DEFAULT 40)
RETURNS TABLE(place_qid text,name_en text,name_zh text,category text,film_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
WITH used AS (
 SELECT country_qid qid,'country' kind,movie_qid FROM public.story_movie_locations WHERE is_deleted=false AND country_qid IS NOT NULL
 UNION ALL SELECT admin1_qid,'admin1',movie_qid FROM public.story_movie_locations WHERE is_deleted=false AND admin1_qid IS NOT NULL
 UNION ALL SELECT city_qid,'city',movie_qid FROM public.story_movie_locations WHERE is_deleted=false AND city_qid IS NOT NULL
 UNION ALL SELECT modern_place_qid,'place',movie_qid FROM public.story_movie_locations WHERE is_deleted=false AND modern_place_qid IS NOT NULL
), ranked AS (
 SELECT u.qid,count(DISTINCT u.movie_qid) n,
 CASE WHEN bool_or(u.kind='country') THEN 'country' WHEN bool_or(u.kind='admin1') THEN 'admin1'
 WHEN bool_or(u.kind='city') THEN 'city' ELSE 'place' END kind
 FROM used u GROUP BY u.qid
)
SELECT r.qid,p.name_en,p.name_zh,r.kind,r.n
FROM ranked r JOIN public.story_places p ON p.place_qid=r.qid AND p.is_deleted=false
WHERE trim(coalesce(p_query,''))='' OR position(lower(trim(p_query)) IN lower(p.name_en))>0
 OR position(lower(trim(p_query)) IN lower(p.name_zh))>0
 OR position(lower(trim(p_query)) IN lower(p.labels::text))>0
ORDER BY CASE WHEN lower(p.name_en)=lower(trim(coalesce(p_query,''))) OR lower(p.name_zh)=lower(trim(coalesce(p_query,''))) THEN 0 ELSE 1 END,
 r.n DESC,p.name_en LIMIT greatest(1,least(coalesce(p_limit,40),100));
$fn$;
REVOKE ALL ON FUNCTION public.reelatlas_where_places(text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelatlas_where_places(text,integer) TO anon,authenticated;
