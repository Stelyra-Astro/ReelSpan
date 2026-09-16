-- Read-only diff metadata for already public story content; no source data/policy changes.
CREATE SCHEMA IF NOT EXISTS reelspan_sync;
GRANT USAGE ON SCHEMA reelspan_sync TO anon, authenticated;

CREATE OR REPLACE FUNCTION reelspan_sync.canonical(p_value jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE STRICT SECURITY INVOKER SET search_path = '' AS $$
DECLARE result text; entry record;
BEGIN
  CASE jsonb_typeof(p_value)
    WHEN 'null' THEN RETURN 'n;';
    WHEN 'boolean' THEN RETURN CASE WHEN p_value='true'::jsonb THEN 'b1;' ELSE 'b0;' END;
    WHEN 'number' THEN RETURN 'd' || trim_scale((p_value #>> '{}')::numeric)::text || ';';
    WHEN 'string' THEN RETURN 's' || octet_length(p_value #>> '{}')::text || ':' || (p_value #>> '{}');
    WHEN 'array' THEN
      result := 'a' || jsonb_array_length(p_value)::text || ':';
      FOR entry IN SELECT value FROM jsonb_array_elements(p_value) LOOP
        result := result || reelspan_sync.canonical(entry.value);
      END LOOP;
      RETURN result;
    WHEN 'object' THEN
      result := 'o' || (SELECT count(*) FROM jsonb_each(p_value))::text || ':';
      FOR entry IN SELECT key,value FROM jsonb_each(p_value) ORDER BY key COLLATE "C" LOOP
        result := result || reelspan_sync.canonical(to_jsonb(entry.key)) || reelspan_sync.canonical(entry.value);
      END LOOP;
      RETURN result;
  END CASE;
  RAISE EXCEPTION 'Unsupported JSON type';
END $$;
REVOKE ALL ON FUNCTION reelspan_sync.canonical(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reelspan_sync.canonical(jsonb) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.reelspan_catalog_index(
  p_table text, p_after text DEFAULT '', p_limit integer DEFAULT 5000)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
DECLARE relation_name text; key_sql text; value_sql text; result jsonb;
BEGIN
  CASE p_table
    WHEN 'story_targets' THEN relation_name := 'story_targets'; key_sql := 't.target_qid::text'; value_sql := 'jsonb_build_array(t.target_qid, t.target_kind, t.name_en, t.name_zh, t.labels, t.admin1_qid, t.admin1_name_en, t.country_qid, t.country_name_en, t.film_count, t.candidate_count)';
    WHEN 'story_places' THEN relation_name := 'story_places'; key_sql := 't.place_qid::text'; value_sql := 'jsonb_build_array(t.place_qid, t.name_en, t.name_zh, t.labels, t.type_qids, t.p131_qids, t.location_qids, t.country_qids, t.present_day_qids, t.replaced_by_qids, t.followed_by_qids, t.coordinate, t.dissolved_date)';
    WHEN 'story_time_concepts' THEN relation_name := 'story_time_concepts'; key_sql := 't.concept_qid::text'; value_sql := 'jsonb_build_array(t.concept_qid, t.category, t.name_en, t.name_zh, t.labels, t.start_year, t.end_year)';
    WHEN 'story_movies' THEN relation_name := 'story_movies'; key_sql := 't.movie_qid::text'; value_sql := 'jsonb_build_array(t.movie_qid, t.legacy_id, t.imdb_id, t.tmdb_id)';
    WHEN 'story_movie_locations' THEN relation_name := 'story_movie_locations'; key_sql := 't.id::text'; value_sql := 'jsonb_build_array(t.id, t.source_target_qid, t.movie_qid, CASE WHEN t.is_target_match IS NULL THEN NULL WHEN t.is_target_match THEN 1 ELSE 0 END, t.raw_place_qid, t.raw_place_name_en, t.raw_place_name_zh, t.raw_place_labels, t.historical_capital_qid, t.historical_capital_name_en, t.modern_place_qid, t.modern_place_name_en, t.city_qid, t.city_name_en, t.city_name_zh, t.admin1_qid, t.admin1_name_en, t.admin1_name_zh, t.country_qid, t.country_name_en, t.country_name_zh, t.normalization_method, t.normalization_path, t.confidence, t.status, t.notes)';
    WHEN 'story_movie_periods' THEN relation_name := 'story_movie_periods'; key_sql := 't.movie_qid::text || ''|'' || t.period_qid::text'; value_sql := 'jsonb_build_array(t.movie_qid, t.period_qid, t.period_name_en, t.period_name_zh, t.period_labels, t.start_year, t.end_year, t.interval_method)';
    WHEN 'story_movie_target_matches' THEN relation_name := 'story_movie_target_matches'; key_sql := 't.movie_qid::text || ''|'' || t.target_qid::text'; value_sql := 'jsonb_build_array(t.movie_qid, t.target_qid, t.target_kind, t.matched_raw_location_count, t.matched_raw_place_qids, t.best_confidence)';
    ELSE RAISE EXCEPTION 'Unsupported catalog table';
  END CASE;
  EXECUTE format(
    'SELECT coalesce(jsonb_agg(jsonb_build_object(''row_key'',row_key,''fingerprint'',fingerprint) ORDER BY row_key COLLATE "C"),''[]''::jsonb) FROM (SELECT %s AS row_key, md5(reelspan_sync.canonical(%s)) AS fingerprint FROM public.%I t WHERE NOT t.is_deleted AND (%s) COLLATE "C" > $1 COLLATE "C" ORDER BY (%s) COLLATE "C" LIMIT $2) page',
    key_sql,value_sql,relation_name,key_sql,key_sql)
    INTO result USING coalesce(p_after,''),greatest(1,least(coalesce(p_limit,5000),5000));
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.reelspan_catalog_index(text,text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reelspan_catalog_index(text,text,integer) TO anon, authenticated;
COMMENT ON FUNCTION public.reelspan_catalog_index(text,text,integer) IS
'Public active-row ID/content-fingerprint index for incremental SQLite reconciliation. Honors caller RLS. Does not expose submissions or deleted content.';
