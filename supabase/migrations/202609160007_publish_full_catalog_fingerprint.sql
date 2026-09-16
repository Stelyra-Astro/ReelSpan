-- Publish after the concept, search, and modern Where migrations are deployed and verified.
-- Client compares source_version + local cache format and resumes incomplete batches.
UPDATE public.dataset_meta
SET version = version + 1,
    source_version = '2026-09-16-full-catalog-when-search-v1',
    row_counts = jsonb_set(
      jsonb_set(
        jsonb_set(coalesce(row_counts,'{}'::jsonb), '{story_movies}',
          to_jsonb((SELECT count(*) FROM public.story_movies WHERE is_deleted=false))),
        '{story_time_concepts}',
          to_jsonb((SELECT count(*) FROM public.story_time_concepts WHERE is_deleted=false))),
      '{story_movie_concept_tags}',
          to_jsonb((SELECT count(*) FROM public.story_movie_concept_tags WHERE is_deleted=false))),
    updated_at = now()
WHERE dataset_name = 'reelspan_story_content' AND is_deleted=false;
