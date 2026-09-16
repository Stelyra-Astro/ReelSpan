-- Card/search queries read the live catalog, independent of device download progress.
CREATE OR REPLACE FUNCTION public.reelspan_contribution_film_cards(p_qids text[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
SELECT coalesce(jsonb_agg(jsonb_build_object(
 'movie_qid',sm.movie_qid,'legacy_id',sm.legacy_id,'tmdb_id',sm.tmdb_id,'imdb_id',sm.imdb_id,
 'title',coalesce(nullif(md.title,''),nullif(md.original_title,''),sm.movie_qid),
 'overview',coalesce(md.overview,''),'release_date',md.release_date,'genres',coalesce(md.genres,'[]'::jsonb),
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

CREATE OR REPLACE FUNCTION public.reelspan_missing_film_cards(
 p_category text DEFAULT 'place_no_time',p_query text DEFAULT '',p_limit integer DEFAULT 30,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
WITH flags AS (
 SELECT sm.movie_qid,sm.legacy_id,sm.tmdb_id,sm.imdb_id,
 coalesce(nullif(md.title,''),nullif(md.original_title,''),sm.movie_qid) title,coalesce(md.original_title,'') original_title,
 EXISTS(SELECT 1 FROM public.story_movie_periods t WHERE t.movie_qid=sm.movie_qid AND NOT t.is_deleted AND (t.start_year IS NOT NULL OR t.end_year IS NOT NULL)) ht,
 EXISTS(SELECT 1 FROM public.story_movie_locations p WHERE p.movie_qid=sm.movie_qid AND NOT p.is_deleted AND p.raw_place_qid IS NOT NULL) hp
 FROM public.story_movies sm LEFT JOIN public.movies md ON md.tmdb_id=sm.tmdb_id WHERE NOT sm.is_deleted
), page AS (
 SELECT movie_qid,legacy_id FROM flags
 WHERE CASE p_category WHEN 'time_no_place' THEN ht AND NOT hp WHEN 'place_no_time' THEN hp AND NOT ht WHEN 'neither' THEN NOT ht AND NOT hp ELSE false END
 AND (nullif(trim(p_query),'') IS NULL OR strpos(lower(title),lower(left(trim(p_query),80)))>0
      OR strpos(lower(original_title),lower(left(trim(p_query),80)))>0
      OR lower(movie_qid)=lower(trim(p_query)) OR imdb_id=lower(trim(p_query)) OR tmdb_id::text=trim(p_query))
 ORDER BY legacy_id LIMIT greatest(1,least(coalesce(p_limit,30),50)) OFFSET greatest(0,least(coalesce(p_offset,0),100000))
)
SELECT public.reelspan_contribution_film_cards(coalesce((SELECT array_agg(movie_qid ORDER BY legacy_id) FROM page),ARRAY[]::text[]));
$$;
REVOKE ALL ON FUNCTION public.reelspan_missing_film_cards(text,text,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_missing_film_cards(text,text,integer,integer) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.reelspan_existing_film_candidates(
 p_title text DEFAULT '',p_tmdb_id text DEFAULT '',p_imdb_id text DEFAULT '')
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
WITH candidates AS (
 SELECT sm.movie_qid,sm.legacy_id,
 CASE WHEN sm.tmdb_id::text=trim(p_tmdb_id) OR sm.imdb_id=lower(trim(p_imdb_id)) THEN 0
      WHEN lower(trim(md.title))=lower(trim(p_title)) OR lower(trim(md.original_title))=lower(trim(p_title)) THEN 1 ELSE 2 END priority
 FROM public.story_movies sm LEFT JOIN public.movies md ON md.tmdb_id=sm.tmdb_id
 WHERE NOT sm.is_deleted AND (
   (nullif(trim(p_tmdb_id),'') IS NOT NULL AND sm.tmdb_id::text=trim(p_tmdb_id))
   OR (nullif(trim(p_imdb_id),'') IS NOT NULL AND sm.imdb_id=lower(trim(p_imdb_id)))
   OR (length(trim(p_title))>=2 AND (strpos(lower(md.title),lower(left(trim(p_title),200)))>0 OR strpos(lower(md.original_title),lower(left(trim(p_title),200)))>0)))
 ORDER BY priority,sm.legacy_id LIMIT 10
)
SELECT public.reelspan_contribution_film_cards(coalesce((SELECT array_agg(movie_qid ORDER BY priority,legacy_id) FROM candidates),ARRAY[]::text[]));
$$;
REVOKE ALL ON FUNCTION public.reelspan_existing_film_candidates(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_existing_film_candidates(text,text,text) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.reelspan_submit_contribution(p_payload jsonb, p_token uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ DECLARE k text; movie text; tmdb bigint; title_value text; imdb text; ts jsonb; ps jsonb; cs jsonb; entry jsonb; result uuid; owner_hash text; BEGIN IF p_token IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN RAISE EXCEPTION 'Invalid submission'; END IF; owner_hash := encode(extensions.digest(convert_to(p_token::text,'UTF8'),'sha256'),'hex'); k := p_payload->>'kind'; movie := nullif(trim(coalesce(p_payload->>'movie_qid','')),''); title_value := nullif(trim(coalesce(p_payload->>'title','')),''); imdb := nullif(trim(coalesce(p_payload->>'imdb_id','')),''); ts := coalesce(p_payload->'time_entries','[]'::jsonb); ps := coalesce(p_payload->'place_entries','[]'::jsonb); cs := coalesce(p_payload->'concept_entries','[]'::jsonb); IF k IS NULL OR k NOT IN ('new','existing') OR jsonb_typeof(ts)<>'array' OR jsonb_typeof(ps)<>'array' OR jsonb_typeof(cs)<>'array' OR jsonb_array_length(ts)>12 OR jsonb_array_length(ps)>12 OR jsonb_array_length(cs)>12 THEN RAISE EXCEPTION 'Invalid contribution fields'; END IF; FOR entry IN SELECT value FROM jsonb_array_elements(ts||ps||cs) LOOP IF jsonb_typeof(entry)<>'string' OR length(trim(entry #>> '{}')) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Time, place and tag entries must be text up to 160 characters'; END IF; END LOOP; IF k='existing' THEN IF movie IS NULL OR NOT EXISTS (SELECT 1 FROM public.story_movies m WHERE m.movie_qid=movie AND m.is_deleted=false) OR jsonb_array_length(ts)+jsonb_array_length(ps)=0 OR jsonb_array_length(cs)>0 OR title_value IS NOT NULL OR nullif(p_payload->>'tmdb_id','') IS NOT NULL OR imdb IS NOT NULL THEN RAISE EXCEPTION 'Existing film submissions accept only time and place corrections'; END IF; ELSE IF movie IS NOT NULL OR title_value IS NULL OR length(title_value)>200 OR jsonb_array_length(ts)=0 OR jsonb_array_length(ps)=0 OR (imdb IS NOT NULL AND imdb !~ '^tt[0-9]{7,10}$') THEN RAISE EXCEPTION 'New films require title, time and place'; END IF; IF nullif(trim(coalesce(p_payload->>'tmdb_id','')),'') IS NOT NULL THEN IF p_payload->>'tmdb_id' !~ '^[1-9][0-9]{0,11}$' THEN RAISE EXCEPTION 'Invalid TMDB ID'; END IF; tmdb := (p_payload->>'tmdb_id')::bigint; IF EXISTS (SELECT 1 FROM public.story_movies m WHERE m.tmdb_id=tmdb AND m.is_deleted=false) THEN RAISE EXCEPTION 'Film already in ReelSpan; submit a correction instead'; END IF; END IF;
 IF imdb IS NOT NULL AND EXISTS (SELECT 1 FROM public.story_movies m WHERE NOT m.is_deleted AND m.imdb_id=lower(imdb)) THEN
   RAISE EXCEPTION 'Film already in ReelSpan; submit a correction instead';
 END IF;
 IF tmdb IS NULL AND imdb IS NULL AND EXISTS (
   SELECT 1 FROM public.story_movies m JOIN public.movies md ON md.tmdb_id=m.tmdb_id
   WHERE NOT m.is_deleted AND (lower(trim(md.title))=lower(title_value) OR lower(trim(md.original_title))=lower(title_value))
 ) THEN RAISE EXCEPTION 'A film with this title already exists; correct it or supply a distinct TMDB/IMDb ID'; END IF;
 END IF; IF (SELECT count(*) FROM public.reelspan_contribution_submissions WHERE token_hash=owner_hash AND submitted_at>now()-interval '1 hour')>=5 OR (SELECT count(*) FROM public.reelspan_contribution_submissions WHERE token_hash=owner_hash AND submitted_at>now()-interval '1 day')>=15 THEN RAISE EXCEPTION 'Contribution limit reached; please try again later'; END IF; INSERT INTO public.reelspan_contribution_submissions(token_hash,submission_kind,movie_qid,tmdb_id,title,imdb_id,time_entries,place_entries,concept_entries) VALUES(owner_hash,k,movie,tmdb,title_value,imdb,ts,ps,cs) RETURNING id INTO result; RETURN result; END; $function$;
