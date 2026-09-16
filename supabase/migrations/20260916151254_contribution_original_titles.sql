-- Card/search queries read the live catalog, independent of device download progress.
CREATE OR REPLACE FUNCTION public.reelspan_contribution_film_cards(p_qids text[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
SELECT coalesce(jsonb_agg(jsonb_build_object(
 'movie_qid',sm.movie_qid,'legacy_id',sm.legacy_id,'tmdb_id',sm.tmdb_id,'imdb_id',sm.imdb_id,
 'title',coalesce(nullif(md.title,''),nullif(md.original_title,''),sm.movie_qid),
 'original_title',md.original_title,'overview',coalesce(md.overview,''),'release_date',md.release_date,'genres',coalesce(md.genres,'[]'::jsonb),
 'poster_url',md.poster_url,'runtime_minutes',md.runtime,'rating',md.payload->'vote_average','match_reason','contribution',
 'has_time',EXISTS(SELECT 1 FROM public.story_movie_periods t WHERE t.movie_qid=sm.movie_qid AND NOT t.is_deleted AND (t.start_year IS NOT NULL OR t.end_year IS NOT NULL)),
 'has_place',EXISTS(SELECT 1 FROM public.story_movie_locations p WHERE p.movie_qid=sm.movie_qid AND NOT p.is_deleted AND p.raw_place_qid IS NOT NULL),
 'time_ranges',coalesce((SELECT jsonb_agg(jsonb_build_object('start',t.start_year,'end',t.end_year,'qid',t.period_qid) ORDER BY t.period_qid)
   FROM public.story_movie_periods t WHERE t.movie_qid=sm.movie_qid AND NOT t.is_deleted),'[]'::jsonb),
 'story_locations',coalesce((SELECT jsonb_agg(jsonb_build_object('qid',p.raw_place_qid,'name',p.raw_place_name_en,'name_zh',p.raw_place_name_zh,
   'latitude',place.latitude,'longitude',place.longitude) ORDER BY p.id)
   FROM public.story_movie_locations p LEFT JOIN public.story_places place ON place.place_qid=p.raw_place_qid AND NOT place.is_deleted
   WHERE p.movie_qid=sm.movie_qid AND NOT p.is_deleted),'[]'::jsonb)
) ORDER BY array_position(p_qids,sm.movie_qid)),'[]'::jsonb)
FROM public.story_movies sm LEFT JOIN public.movies md ON md.tmdb_id=sm.tmdb_id
WHERE NOT sm.is_deleted AND sm.movie_qid=ANY(p_qids[1:50]);
$$;
REVOKE ALL ON FUNCTION public.reelspan_contribution_film_cards(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_contribution_film_cards(text[]) TO anon, authenticated;
