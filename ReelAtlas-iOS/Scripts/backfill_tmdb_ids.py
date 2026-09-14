#!/usr/bin/env python3
"""Backfill TMDB movie IDs from Wikidata P4947 and build a metadata-slim seed DB."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import ssl
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


WIKIDATA_API = "https://www.wikidata.org/w/api.php"


def _tls_context() -> ssl.SSLContext:
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def parse_p4947(claims: list[dict[str, Any]]) -> tuple[int | None, str | None]:
    values: list[int] = []
    invalid = False
    for claim in claims:
        try:
            raw = claim["mainsnak"]["datavalue"]["value"]
        except (KeyError, TypeError):
            continue
        if isinstance(raw, str) and raw.isascii() and raw.isdigit() and int(raw) > 0:
            values.append(int(raw))
        else:
            invalid = True
    unique = sorted(set(values))
    if len(unique) > 1:
        return None, "conflict"
    if len(unique) == 1 and not invalid:
        return unique[0], None
    if invalid:
        return None, "invalid"
    return None, "missing"


def _fetch_entities(qids: list[str], timeout: float, retries: int) -> dict[str, Any]:
    query = urllib.parse.urlencode({
        "action": "wbgetentities", "format": "json", "props": "claims",
        "ids": "|".join(qids), "languages": "en",
    })
    request = urllib.request.Request(
        f"{WIKIDATA_API}?{query}",
        headers={"User-Agent": "ReelSpan-TMDB-ID-Backfill/1.0 (contact: xiaoguiwk.top)"},
    )
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(request, timeout=timeout, context=_tls_context()) as response:
                return json.load(response).get("entities", {})
        except urllib.error.HTTPError as error:
            if error.code != 429 and not 500 <= error.code < 600:
                raise
            if attempt == retries:
                raise
            delay = float(error.headers.get("Retry-After", 0) or 0) or min(2 ** attempt, 8)
        except (urllib.error.URLError, TimeoutError):
            if attempt == retries:
                raise
            delay = min(2 ** attempt, 8)
        time.sleep(delay)
    raise RuntimeError("unreachable")


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def backfill_database(
    database: Path,
    report_path: Path,
    checkpoint_path: Path,
    batch_size: int = 50,
    timeout: float = 20,
    retries: int = 3,
) -> dict[str, Any]:
    with sqlite3.connect(database) as connection:
        missing = [row[0] for row in connection.execute(
            """SELECT m.movie_qid FROM movies m WHERE m.tmdb_movie_id IS NULL
               ORDER BY
                 EXISTS (SELECT 1 FROM movie_locations ml WHERE ml.movie_qid=m.movie_qid)
                 AND EXISTS (SELECT 1 FROM movie_periods mp WHERE mp.movie_qid=m.movie_qid
                             AND mp.start_year IS NOT NULL AND mp.end_year IS NOT NULL) DESC,
                 EXISTS (SELECT 1 FROM movie_target_matches mtm WHERE mtm.movie_qid=m.movie_qid) DESC,
                 m.movie_qid"""
        )]
    checkpoint: dict[str, Any] = {"results": {}}
    if checkpoint_path.exists():
        checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
    results = checkpoint.setdefault("results", {})
    pending = [
        qid for qid in missing
        if qid not in results or results[qid].get("status") == "failed"
    ]
    for offset in range(0, len(pending), batch_size):
        qids = pending[offset:offset + batch_size]
        try:
            entities = _fetch_entities(qids, timeout, retries)
            for qid in qids:
                entity = entities.get(qid, {})
                value, reason = parse_p4947(entity.get("claims", {}).get("P4947", []))
                results[qid] = {"tmdbMovieID": value, "status": reason or "added"}
        except Exception as error:
            for qid in qids:
                results[qid] = {"tmdbMovieID": None, "status": "failed", "error": str(error)}
        checkpoint["updatedAt"] = datetime.now(timezone.utc).isoformat()
        _write_json(checkpoint_path, checkpoint)

    with sqlite3.connect(database) as connection:
        connection.executemany(
            "UPDATE movies SET tmdb_movie_id=? WHERE movie_qid=? AND tmdb_movie_id IS NULL",
            [(item["tmdbMovieID"], qid) for qid, item in results.items() if item.get("tmdbMovieID")],
        )
        connection.commit()
        remaining = connection.execute(
            "SELECT COUNT(*) FROM movies WHERE tmdb_movie_id IS NULL"
        ).fetchone()[0]
        duplicate_rows = connection.execute("""
            SELECT tmdb_movie_id,group_concat(movie_qid),group_concat(id),count(*)
            FROM movies WHERE tmdb_movie_id IS NOT NULL
            GROUP BY tmdb_movie_id HAVING count(*) > 1 ORDER BY tmdb_movie_id
        """).fetchall()
        original_missing = set(missing)
        group_qids = {
            "has_both": {
                row[0] for row in connection.execute("""
                    SELECT m.movie_qid FROM movies m
                    WHERE EXISTS (SELECT 1 FROM movie_locations ml WHERE ml.movie_qid=m.movie_qid)
                      AND EXISTS (SELECT 1 FROM movie_periods mp WHERE mp.movie_qid=m.movie_qid
                                  AND mp.start_year IS NOT NULL AND mp.end_year IS NOT NULL)
                """)
            } & original_missing,
            "target_match": {
                row[0] for row in connection.execute("""
                    SELECT m.movie_qid FROM movies m
                    WHERE EXISTS (SELECT 1 FROM movie_target_matches mtm WHERE mtm.movie_qid=m.movie_qid)
                """)
            } & original_missing,
            "location_only": {
                row[0] for row in connection.execute("""
                    SELECT m.movie_qid FROM movies m
                    WHERE EXISTS (SELECT 1 FROM movie_locations ml WHERE ml.movie_qid=m.movie_qid)
                      AND NOT EXISTS (SELECT 1 FROM movie_periods mp WHERE mp.movie_qid=m.movie_qid
                                      AND mp.start_year IS NOT NULL AND mp.end_year IS NOT NULL)
                """)
            } & original_missing,
        }

    by_status: dict[str, list[str]] = {}
    for qid in missing:
        status = results.get(qid, {}).get("status", "failed")
        by_status.setdefault(status, []).append(qid)
    report = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "source": "Wikidata P4947 only",
        "startingMissing": len(missing),
        "added": len(by_status.get("added", [])),
        "conflicts": by_status.get("conflict", []),
        "invalid": by_status.get("invalid", []),
        "failed": by_status.get("failed", []),
        "unresolved": remaining,
        "groups": {
            name: {
                "startingMissing": len(qids),
                "added": sum(results[qid].get("status") == "added" for qid in qids),
                "unresolved": sum(results[qid].get("status") != "added" for qid in qids),
            }
            for name, qids in group_qids.items()
        },
        "duplicateTMDBMappings": [
            {"tmdbMovieID": row[0], "movieQIDs": row[1].split(","), "internalIDs": [int(v) for v in row[2].split(",")]}
            for row in duplicate_rows
        ],
    }
    _write_json(report_path, report)
    return report


def slim_database(source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{output.name}.", suffix=".tmp", dir=output.parent)
    os.close(fd)
    temporary = Path(name)
    temporary.unlink()
    try:
        with sqlite3.connect(source) as old, sqlite3.connect(temporary) as new:
            new.execute("PRAGMA foreign_keys=OFF")
            objects = old.execute("""
                SELECT type,name,tbl_name,sql FROM sqlite_master
                WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
                ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 ELSE 2 END,name
            """).fetchall()
            for kind, name, table, sql in objects:
                if kind == "table":
                    if name == "movies":
                        new.execute("CREATE TABLE movies (movie_qid TEXT PRIMARY KEY,id INTEGER UNIQUE NOT NULL,imdb_id TEXT,tmdb_movie_id INTEGER)")
                    else:
                        new.execute(sql)
                    old_columns = [row[1] for row in old.execute(f'PRAGMA table_info("{name}")')]
                    new_columns = [row[1] for row in new.execute(f'PRAGMA table_info("{name}")')]
                    columns = [column for column in new_columns if column in old_columns]
                    if columns:
                        names = ",".join(f'"{column}"' for column in columns)
                        rows = old.execute(f'SELECT {names} FROM "{name}"')
                        placeholders = ",".join("?" for _ in columns)
                        new.executemany(f'INSERT INTO "{name}" ({names}) VALUES ({placeholders})', rows)
                elif kind == "index" and table == "movies":
                    continue
                else:
                    new.execute(sql)
            new.execute("CREATE INDEX idx_movies_tmdb_id ON movies(tmdb_movie_id,id)")
            if "metadata" in {row[1] for row in objects if row[0] == "table"}:
                new.execute(
                    "INSERT OR REPLACE INTO metadata(key,value) VALUES('database_version',?)",
                    ("2026-09-14-dynamic-metadata-v1",),
                )
            new.commit()
            violations = new.execute("PRAGMA foreign_key_check").fetchall()
            if violations:
                raise RuntimeError(f"Foreign key violations: {violations[:10]}")
            if new.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError("SQLite integrity check failed")
        if output.exists():
            shutil.copy2(output, output.with_suffix(output.suffix + ".backup"))
        os.replace(temporary, output)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--slim-output", type=Path)
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--retries", type=int, default=3)
    args = parser.parse_args()
    report = backfill_database(
        args.database, args.report, args.checkpoint,
        batch_size=args.batch_size, timeout=args.timeout, retries=args.retries,
    )
    if args.slim_output:
        slim_database(args.database, args.slim_output)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
