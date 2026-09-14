# Imported content data

`content_seed.sqlite` is generated from the regional CSV packages supplied in `output.zip`. The CSV files are authoritative; `sample_movies.json` and the language-pack fixtures are remnants of the earlier sample dataset and are not import inputs.

- `schema.sql` — schema matching the current seven CSV file types.
- `content_seed.sqlite` — imported core database used as the canonical output.
- `../Scripts/import_csv.py` — validates headers and JSON, merges repeated entity rows, preserves target-scoped location rows, and atomically replaces the database.

The same finished database and schema are copied to `ReelAtlas/Resources/` for the app bundle.
