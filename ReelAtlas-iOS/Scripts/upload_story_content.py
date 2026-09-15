#!/usr/bin/env python3
"""Upload ReelSpan's canonical SQLite story data to Supabase."""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any

import certifi


PROJECT_REF = "injisguyqfxfwgnbtghe"
JSON_COLUMNS = {
    "story_targets": {"labels_json": "labels"},
    "story_places": {
        "labels_json": "labels",
        "type_qids_json": "type_qids",
        "p131_qids_json": "p131_qids",
        "location_qids_json": "location_qids",
        "country_qids_json": "country_qids",
        "present_day_qids_json": "present_day_qids",
        "replaced_by_qids_json": "replaced_by_qids",
        "followed_by_qids_json": "followed_by_qids",
    },
    "story_movie_target_matches": {
        "matched_raw_place_qids_json": "matched_raw_place_qids"
    },
    "story_movie_locations": {"raw_place_labels_json": "raw_place_labels"},
    "story_movie_periods": {"period_labels_json": "period_labels"},
}

TABLE_SPECS = [
    ("story_targets", "targets", "target_qid"),
    ("story_movies", "movies", "movie_qid"),
    ("story_places", "places", "place_qid"),
    (
        "story_movie_target_matches",
        "movie_target_matches",
        "movie_qid,target_qid",
    ),
    ("story_movie_locations", "movie_locations", "id"),
    ("story_movie_periods", "movie_periods", "movie_qid,period_qid"),
    ("story_normalization_issues", "normalization_issues", "id"),
]

POINT_RE = re.compile(
    r"POINT\(\s*(?P<longitude>-?\d+(?:\.\d+)?)\s+"
    r"(?P<latitude>-?\d+(?:\.\d+)?)\s*\)",
    re.IGNORECASE,
)


def parse_json(value: str | None, fallback: Any) -> Any:
    if value is None or value == "":
        return fallback
    return json.loads(value)


def parse_coordinate(value: str | None) -> tuple[float | None, float | None]:
    if not value:
        return None, None
    match = POINT_RE.search(value)
    if not match:
        return None, None
    latitude = float(match["latitude"])
    longitude = float(match["longitude"])
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        return None, None
    return latitude, longitude


def transformed_rows(
    connection: sqlite3.Connection, destination: str, source: str
) -> Iterator[dict[str, Any]]:
    connection.row_factory = sqlite3.Row
    for source_row in connection.execute(f'SELECT * FROM "{source}"'):
        row = dict(source_row)
        for old_name, new_name in JSON_COLUMNS.get(destination, {}).items():
            raw = row.pop(old_name)
            fallback = {} if old_name.endswith("labels_json") else []
            row[new_name] = parse_json(raw, fallback)

        if destination == "story_movies":
            row = {
                "movie_qid": row["movie_qid"],
                "legacy_id": row["id"],
                "tmdb_id": row["tmdb_movie_id"],
                "imdb_id": row["imdb_id"],
            }
        elif destination == "story_places":
            latitude, longitude = parse_coordinate(row.get("coordinate"))
            row["latitude"] = latitude
            row["longitude"] = longitude
        elif destination == "story_movie_locations":
            row["is_target_match"] = (
                None
                if row["is_target_match"] is None
                else bool(row["is_target_match"])
            )
        elif destination == "story_movie_periods":
            if (
                row["start_year"] is not None
                and row["end_year"] is not None
                and row["start_year"] > row["end_year"]
            ):
                row["start_year"], row["end_year"] = (
                    row["end_year"],
                    row["start_year"],
                )
            row["confidence"] = 100

        yield row


def batches(rows: Iterable[dict[str, Any]], size: int) -> Iterator[list[dict[str, Any]]]:
    batch: list[dict[str, Any]] = []
    for row in rows:
        batch.append(row)
        if len(batch) == size:
            yield batch
            batch = []
    if batch:
        yield batch


class SupabaseREST:
    def __init__(self, project_ref: str, service_role_key: str) -> None:
        self.base_url = f"https://{project_ref}.supabase.co/rest/v1"
        self.headers = {
            "apikey": service_role_key,
            "Authorization": f"Bearer {service_role_key}",
            "Content-Type": "application/json",
        }
        self.ssl_context = ssl.create_default_context(cafile=certifi.where())

    def request(
        self,
        method: str,
        path: str,
        payload: Any | None = None,
        prefer: str | None = None,
    ) -> Any:
        headers = dict(self.headers)
        if prefer:
            headers["Prefer"] = prefer
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            f"{self.base_url}/{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(
                request, timeout=90, context=self.ssl_context
            ) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Supabase {method} {path} failed: {error.code} {body}") from error
        return json.loads(body) if body else None

    def upsert(self, table: str, conflict: str, rows: list[dict[str, Any]]) -> None:
        encoded_conflict = urllib.parse.quote(conflict, safe=",")
        self.request(
            "POST",
            f"{table}?on_conflict={encoded_conflict}",
            rows,
            "resolution=merge-duplicates,return=minimal",
        )

    def dataset_meta(self) -> dict[str, Any] | None:
        rows = self.request(
            "GET",
            "dataset_meta?dataset_name=eq.reelspan_story_content&select=version,row_counts",
        )
        return rows[0] if rows else None


def source_version(connection: sqlite3.Connection) -> str:
    row = connection.execute(
        "SELECT value FROM metadata WHERE key='database_version'"
    ).fetchone()
    if row is None:
        raise ValueError("SQLite metadata.database_version is missing")
    return str(row[0])


def table_counts(connection: sqlite3.Connection) -> dict[str, int]:
    return {
        destination: int(connection.execute(f'SELECT count(*) FROM "{source}"').fetchone()[0])
        for destination, source, _ in TABLE_SPECS
    }


def upload(
    database: Path,
    client: SupabaseREST,
    batch_size: int,
    start_table: str | None = None,
) -> dict[str, int]:
    with sqlite3.connect(database) as connection:
        counts = table_counts(connection)
        started = start_table is None
        for destination, source, conflict in TABLE_SPECS:
            if destination == start_table:
                started = True
            if not started:
                continue
            uploaded = 0
            for batch in batches(
                transformed_rows(connection, destination, source), batch_size
            ):
                client.upsert(destination, conflict, batch)
                uploaded += len(batch)
                print(f"{destination}: {uploaded}/{counts[destination]}", file=sys.stderr)

        current_meta = client.dataset_meta()
        already_loaded = bool(current_meta and current_meta.get("row_counts"))
        current_version = int(current_meta["version"]) if current_meta else 0
        next_version = current_version + 1 if already_loaded else max(current_version, 1)
        client.upsert(
            "dataset_meta",
            "dataset_name",
            [
                {
                    "dataset_name": "reelspan_story_content",
                    "version": next_version,
                    "source_version": source_version(connection),
                    "row_counts": counts,
                    "is_deleted": False,
                }
            ],
        )
        return counts


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("database", type=Path)
    parser.add_argument("--project-ref", default=PROJECT_REF)
    parser.add_argument("--batch-size", type=int, default=250)
    parser.add_argument(
        "--start-table",
        choices=[destination for destination, _, _ in TABLE_SPECS],
        help="Resume an interrupted upload at this destination table",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.database.is_file():
        parser.error(f"database does not exist: {args.database}")
    with sqlite3.connect(args.database) as connection:
        counts = table_counts(connection)
        version = source_version(connection)
    if args.dry_run:
        print(json.dumps({"source_version": version, "row_counts": counts}, indent=2))
        return

    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not key:
        parser.error("SUPABASE_SERVICE_ROLE_KEY is required unless --dry-run is used")
    result = upload(
        args.database,
        SupabaseREST(args.project_ref, key),
        args.batch_size,
        args.start_table,
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
