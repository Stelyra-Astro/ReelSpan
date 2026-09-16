-- Bump ONLY after the revised story periods and When catalog are committed.
-- A changed source_version forces old completed on-device snapshots to rebuild (first 250 films first).
UPDATE public.dataset_meta
SET version=3,
    source_version='2026-09-16-reelspan-where-when-contributions-v3',
    row_counts=jsonb_set(
      jsonb_set(coalesce(row_counts,'{}'::jsonb),'{story_time_concepts}',
       to_jsonb((SELECT count(*) FROM public.story_time_concepts WHERE is_deleted=false))),
      '{story_movies}',to_jsonb((SELECT count(*) FROM public.story_movies WHERE is_deleted=false))),
    updated_at=now()
WHERE dataset_name='reelspan_story_content' AND is_deleted=false AND version=2
 AND source_version='2026-09-16-full-catalog-when-search-v1';
