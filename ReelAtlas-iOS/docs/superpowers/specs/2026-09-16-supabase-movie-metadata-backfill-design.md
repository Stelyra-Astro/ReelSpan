# Supabase Movie Metadata Backfill Design

## Goal

Populate the existing ReelSpan Supabase `public.movies` cache with TMDB movie
metadata so an iPhone without a local cache can resolve a movie from Supabase
before falling back to the existing Worker.

## Scope

- Change Supabase data only.
- Do not change the iOS application or its request order.
- Do not change the Cloudflare Worker.
- Do not upload, replace, or delete existing poster objects.
- Do not store actor or director image binaries in Supabase.
- Preserve TMDB `profilePath` strings so the existing app can load person images
  from the TMDB image CDN when a detail page is shown.

## Source and Destination

The canonical list of movies is `public.story_movies`, restricted to rows with a
non-null positive `tmdb_id`. For each ID, the existing public Worker endpoint
`/movie/{tmdb_id}?language=en-US` is the metadata source. The destination is an
idempotent upsert into `public.movies`, keyed by `tmdb_id`, with the returned
movie object stored in `payload`.

The first step is a one-movie probe. If calling the existing Worker already
creates a readable `public.movies` row, the full backfill may use the same
Worker path without privileged database credentials. If it does not, execution
must stop and obtain an approved Supabase administrative write path; neither the
iOS app nor the Worker will be modified as a workaround.

## Payload Contract

Each payload keeps the fields already decoded by `MovieMetadata`: `id`, `title`,
`originalTitle`, `overview`, `tagline`, `posterPath`, `posterUrl`, `backdropPath`,
`releaseDate`, `runtime`, `originalLanguage`, `status`, `genres`, `rating`,
`voteCount`, `popularity`, `directors`, and `cast`.

`directors` and `cast` may contain identity, name, role/order, and `profilePath`.
They must not contain uploaded image data. Existing Supabase poster URLs remain
unchanged. Missing posters may continue to use the current TMDB fallback; this
backfill does not upload them.

## Safety and Resumability

- Record the exact pre-backfill row count for `public.movies`.
- Use upserts keyed by `tmdb_id`; never truncate or delete tables.
- Process bounded batches with retry/backoff for transient failures.
- Persist progress outside the app database so a stopped run can resume.
- Treat 404/unavailable TMDB IDs as skipped records and report them.
- Do not log API keys, tokens, full credentials, or private headers.

## Verification

After the probe and after the full run:

1. Query the exact readable `public.movies` row count.
2. Sample early, middle, and late TMDB IDs.
3. Verify `payload.id = tmdb_id` and confirm non-empty overview/rating fields
   where TMDB supplies them.
4. Verify existing `posterUrl` values still point at the public `posters` bucket.
5. Verify cast/director entries contain paths only and no image binaries.
6. Request one populated movie using the same Supabase publishable key used by
   the iOS app, proving that the App can consume the result without a release.

