-- Country QIDs are reviewed modern geographies. Historical polities and invented places do not appear as Where countries.
CREATE TABLE IF NOT EXISTS public.reelspan_country_continents (
  country_qid text PRIMARY KEY REFERENCES public.story_places(place_qid),
  continent text NOT NULL CHECK(continent IN ('Africa','Asia','Europe','North America','South America','Oceania'))
);
ALTER TABLE public.reelspan_country_continents ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.reelspan_country_continents TO anon,authenticated;
CREATE POLICY public_read ON public.reelspan_country_continents FOR SELECT TO anon,authenticated USING(true);

CREATE TABLE IF NOT EXISTS public.reelspan_where_catalog (
  place_qid text PRIMARY KEY REFERENCES public.story_places(place_qid),
  name_en text NOT NULL,
  name_zh text NOT NULL DEFAULT '',
  category text NOT NULL CHECK(category IN ('country','city')),
  continent text NOT NULL,
  parent_qid text,
  country_qid text NOT NULL,
  film_count integer NOT NULL CHECK (film_count>0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS reelspan_where_catalog_tree_idx ON public.reelspan_where_catalog(continent,country_qid,category,film_count DESC);
ALTER TABLE public.reelspan_where_catalog ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.reelspan_where_catalog TO anon,authenticated;
CREATE POLICY public_read ON public.reelspan_where_catalog FOR SELECT TO anon,authenticated USING(true);

CREATE TABLE IF NOT EXISTS public.reelspan_where_refresh_state (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 dirty boolean NOT NULL DEFAULT true,
 revision bigint NOT NULL DEFAULT 0,
 refreshed_at timestamptz
);
INSERT INTO public.reelspan_where_refresh_state(singleton) VALUES(true) ON CONFLICT DO NOTHING;
ALTER TABLE public.reelspan_where_refresh_state ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.reelspan_refresh_where_catalog(p_force boolean DEFAULT false)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE resulting integer;
BEGIN
 IF NOT p_force AND NOT (SELECT dirty FROM public.reelspan_where_refresh_state WHERE singleton) THEN
   RETURN (SELECT count(*)::integer FROM public.reelspan_where_catalog);
 END IF;
 CREATE TEMP TABLE reelspan_normalized_places ON COMMIT DROP AS
 SELECT DISTINCT ml.movie_qid,cc.country_qid,cc.continent,
     CASE WHEN ml.city_qid IS NOT NULL AND city.place_qid IS NOT NULL THEN ml.city_qid ELSE NULL END city_qid
 FROM public.story_movie_locations ml
 JOIN public.reelspan_country_continents cc ON cc.country_qid=ml.country_qid
 LEFT JOIN public.story_places city ON city.place_qid=ml.city_qid AND city.is_deleted=false
 WHERE ml.is_deleted=false;
 CREATE INDEX ON pg_temp.reelspan_normalized_places(country_qid,city_qid);
 CREATE TEMP TABLE reelspan_fresh_places ON COMMIT DROP AS
 WITH countries AS (
 SELECT country_qid qid,country_qid,continent,'country'::text category,NULL::text parent_qid,
        count(DISTINCT movie_qid)::integer film_count
 FROM pg_temp.reelspan_normalized_places GROUP BY country_qid,continent
 ), cities AS (
 SELECT city_qid qid,country_qid,continent,'city'::text category,country_qid parent_qid,
        count(DISTINCT movie_qid)::integer film_count
 FROM pg_temp.reelspan_normalized_places WHERE city_qid IS NOT NULL
 GROUP BY city_qid,country_qid,continent
 )
 SELECT DISTINCT ON (all_places.qid) all_places.*,p.name_en,p.name_zh
 FROM (SELECT * FROM countries UNION ALL SELECT * FROM cities) all_places
 JOIN public.story_places p ON p.place_qid=all_places.qid AND p.is_deleted=false
 ORDER BY all_places.qid,all_places.film_count DESC;
 INSERT INTO public.reelspan_where_catalog(place_qid,name_en,name_zh,category,continent,parent_qid,country_qid,film_count,updated_at)
 SELECT qid,name_en,coalesce(name_zh,''),category,continent,parent_qid,country_qid,film_count,now() FROM pg_temp.reelspan_fresh_places
 ON CONFLICT(place_qid) DO UPDATE SET name_en=excluded.name_en,name_zh=excluded.name_zh,
 category=excluded.category,continent=excluded.continent,parent_qid=excluded.parent_qid,
 country_qid=excluded.country_qid,film_count=excluded.film_count,updated_at=now();
 DELETE FROM public.reelspan_where_catalog w WHERE NOT EXISTS (SELECT 1 FROM pg_temp.reelspan_fresh_places f WHERE f.qid=w.place_qid);
 UPDATE public.reelspan_where_refresh_state SET dirty=false,revision=revision+1,refreshed_at=now() WHERE singleton;
 SELECT count(*)::integer INTO resulting FROM public.reelspan_where_catalog;
 RETURN resulting;
END;
$fn$;
REVOKE ALL ON FUNCTION public.reelspan_refresh_where_catalog(boolean) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.reelspan_where_mark_dirty()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN UPDATE public.reelspan_where_refresh_state SET dirty=true WHERE singleton; RETURN NULL; END;
$fn$;
REVOKE ALL ON FUNCTION public.reelspan_where_mark_dirty() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER reelspan_where_location_changed AFTER INSERT OR UPDATE OR DELETE ON public.story_movie_locations
 FOR EACH STATEMENT EXECUTE FUNCTION public.reelspan_where_mark_dirty();
CREATE OR REPLACE FUNCTION public.reelspan_where_revision() RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $fn$
 SELECT revision FROM public.reelspan_where_refresh_state WHERE singleton;
$fn$;
REVOKE ALL ON FUNCTION public.reelspan_where_revision() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_where_revision() TO anon,authenticated;
CREATE OR REPLACE FUNCTION public.reelatlas_where_places(p_query text DEFAULT '',p_limit integer DEFAULT 40)
RETURNS TABLE(place_qid text,name_en text,name_zh text,category text,film_count bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $fn$
 SELECT w.place_qid,w.name_en,w.name_zh,w.category,w.film_count::bigint FROM public.reelspan_where_catalog w
 WHERE trim(coalesce(p_query,''))='' OR w.name_en ILIKE '%'||left(trim(p_query),80)||'%'
 OR w.name_zh ILIKE '%'||left(trim(p_query),80)||'%'
 ORDER BY CASE WHEN lower(w.name_en)=lower(trim(coalesce(p_query,''))) OR lower(w.name_zh)=lower(trim(coalesce(p_query,''))) THEN 0 ELSE 1 END,
 w.film_count DESC,w.name_en LIMIT greatest(1,least(coalesce(p_limit,40),100));
$fn$;
REVOKE ALL ON FUNCTION public.reelatlas_where_places(text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelatlas_where_places(text,integer) TO anon,authenticated;
