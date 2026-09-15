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

It does not query Wikidata, TMDB, or any other external source. Headers must exactly match the fields declared by the current schema. JSON values are validated and stored unchanged as SQLite `TEXT`.

## Regional merge rules

Each non-empty regional directory contains one `target.csv` row. `movies`, `places`, and `movie_periods` are entity tables: identical rows repeated across regional packages are stored once, while conflicting rows for the same entity key stop the import.

`movie_target_matches` uses `(movie_qid, target_qid)` as its primary key. Duplicate pairs stop the import.

`movie_locations.is_target_match` is relative to the regional target. The importer therefore adds `source_target_qid` and stores every source `movie_locations` row under `(source_target_qid, movie_qid, raw_place_qid)`. This preserves both values when the same raw place is a match for one target and not for another.

`normalization_issues` also receives `source_target_qid`, preserving repeated target-specific issue reports.

## Runtime queries

The uploader maps these tables to Supabase `story_*` tables without changing
the existing `public.movies` TMDB cache. The app checks `dataset_meta`, then
rebuilds a local SQLite cache from the public read-only Data API. Map and time
queries continue to run against that offline cache.

## Import command

```bash
python3 Scripts/import_csv.py /path/to/output.zip Data/content_seed.sqlite
python3 Scripts/upload_story_content.py Data/content_seed.sqlite --dry-run
```

The importer validates CSV structure, JSON, duplicate keys, SQLite integrity, and foreign keys before atomically replacing the destination. If a destination exists, it first creates a timestamped backup beside it.
