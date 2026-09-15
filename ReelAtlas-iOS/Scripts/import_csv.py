#!/usr/bin/env python3
"""Build the ReelSpan content database from the supplied regional CSV packages."""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import sqlite3
import tempfile
import zipfile
from collections.abc import Iterable
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


CSV_HEADERS = {
    "target.csv": (
        "target_qid", "target_kind", "name_en", "name_zh", "labels_json",
        "admin1_qid", "admin1_name_en", "country_qid", "country_name_en",
        "film_count", "candidate_count",
    ),
    "movies.csv": (
        "movie_qid", "title_en", "title_zh", "labels_json", "release_date",
        "release_year", "director_qids_json", "directors_json",
        "origin_country_qids_json", "origin_countries_json", "genre_qids_json",
        "genres_json", "original_language_qids_json", "original_languages_json",
        "imdb_id", "tmdb_movie_id", "runtime", "image", "period_qids_json",
        "tmdb_overview", "tmdb_tagline", "overview_en", "overview_source",
        "overview_source_title", "overview_source_url", "overview_license",
    ),
    "movie_target_matches.csv": (
        "movie_qid", "target_qid", "target_kind", "matched_raw_location_count",
        "matched_raw_place_qids_json", "best_confidence",
    ),
    "movie_locations.csv": (
        "movie_qid", "is_target_match", "raw_place_qid", "raw_place_name_en",
        "raw_place_name_zh", "raw_place_labels_json", "historical_capital_qid",
        "historical_capital_name_en", "modern_place_qid", "modern_place_name_en",
        "city_qid", "city_name_en", "city_name_zh", "admin1_qid",
        "admin1_name_en", "admin1_name_zh", "country_qid", "country_name_en",
        "country_name_zh", "normalization_method", "normalization_path",
        "confidence", "status", "notes",
    ),
    "movie_periods.csv": (
        "movie_qid", "period_qid", "period_name_en", "period_name_zh",
        "period_labels_json", "start_year", "end_year", "interval_method",
    ),
    "places.csv": (
        "place_qid", "name_en", "name_zh", "labels_json", "type_qids_json",
        "p131_qids_json", "location_qids_json", "country_qids_json",
        "present_day_qids_json", "replaced_by_qids_json", "followed_by_qids_json",
        "coordinate", "dissolved_date",
    ),
    "normalization_issues.csv": (
        "movie_qid", "raw_place_qid", "raw_place_name_en", "raw_place_name_zh",
        "issue_type", "status", "confidence", "notes",
    ),
}

JSON_COLUMNS = {
    "target.csv": {"labels_json"},
    "movies.csv": {
        "labels_json", "director_qids_json", "directors_json",
        "origin_country_qids_json", "origin_countries_json", "genre_qids_json",
        "genres_json", "original_language_qids_json", "original_languages_json",
        "period_qids_json",
    },
    "movie_target_matches.csv": {"matched_raw_place_qids_json"},
    "movie_locations.csv": {"raw_place_labels_json"},
    "movie_periods.csv": {"period_labels_json"},
    "places.csv": {
        "labels_json", "type_qids_json", "p131_qids_json", "location_qids_json",
        "country_qids_json", "present_day_qids_json", "replaced_by_qids_json",
        "followed_by_qids_json",
    },
    "normalization_issues.csv": set(),
}

INTEGER_COLUMNS = {
    "target.csv": {"film_count", "candidate_count"},
    "movies.csv": {"release_year", "tmdb_movie_id"},
    "movie_target_matches.csv": {"matched_raw_location_count"},
    "movie_locations.csv": {"is_target_match"},
    "movie_periods.csv": {"start_year", "end_year"},
    "places.csv": set(),
    "normalization_issues.csv": set(),
}

REAL_COLUMNS = {
    "target.csv": set(),
    "movies.csv": {"runtime"},
    "movie_target_matches.csv": {"best_confidence"},
    "movie_locations.csv": {"confidence"},
    "movie_periods.csv": set(),
    "places.csv": set(),
    "normalization_issues.csv": {"confidence"},
}

NULLABLE_COLUMNS = {
    "target.csv": {"admin1_qid", "admin1_name_en"},
    "movies.csv": {
        "release_date", "release_year", "imdb_id", "tmdb_movie_id", "runtime", "image",
    },
    "movie_target_matches.csv": set(),
    "movie_locations.csv": {
        "historical_capital_qid", "historical_capital_name_en", "modern_place_qid",
        "modern_place_name_en", "city_qid", "city_name_en", "city_name_zh",
        "admin1_qid", "admin1_name_en", "admin1_name_zh", "country_qid",
        "country_name_en", "country_name_zh", "normalization_path", "notes",
    },
    "movie_periods.csv": {"start_year", "end_year"},
    "places.csv": {"coordinate", "dissolved_date"},
    "normalization_issues.csv": {"notes"},
}

GLOBAL_LOCATION_HEADERS = tuple(
    column for column in CSV_HEADERS["movie_locations.csv"] if column != "is_target_match"
)
GLOBAL_FILENAMES = (
    "movies.csv", "movie_locations.csv", "movie_periods.csv", "places.csv",
    "normalization_issues.csv",
)

TABLE_FOR_CSV = {
    "target.csv": "targets",
    "movies.csv": "movies",
    "movie_target_matches.csv": "movie_target_matches",
    "movie_locations.csv": "movie_locations",
    "movie_periods.csv": "movie_periods",
    "places.csv": "places",
    "normalization_issues.csv": "normalization_issues",
}

ENTITY_KEYS = {
    "target.csv": ("target_qid",),
    "movies.csv": ("movie_qid",),
    "movie_periods.csv": ("movie_qid", "period_qid"),
    "places.csv": ("place_qid",),
}


class ImportValidationError(ValueError):
    pass


def _read_csv(path: Path) -> list[dict[str, str]]:
    if path.stat().st_size == 0:
        return []
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        actual = tuple(reader.fieldnames or ())
        expected = CSV_HEADERS[path.name]
        if actual != expected:
            raise ImportValidationError(f"{path}: expected header {expected}, found {actual}")
        rows = []
        for line_number, row in enumerate(reader, 2):
            if None in row:
                raise ImportValidationError(f"{path}:{line_number}: extra CSV values {row[None]}")
            for column in JSON_COLUMNS[path.name]:
                try:
                    json.loads(row[column])
                except (TypeError, json.JSONDecodeError) as error:
                    raise ImportValidationError(
                        f"{path}:{line_number}: invalid JSON in {column}: {error}"
                    ) from error
            rows.append(row)
        return rows


def _regional_directories(root: Path) -> list[Path]:
    if (root / "output").is_dir():
        root = root / "output"
    directories = sorted(
        path for path in root.iterdir()
        if path.is_dir() and path.name != "__MACOSX" and any((path / name).exists() for name in CSV_HEADERS)
    )
    if not directories:
        raise ImportValidationError(f"No regional CSV directories found under {root}")
    return directories


def _collect(root: Path) -> tuple[dict[str, list[tuple[str | None, dict[str, str]]]], dict[str, int]]:
    collected = {name: [] for name in CSV_HEADERS}
    source_counts = {TABLE_FOR_CSV[name]: 0 for name in CSV_HEADERS}
    for directory in _regional_directories(root):
        files = {name: directory / name for name in CSV_HEADERS}
        missing = [name for name, path in files.items() if not path.exists()]
        if missing:
            raise ImportValidationError(f"{directory}: missing files {missing}")
        rows_by_file = {name: _read_csv(path) for name, path in files.items()}
        target_rows = rows_by_file["target.csv"]
        if not target_rows:
            if any(rows_by_file[name] for name in CSV_HEADERS if name != "target.csv"):
                raise ImportValidationError(f"{directory}: data rows exist without a target row")
            continue
        if len(target_rows) != 1:
            raise ImportValidationError(f"{directory}: target.csv must contain exactly one row")
        source_target_qid = target_rows[0]["target_qid"]
        for filename, rows in rows_by_file.items():
            source_counts[TABLE_FOR_CSV[filename]] += len(rows)
            for row in rows:
                collected[filename].append((source_target_qid, row))
    return collected, source_counts


def _deduplicate_entities(
    filename: str, records: list[tuple[str | None, dict[str, str]]]
) -> list[dict[str, str]]:
    keys = ENTITY_KEYS[filename]
    by_key: dict[tuple[str, ...], dict[str, str]] = {}
    for _, row in records:
        key = tuple(row[column] for column in keys)
        previous = by_key.get(key)
        if previous is not None and previous != row:
            changed = [column for column in row if previous[column] != row[column]]
            raise ImportValidationError(f"{filename}: conflicting rows for {key}; changed fields: {changed}")
        by_key[key] = row
    return [by_key[key] for key in sorted(by_key)]


def _convert(filename: str, column: str, value: str) -> Any:
    if value == "" and column in NULLABLE_COLUMNS[filename]:
        return None
    if column in INTEGER_COLUMNS[filename]:
        try:
            return int(value)
        except ValueError as error:
            raise ImportValidationError(f"{filename}: {column} is not an integer: {value!r}") from error
    if column in REAL_COLUMNS[filename]:
        try:
            return float(value)
        except ValueError as error:
            raise ImportValidationError(f"{filename}: {column} is not a number: {value!r}") from error
    return value


def _insert_rows(
    connection: sqlite3.Connection,
    filename: str,
    rows: Iterable[dict[str, str]],
    extra_columns: tuple[str, ...] = (),
) -> int:
    columns = extra_columns + CSV_HEADERS[filename]
    sql = (
        f"INSERT INTO {TABLE_FOR_CSV[filename]} ({','.join(columns)}) "
        f"VALUES ({','.join('?' for _ in columns)})"
    )
    count = 0
    for row in rows:
        connection.execute(sql, tuple(row[column] for column in extra_columns) + tuple(
            _convert(filename, column, row[column]) for column in CSV_HEADERS[filename]
        ))
        count += 1
    return count


def _backup_path(database_path: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    candidate = database_path.with_name(f"{database_path.name}.backup-{timestamp}")
    suffix = 1
    while candidate.exists():
        candidate = database_path.with_name(f"{database_path.name}.backup-{timestamp}-{suffix}")
        suffix += 1
    return candidate


def import_csv_tree(
    input_root: Path | str,
    database_path: Path | str,
    schema_path: Path | str | None = None,
) -> dict[str, int]:
    input_root = Path(input_root)
    database_path = Path(database_path)
    schema_path = Path(schema_path) if schema_path else Path(__file__).resolve().parents[1] / "Data" / "schema.sql"
    collected, source_counts = _collect(input_root)

    entity_rows = {name: _deduplicate_entities(name, collected[name]) for name in ENTITY_KEYS}
    match_rows = [row for _, row in collected["movie_target_matches.csv"]]
    match_keys = [(row["movie_qid"], row["target_qid"]) for row in match_rows]
    if len(match_keys) != len(set(match_keys)):
        duplicates = sorted(key for key in set(match_keys) if match_keys.count(key) > 1)
        raise ImportValidationError(f"movie_target_matches.csv: duplicate movie_qid + target_qid: {duplicates[:10]}")

    database_path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(prefix=f".{database_path.name}.", suffix=".tmp", dir=database_path.parent, delete=False)
    temporary_path = Path(handle.name)
    handle.close()
    temporary_path.unlink()
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(temporary_path)
        connection.execute("PRAGMA foreign_keys = ON")
        connection.executescript(schema_path.read_text(encoding="utf-8"))

        counts: dict[str, int] = {}
        target_rows = entity_rows["target.csv"]
        counts["targets"] = _insert_rows(connection, "target.csv", target_rows)

        movie_rows = entity_rows["movies.csv"]
        movie_ids = {row["movie_qid"]: index for index, row in enumerate(movie_rows, 1)}
        movie_columns = ("movie_qid", "id") + CSV_HEADERS["movies.csv"][1:]
        movie_sql = (
            f"INSERT INTO movies ({','.join(movie_columns)}) "
            f"VALUES ({','.join('?' for _ in movie_columns)})"
        )
        for row in movie_rows:
            connection.execute(movie_sql, (
                row["movie_qid"], movie_ids[row["movie_qid"]],
                *(_convert("movies.csv", column, row[column]) for column in CSV_HEADERS["movies.csv"][1:]),
            ))
        counts["movies"] = len(movie_rows)

        counts["places"] = _insert_rows(connection, "places.csv", entity_rows["places.csv"])
        counts["movie_target_matches"] = _insert_rows(connection, "movie_target_matches.csv", match_rows)
        counts["movie_periods"] = _insert_rows(connection, "movie_periods.csv", entity_rows["movie_periods.csv"])

        location_rows = []
        for source_target_qid, row in collected["movie_locations.csv"]:
            location_rows.append({"source_target_qid": source_target_qid, **row})
        counts["movie_locations"] = _insert_rows(
            connection, "movie_locations.csv", location_rows, ("source_target_qid",)
        )

        issue_rows = []
        for source_target_qid, row in collected["normalization_issues.csv"]:
            issue_rows.append({"source_target_qid": source_target_qid, **row})
        counts["normalization_issues"] = _insert_rows(
            connection, "normalization_issues.csv", issue_rows, ("source_target_qid",)
        )

        metadata = {
            "database_version": "2026-09-13-csv-v1",
            "source_format": "regional-csv-output-v1",
            "source_rows_json": json.dumps(source_counts, sort_keys=True, separators=(",", ":")),
            "imported_rows_json": json.dumps(counts, sort_keys=True, separators=(",", ":")),
        }
        connection.executemany("INSERT INTO metadata(key,value) VALUES (?,?)", metadata.items())

        foreign_key_errors = connection.execute("PRAGMA foreign_key_check").fetchall()
        if foreign_key_errors:
            raise ImportValidationError(f"Foreign key violations: {foreign_key_errors[:10]}")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise ImportValidationError(f"SQLite integrity check failed: {integrity}")
        connection.commit()
        connection.close()
        connection = None

        if database_path.exists():
            shutil.copy2(database_path, _backup_path(database_path))
        os.replace(temporary_path, database_path)
        return counts
    except Exception:
        if connection is not None:
            connection.close()
        temporary_path.unlink(missing_ok=True)
        raise


def _resolve_input(path: Path, stack: ExitStack) -> Path:
    if path.is_dir():
        return path
    if not zipfile.is_zipfile(path):
        raise ImportValidationError(f"Input must be a directory or ZIP archive: {path}")
    temporary = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="reel-atlas-csv-")))
    with zipfile.ZipFile(path) as archive:
        archive.extractall(temporary)
    return temporary


def import_csv_source(
    input_path: Path | str,
    database_path: Path | str,
    schema_path: Path | str | None = None,
) -> dict[str, int]:
    with ExitStack() as stack:
        input_root = _resolve_input(Path(input_path), stack)
        return import_csv_tree(input_root, database_path, schema_path)


def _global_directory(root: Path) -> Path:
    candidates = [root, *sorted(path for path in root.rglob("*") if path.is_dir())]
    for candidate in candidates:
        if all((candidate / filename).is_file() for filename in GLOBAL_FILENAMES):
            return candidate
    raise ImportValidationError(f"No global CSV export found under {root}")


def _read_global_csv(path: Path) -> list[dict[str, str]]:
    expected = GLOBAL_LOCATION_HEADERS if path.name == "movie_locations.csv" else CSV_HEADERS[path.name]
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        actual = tuple(reader.fieldnames or ())
        if actual != expected:
            raise ImportValidationError(f"{path}: expected header {expected}, found {actual}")
        rows = list(reader)
    for line_number, row in enumerate(rows, 2):
        if None in row:
            raise ImportValidationError(f"{path}:{line_number}: extra CSV values {row[None]}")
        for column in JSON_COLUMNS[path.name]:
            try:
                json.loads(row[column])
            except (TypeError, json.JSONDecodeError) as error:
                raise ImportValidationError(
                    f"{path}:{line_number}: invalid JSON in {column}: {error}"
                ) from error
    return rows


def _copy_existing_database(connection: sqlite3.Connection, source: Path) -> None:
    connection.execute("ATTACH DATABASE ? AS old", (str(source),))
    tables = {
        "targets": CSV_HEADERS["target.csv"],
        "movies": ("movie_qid", "id", *CSV_HEADERS["movies.csv"][1:]),
        "movie_target_matches": CSV_HEADERS["movie_target_matches.csv"],
        "places": CSV_HEADERS["places.csv"],
        "movie_locations": ("source_target_qid", *CSV_HEADERS["movie_locations.csv"]),
        "movie_periods": CSV_HEADERS["movie_periods.csv"],
        "normalization_issues": (
            "source_target_qid", *CSV_HEADERS["normalization_issues.csv"]
        ),
    }
    for table, columns in tables.items():
        old_columns = {
            row[1] for row in connection.execute(f"PRAGMA old.table_info({table})")
        }
        copy_columns = tuple(column for column in columns if column in old_columns)
        names = ",".join(copy_columns)
        connection.execute(f"INSERT INTO {table} ({names}) SELECT {names} FROM old.{table}")
    connection.execute("INSERT INTO metadata SELECT * FROM old.metadata")
    connection.commit()
    connection.execute("DETACH DATABASE old")


def merge_global_csv_tree(
    input_root: Path | str,
    database_path: Path | str,
    schema_path: Path | str | None = None,
) -> dict[str, int]:
    input_root = _global_directory(Path(input_root))
    database_path = Path(database_path)
    if not database_path.is_file():
        raise ImportValidationError(f"Existing database is required for a global merge: {database_path}")
    schema_path = Path(schema_path) if schema_path else Path(__file__).resolve().parents[1] / "Data" / "schema.sql"
    rows = {filename: _read_global_csv(input_root / filename) for filename in GLOBAL_FILENAMES}

    for filename, keys in {
        "movies.csv": ("movie_qid",), "places.csv": ("place_qid",),
        "movie_locations.csv": ("movie_qid", "raw_place_qid"),
        "movie_periods.csv": ("movie_qid", "period_qid"),
    }.items():
        values = [tuple(row[key] for key in keys) for row in rows[filename]]
        if len(values) != len(set(values)):
            raise ImportValidationError(f"{filename}: duplicate keys in global export")

    handle = tempfile.NamedTemporaryFile(prefix=f".{database_path.name}.", suffix=".tmp", dir=database_path.parent, delete=False)
    temporary_path = Path(handle.name)
    handle.close()
    temporary_path.unlink()
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(temporary_path)
        connection.execute("PRAGMA foreign_keys = ON")
        connection.executescript(schema_path.read_text(encoding="utf-8"))
        _copy_existing_database(connection, database_path)

        next_movie_id = connection.execute("SELECT COALESCE(MAX(id),0) FROM movies").fetchone()[0] + 1
        movie_columns = ("movie_qid", "id", *CSV_HEADERS["movies.csv"][1:])
        movie_updates = ",".join(
            f"{column}=excluded.{column}" for column in CSV_HEADERS["movies.csv"][1:]
        )
        movie_sql = (
            f"INSERT INTO movies ({','.join(movie_columns)}) VALUES ({','.join('?' for _ in movie_columns)}) "
            f"ON CONFLICT(movie_qid) DO UPDATE SET {movie_updates}"
        )
        for row in rows["movies.csv"]:
            before = connection.total_changes
            connection.execute(movie_sql, (
                row["movie_qid"], next_movie_id,
                *(_convert("movies.csv", column, row[column]) for column in CSV_HEADERS["movies.csv"][1:]),
            ))
            if connection.total_changes > before:
                next_movie_id += 1

        for filename in ("places.csv", "movie_periods.csv"):
            columns = CSV_HEADERS[filename]
            sql = f"INSERT OR IGNORE INTO {TABLE_FOR_CSV[filename]} ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})"
            connection.executemany(sql, [
                tuple(_convert(filename, column, row[column]) for column in columns)
                for row in rows[filename]
            ])

        location_columns = ("source_target_qid", "is_target_match", *GLOBAL_LOCATION_HEADERS)
        location_sql = f"INSERT OR IGNORE INTO movie_locations ({','.join(location_columns)}) VALUES ({','.join('?' for _ in location_columns)})"
        connection.executemany(location_sql, [
            (None, None, *(
                _convert("movie_locations.csv", column, row[column])
                for column in GLOBAL_LOCATION_HEADERS
            )) for row in rows["movie_locations.csv"]
        ])

        issue_columns = ("source_target_qid", *CSV_HEADERS["normalization_issues.csv"])
        issue_sql = f"INSERT OR IGNORE INTO normalization_issues ({','.join(issue_columns)}) VALUES ({','.join('?' for _ in issue_columns)})"
        connection.executemany(issue_sql, [
            (None, *(
                _convert("normalization_issues.csv", column, row[column])
                for column in CSV_HEADERS["normalization_issues.csv"]
            )) for row in rows["normalization_issues.csv"]
        ])

        counts = {TABLE_FOR_CSV[name]: len(rows[name]) for name in GLOBAL_FILENAMES}
        version = "2026-09-13-location-overview-v2"
        connection.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES ('database_version',?)", (version,))
        connection.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES ('global_imported_rows_json',?)", (
            json.dumps(counts, sort_keys=True, separators=(",", ":")),
        ))
        foreign_key_errors = connection.execute("PRAGMA foreign_key_check").fetchall()
        if foreign_key_errors:
            raise ImportValidationError(f"Foreign key violations: {foreign_key_errors[:10]}")
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ImportValidationError("SQLite integrity check failed")
        connection.commit()
        connection.close()
        connection = None
        shutil.copy2(database_path, _backup_path(database_path))
        os.replace(temporary_path, database_path)
        return counts
    except Exception:
        if connection is not None:
            connection.close()
        temporary_path.unlink(missing_ok=True)
        raise


def merge_global_csv_source(
    input_path: Path | str,
    database_path: Path | str,
    schema_path: Path | str | None = None,
) -> dict[str, int]:
    with ExitStack() as stack:
        input_root = _resolve_input(Path(input_path), stack)
        return merge_global_csv_tree(input_root, database_path, schema_path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Regional CSV directory or ZIP archive")
    parser.add_argument("database", type=Path, help="Destination SQLite database")
    parser.add_argument("--schema", type=Path, default=Path(__file__).resolve().parents[1] / "Data" / "schema.sql")
    parser.add_argument("--mirror", type=Path, help="Optional second path for the finished database")
    parser.add_argument("--merge-global", action="store_true", help="Merge a five-file global export into the existing database")
    args = parser.parse_args()

    counts = (
        merge_global_csv_source(args.input, args.database, args.schema)
        if args.merge_global else import_csv_source(args.input, args.database, args.schema)
    )
    if args.mirror:
        args.mirror.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.database, args.mirror)
    print(json.dumps({"database": str(args.database), "mirror": str(args.mirror) if args.mirror else None, "rows": counts}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
