# Deferred search redesign — NOT DEPLOYED

These SQL drafts are deliberately outside `supabase/migrations/`. Do not apply them automatically.

The production write-lock/backfill deployment was rejected by safety review and then deferred by the user. Neither preparation nor activation has run. The existing field-indexed delegate remains live.

Proposed approach: inline overlapping text chunks (384 characters, step 305) preserve all <=80-character literal substrings, including boundaries, without repeatedly reading large cast JSON. Full-title flags apply only to the first complete chunk. Source write locks would protect consistent backfill and trigger installation; that needs explicit operational approval and an acceptable maintenance window or a safer online backfill design.

Before deployment: isolated database tests for boundary/Unicode/literal matching, title scores, both triggers' insert/update/delete/key changes, concurrent updates, full current-snapshot parity, high-frequency load and all filter/sort/pagination combinations. No performance or deployment success is claimed for these drafts.
