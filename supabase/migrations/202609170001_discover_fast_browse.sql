-- Build 12 diagnostic: default anonymous reelatlas_discover exceeded the 3s
-- statement_timeout because it joined and scored the full catalog before LIMIT.
-- Keep the released RPC signature and preserve the existing searchable path.
-- Run this migration on Supabase to address the server half of the failure;
-- shipping only the iOS changes will not change the live RPC.

CREATE INDEX IF NOT EXISTS idx_reelspan_live_movies_legacy_id
  ON public.story_movies (legacy_id) WHERE is_deleted = false;
CREATE INDEX IF NOT EXISTS idx_reelspan_live_locations_country_movie
  ON public.story_movie_locations (country_qid, movie_qid) WHERE is_deleted = false;
CREATE INDEX IF NOT EXISTS idx_reelspan_live_locations_movie_country
  ON public.story_movie_locations (movie_qid, country_qid) WHERE is_deleted = false;

-- Preserve the actual server's existing search/sort semantics, even if that
-- definition differs from a local migration. Only the empty default browse is
-- replaced by an ID-first fast path. Apply exactly once as a dated migration.
ALTER FUNCTION public.reelatlas_discover(
  text,integer,integer,text,text,text,text,text,integer,integer
) RENAME TO reelatlas_discover_search;
REVOKE ALL ON FUNCTION public.reelatlas_discover_search(
  text,integer,integer,text,text,text,text,text,integer,integer
) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.reelatlas_discover(
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
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $function$
BEGIN
  IF trim(coalesce(p_query, '')) = ''
     AND p_start_year IS NULL AND p_end_year IS NULL
     AND p_concept_qid IS NULL AND p_place_qid IS NULL
     AND p_country_qid IS NULL AND p_genre IS NULL
     AND (p_sort = 'recommended' OR p_sort LIKE 'country:%') THEN
    -- No movies metadata, periods, wide JSON, or search index are joined until
    -- after ID pagination. For country priority, use an indexed *bounded*
    -- country shortlist rather than sorting 50k correlated EXISTS results.
    RETURN QUERY
    WITH prioritized AS MATERIALIZED (
      SELECT DISTINCT sm.movie_qid, sm.legacy_id, sm.tmdb_id, sm.imdb_id,
             true AS local_priority
      FROM public.story_movie_locations ml
      JOIN public.story_movies sm ON sm.movie_qid=ml.movie_qid AND sm.is_deleted=false
      WHERE p_sort LIKE 'country:%' AND ml.country_qid=substring(p_sort from 9)
        AND ml.is_deleted=false
      ORDER BY sm.legacy_id ASC
      LIMIT greatest(1, least(coalesce(p_limit, 20), 50))
            + greatest(0, least(coalesce(p_offset, 0), 100000))
    ), remainder AS MATERIALIZED (
      SELECT sm.movie_qid, sm.legacy_id, sm.tmdb_id, sm.imdb_id,
             false AS local_priority
      FROM public.story_movies sm
      WHERE sm.is_deleted=false AND (p_sort='recommended' OR NOT EXISTS (
               SELECT 1 FROM public.story_movie_locations ml
               WHERE ml.movie_qid = sm.movie_qid AND ml.is_deleted = false
                 AND ml.country_qid = substring(p_sort from 9)
             ))
      ORDER BY sm.legacy_id ASC
      LIMIT greatest(1, least(coalesce(p_limit, 20), 50))
            + greatest(0, least(coalesce(p_offset, 0), 100000))
    ), chosen AS MATERIALIZED (
      SELECT * FROM (
        SELECT * FROM prioritized
        UNION ALL SELECT * FROM remainder
      ) shortlist
      ORDER BY local_priority DESC, legacy_id ASC
      LIMIT greatest(1, least(coalesce(p_limit, 20), 50))
      OFFSET greatest(0, least(coalesce(p_offset, 0), 100000))
    )
    SELECT c.movie_qid, c.legacy_id, c.tmdb_id, c.imdb_id,
           coalesce(nullif(md.title, ''), nullif(md.original_title, ''), c.movie_qid),
           coalesce(md.overview, ''), md.release_date, coalesce(md.genres, '[]'::jsonb),
           1::integer, 'browse'::text,
           coalesce((
             SELECT jsonb_agg(jsonb_build_object('start', mp.start_year, 'end', mp.end_year,
                            'qid', mp.period_qid) ORDER BY mp.start_year, mp.end_year)
             FROM public.story_movie_periods mp
             WHERE mp.movie_qid = c.movie_qid AND mp.is_deleted = false
               AND mp.start_year IS NOT NULL AND mp.end_year IS NOT NULL
           ), '[]'::jsonb),
           coalesce((
             SELECT jsonb_agg(jsonb_build_object('qid', loc.raw_place_qid,
                        'name', loc.raw_place_name_en, 'name_zh', loc.raw_place_name_zh,
                        'latitude', pl.latitude, 'longitude', pl.longitude))
             FROM (
               SELECT DISTINCT ON (ml.raw_place_qid)
                      ml.raw_place_qid, ml.raw_place_name_en, ml.raw_place_name_zh
               FROM public.story_movie_locations ml
               WHERE ml.movie_qid = c.movie_qid AND ml.is_deleted = false
               ORDER BY ml.raw_place_qid LIMIT 8
             ) loc
             LEFT JOIN public.story_places pl ON pl.place_qid = loc.raw_place_qid
           ), '[]'::jsonb)
    FROM chosen c
    LEFT JOIN public.movies md ON md.tmdb_id = c.tmdb_id
    ORDER BY c.local_priority DESC, c.legacy_id ASC;
    RETURN;
  END IF;

  -- Keep existing behavior for filtered, searched, genre, and other sorts.
  RETURN QUERY SELECT s.* FROM public.reelatlas_discover_search(
    p_query, p_start_year, p_end_year, p_concept_qid, p_place_qid,
    p_country_qid, p_genre, p_sort, p_limit, p_offset
  ) s;
END;
$function$;
REVOKE ALL ON FUNCTION public.reelatlas_discover(
  text,integer,integer,text,text,text,text,text,integer,integer
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelatlas_discover(
  text,integer,integer,text,text,text,text,text,integer,integer
) TO anon, authenticated;
