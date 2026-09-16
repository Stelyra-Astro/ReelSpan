# Supabase Movie Metadata Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Populate Supabase `public.movies` through the existing Worker without changing iOS, Worker code, poster objects, or actor image storage.

**Architecture:** Use the public `story_movies` table as the ID source and the existing `/movie/{tmdb_id}?language=en-US` Worker route as the only metadata fetch path. First prove that one Worker request creates a row readable through the same publishable key used by iOS; only then run a resumable bounded-concurrency backfill and verify the resulting Supabase rows.

**Tech Stack:** Python 3 standard library, Supabase PostgREST, existing Cloudflare Worker, `unittest`

**Spec:** `ReelAtlas-iOS/docs/superpowers/specs/2026-09-16-supabase-movie-metadata-backfill-design.md`

## Global Constraints

- Change Supabase data only; do not modify iOS or Worker behavior.
- Do not upload, overwrite, or delete poster objects.
- Do not upload actor or director image binaries.
- Preserve `profilePath` strings in director and cast metadata.
- Use idempotent Worker requests and resumable progress; never truncate or delete tables.
- Never print or persist private credentials.

---

### Task 1: Prove the Existing Worker Write-Back Contract

**Files:**
- No repository changes

**Interfaces:**
- Consumes: `GET /movie/{tmdb_id}?language=en-US`, Supabase `GET /rest/v1/movies`
- Produces: verified decision that the existing Worker either does or does not create an iOS-readable `public.movies` row

- [ ] **Step 1: Record the exact pre-probe count**

Query `public.movies?select=tmdb_id&limit=1` with `Prefer: count=exact` and the app publishable key.

Expected: `Content-Range: */0` before the first probe.

- [ ] **Step 2: Select a safe probe ID**

Use TMDB ID `603`, whose existing poster object has already returned HTTP 200. This avoids creating or replacing a poster as part of the probe.

- [ ] **Step 3: Request the movie through the existing Worker**

Run:

```bash
curl -fsS 'https://tmdb.xiaoguiwk.top/movie/603?language=en-US'
```

Expected: HTTP 200 JSON with `id` equal to `603`, non-empty `title`, and the existing Supabase `posterUrl` when the Worker recognizes the stored poster.

- [ ] **Step 4: Verify Supabase write-back**

Query:

```text
/rest/v1/movies?tmdb_id=eq.603&select=tmdb_id,payload&limit=1
```

Expected: one row with `tmdb_id = 603` and `payload.id = 603`.

- [ ] **Step 5: Enforce the stop condition**

If no row appears, stop the implementation. Report that Supabase administrative write access is required; do not change the Worker or iOS as a workaround.

---

### Task 2: Add a Resumable Worker Backfill Runner

**Files:**
- Create: `ReelAtlas-iOS/Scripts/backfill_supabase_movie_metadata.py`
- Create: `ReelAtlas-iOS/Scripts/tests/test_backfill_supabase_movie_metadata.py`

**Interfaces:**
- Consumes: `SUPABASE_PUBLISHABLE_KEY`, Supabase project ref, Worker base URL, JSON checkpoint path
- Produces: `fetch_story_movie_ids() -> list[int]`, `fetch_worker_movie(tmdb_id: int) -> dict[str, object]`, `BackfillState`, and CLI exit status

- [ ] **Step 1: Write failing payload-boundary tests**

Add tests proving that `validate_payload(payload, tmdb_id)`:

```python
def test_validate_payload_accepts_profile_paths_without_image_data():
    payload = {
        "id": 603,
        "title": "The Matrix",
        "overview": "A description",
        "rating": 8.2,
        "voteCount": 26000,
        "directors": [{"id": 1, "name": "Director", "profilePath": "/p.jpg"}],
        "cast": [{"id": 2, "name": "Actor", "profilePath": "/a.jpg", "order": 0}],
    }
    validate_payload(payload, 603)


def test_validate_payload_rejects_embedded_person_image_data():
    payload = {
        "id": 603,
        "title": "The Matrix",
        "directors": [],
        "cast": [{"id": 2, "name": "Actor", "imageData": "base64"}],
    }
    with self.assertRaises(ValueError):
        validate_payload(payload, 603)
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
python3 -m unittest ReelAtlas-iOS/Scripts/tests/test_backfill_supabase_movie_metadata.py -v
```

Expected: FAIL because the backfill module does not exist.

- [ ] **Step 3: Implement strict payload validation**

Implement:

```python
def validate_payload(payload: dict[str, object], tmdb_id: int) -> None:
    if payload.get("id") != tmdb_id:
        raise ValueError("Worker payload ID mismatch")
    if not isinstance(payload.get("title"), str) or not payload["title"].strip():
        raise ValueError("Worker payload is missing title")
    for group in ("directors", "cast"):
        for person in payload.get(group, []):
            forbidden = {"image", "imageData", "profileImage", "profileData"}
            if forbidden.intersection(person):
                raise ValueError(f"{group} contains embedded image data")
```

- [ ] **Step 4: Write failing resume and retry tests**

Use in-memory fake transports to prove:

- completed IDs are skipped after loading a checkpoint;
- HTTP 404 IDs are recorded as skipped;
- HTTP 429 and 5xx responses retry up to the configured limit;
- terminal failures are recorded without discarding earlier progress;
- concurrency never exceeds the configured worker count.

- [ ] **Step 5: Implement the standard-library runner**

Implement a CLI with these exact options:

```text
--project-ref injisguyqfxfwgnbtghe
--worker-base-url https://tmdb.xiaoguiwk.top
--checkpoint <path>
--concurrency 4
--limit <optional positive integer>
--start-after <optional tmdb id>
```

Read `SUPABASE_PUBLISHABLE_KEY` from the environment, page through
`story_movies` ordered by `tmdb_id`, call the Worker with bounded concurrency,
validate every response, and atomically replace the checkpoint after each
completed batch. The checkpoint JSON must contain sorted `completed`, `skipped`,
and `failed` ID collections plus counters and the last update timestamp.

- [ ] **Step 6: Run the focused tests and verify pass**

Run:

```bash
python3 -m unittest ReelAtlas-iOS/Scripts/tests/test_backfill_supabase_movie_metadata.py -v
```

Expected: all tests PASS.

- [ ] **Step 7: Commit the runner**

```bash
git add ReelAtlas-iOS/Scripts/backfill_supabase_movie_metadata.py ReelAtlas-iOS/Scripts/tests/test_backfill_supabase_movie_metadata.py
git commit -m "feat: add resumable Supabase metadata backfill"
```

---

### Task 3: Run a Bounded Production Pilot

**Files:**
- Create at runtime outside Git: `/tmp/reelspan-metadata-backfill.json`

**Interfaces:**
- Consumes: Task 2 CLI and verified Task 1 write-back
- Produces: 25 newly processed IDs plus a durable checkpoint

- [ ] **Step 1: Record the pre-pilot count**

Use the exact PostgREST count query from Task 1 and retain the count in the run log.

- [ ] **Step 2: Run 25 movies with concurrency 2**

Run the backfill with `--limit 25 --concurrency 2` and the `/tmp` checkpoint.

Expected: exit status 0 with completed/skipped/failed totals and no credentials in output.

- [ ] **Step 3: Verify the post-pilot count and payloads**

Confirm the row count increased by the number of successful unique IDs. Sample
three rows and verify ID equality, text/rating fields, Supabase poster URLs when
the corresponding poster exists, and absence of embedded person image data.

- [ ] **Step 4: Stop on anomalous error rate**

Do not proceed if more than 20% of pilot IDs fail for reasons other than 404, or
if any successful Worker response fails payload validation.

---

### Task 4: Complete and Verify the Production Backfill

**Files:**
- Reuse at runtime: `/tmp/reelspan-metadata-backfill.json`
- Create: `Artifacts/supabase-movie-metadata-backfill-report.json`

**Interfaces:**
- Consumes: successful Task 3 checkpoint
- Produces: completed Supabase cache and an audit report without secrets

- [ ] **Step 1: Resume the full backfill**

Run with `--concurrency 4` and no `--limit`, reusing the pilot checkpoint. Keep
the job in a persistent terminal session and monitor progress without restarting
completed IDs.

- [ ] **Step 2: Reconcile counts**

Compare:

- distinct positive, non-null `story_movies.tmdb_id` count;
- exact readable `public.movies` count;
- checkpoint completed/skipped/failed totals.

Explain every difference with explicit duplicate, skipped, or failed counts.

- [ ] **Step 3: Sample content across the ID range**

Verify at least five early, five middle, and five late IDs using the app's
publishable key. Check `payload.id`, title, overview when supplied, rating,
voteCount, posterUrl behavior, and person path-only metadata.

- [ ] **Step 4: Write the audit report**

Write `Artifacts/supabase-movie-metadata-backfill-report.json` containing start
and finish timestamps, pre/post counts, completed/skipped/failed totals, sampled
IDs, and validation results. Do not include keys, authorization headers, or full
payloads.

- [ ] **Step 5: Run final verification**

Run:

```bash
python3 -m unittest discover -s ReelAtlas-iOS/Scripts/tests -v
git diff --check
```

Expected: all script tests PASS and `git diff --check` emits no output.

- [ ] **Step 6: Commit the audit report**

```bash
git add Artifacts/supabase-movie-metadata-backfill-report.json
git commit -m "docs: record Supabase metadata backfill"
```

