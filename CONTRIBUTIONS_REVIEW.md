# ReelSpan: review community contributions

Contributions are **proposals**, not writes to published movies. The app requires no account, and a per-install random UUID is held in Keychain; Supabase stores only the SHA-256 hash. Reinstalling or losing the device credential may make its previous history inaccessible. The owner can view their own most recent 200 submissions and **exact all-time status counts**.

## Review without an admin website

In the Supabase project's SQL Editor, signed in as its owner, inspect the private inbox:

```sql
SELECT id,submission_kind,movie_qid,title,tmdb_id,imdb_id,
       time_entries,place_entries,concept_entries,submitted_at,status,moderation_note
FROM public.reelspan_contribution_submissions
WHERE status = 'pending'
ORDER BY submitted_at ASC LIMIT 50;
```

Verify new titles/identifiers and all proposed times, places and tags against reliable evidence. Historical places and eras are allowed as **raw source evidence**. Resolve them to appropriate Wikidata QIDs and modern-location associations where evidence permits, without inventing modern borders. For existing-film suggestions, only time and place may be changed; new-film suggestions require a name and at least one time and place. **A moderator must deliberately apply accepted data to `story_movies`, `story_movie_periods`, `story_movie_locations`, and associated lookup tables as appropriate. Changing the inbox status alone does not publish anything.** Use a transaction for publication, preserve original evidence and source, ensure IDs and required relations are valid, and bump `dataset_meta.source_version` after a verified catalogue release to refresh on-device snapshots.

After the underlying changes are verified, record the outcome using the UUID shown by the query above:

```sql
UPDATE public.reelspan_contribution_submissions
SET status = 'accepted', reviewed_at = now(),
    moderation_note = 'Verified and published; supporting evidence checked.'
WHERE id = '<SUBMISSION_UUID>' AND status = 'pending';
```

If rejected, use `status = 'rejected'` with a short factual reason. Never expose the inbox table through a public read policy or ship a service-role key in the app; anonymous clients may only call the restricted submit/history/count RPCs. The submit RPC validates fields and applies per-token rate limits. Where's cached directory is rebuilt automatically on a subsequent scheduled refresh after story-location changes. A per-install token alone is **not** strong proof of human identity or a global anti-abuse control; add CAPTCHA/edge rate limiting if spam appears.

## Database and deployment notes

The original 10 tables have a same-project, **data-only** snapshot in `reelspan_backup_20260916`. It is not a portable/off-site backup, does not include storage objects, and must not be mistaken for a complete disaster-recovery copy. Obtain a verified external `supabase db dump` with database credentials before destructive database changes. All SQL files in `supabase/migrations/` are references for a fresh environment; this production project has already received migrations under different Supabase version IDs. **Do not blindly replay the directory with `db push`.** GitHub Pages files in the ZIP are not published until you deploy them via your GitHub Pages workflow; the phone simulator on the marketing page is illustrative and never submits real data.
