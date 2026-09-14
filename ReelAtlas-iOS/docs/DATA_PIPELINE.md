# Reel Atlas CSV import contract

## Authoritative input

The import uses only the supplied regional copies of:

- `target.csv`
- `movies.csv`
- `movie_target_matches.csv`
- `movie_locations.csv`
- `movie_periods.csv`
- `places.csv`
- `normalization_issues.csv`

The importer itself does not query external services. Headers must match the upstream export contract and JSON values are validated. Movie metadata fields are deliberately discarded; only `id`, `movie_qid`, `imdb_id`, and `tmdb_movie_id` are persisted in `movies`.

Missing `tmdb_movie_id` values can be backfilled separately with `Scripts/backfill_tmdb_ids.py`. That tool queries only the Wikidata item's `P4947`, accepts a single positive integer, and writes a resumable checkpoint and audit report. It never guesses by title.

## Regional merge rules

Each non-empty regional directory contains one `target.csv` row. `movies`, `places`, and `movie_periods` are entity tables: identical rows repeated across regional packages are stored once, while conflicting rows for the same entity key stop the import.

`movie_target_matches` uses `(movie_qid, target_qid)` as its primary key. Duplicate pairs stop the import.

`movie_locations.is_target_match` is relative to the regional target. The importer therefore adds `source_target_qid` and stores every source `movie_locations` row under `(source_target_qid, movie_qid, raw_place_qid)`. This preserves both values when the same raw place is a match for one target and not for another.

`normalization_issues` also receives `source_target_qid`, preserving repeated target-specific issue reports.

## Runtime queries

The app searches indexed targets from `targets`, filters movies by `movie_target_matches`, applies story years through `movie_periods`, and reads raw narrative places from `movie_locations`. Movie metadata is fetched dynamically through `MovieMetadataService` and cached only after a user request.

## Import command

```bash
python3 Scripts/import_csv.py /path/to/output.zip Data/content_seed.sqlite \
  --mirror ReelAtlas/Resources/content_seed.sqlite
```

The importer validates CSV structure, JSON, duplicate keys, SQLite integrity, and foreign keys before atomically replacing the destination. If a destination exists, it first creates a timestamped backup beside it.
