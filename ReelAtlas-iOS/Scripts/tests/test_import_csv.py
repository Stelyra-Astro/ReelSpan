import csv
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIR))

from import_csv import import_csv_source, import_csv_tree, merge_global_csv_source  # noqa: E402


HEADERS = {
    "target.csv": [
        "target_qid", "target_kind", "name_en", "name_zh", "labels_json",
        "admin1_qid", "admin1_name_en", "country_qid", "country_name_en",
        "film_count", "candidate_count",
    ],
    "movies.csv": [
        "movie_qid", "title_en", "title_zh", "labels_json", "release_date",
        "release_year", "director_qids_json", "directors_json",
        "origin_country_qids_json", "origin_countries_json", "genre_qids_json",
        "genres_json", "original_language_qids_json", "original_languages_json",
        "imdb_id", "tmdb_movie_id", "runtime", "image", "period_qids_json",
        "tmdb_overview", "tmdb_tagline", "overview_en", "overview_source",
        "overview_source_title", "overview_source_url", "overview_license",
    ],
    "movie_target_matches.csv": [
        "movie_qid", "target_qid", "target_kind", "matched_raw_location_count",
        "matched_raw_place_qids_json", "best_confidence",
    ],
    "movie_locations.csv": [
        "movie_qid", "is_target_match", "raw_place_qid", "raw_place_name_en",
        "raw_place_name_zh", "raw_place_labels_json", "historical_capital_qid",
        "historical_capital_name_en", "modern_place_qid", "modern_place_name_en",
        "city_qid", "city_name_en", "city_name_zh", "admin1_qid",
        "admin1_name_en", "admin1_name_zh", "country_qid", "country_name_en",
        "country_name_zh", "normalization_method", "normalization_path",
        "confidence", "status", "notes",
    ],
    "movie_periods.csv": [
        "movie_qid", "period_qid", "period_name_en", "period_name_zh",
        "period_labels_json", "start_year", "end_year", "interval_method",
    ],
    "places.csv": [
        "place_qid", "name_en", "name_zh", "labels_json", "type_qids_json",
        "p131_qids_json", "location_qids_json", "country_qids_json",
        "present_day_qids_json", "replaced_by_qids_json", "followed_by_qids_json",
        "coordinate", "dissolved_date",
    ],
    "normalization_issues.csv": [
        "movie_qid", "raw_place_qid", "raw_place_name_en", "raw_place_name_zh",
        "issue_type", "status", "confidence", "notes",
    ],
}


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADERS[path.name])
        writer.writeheader()
        writer.writerows(rows)


def base_rows(target_qid: str, target_name: str, is_target_match: str) -> dict[str, list[dict[str, str]]]:
    movie = {
        "movie_qid": "Q1", "title_en": "One", "title_zh": "一",
        "labels_json": '{"en":"One","zh":"一"}', "release_date": "2001-01-01",
        "release_year": "2001", "director_qids_json": '["Q10"]',
        "directors_json": '[{"qid":"Q10","name":"Director"}]',
        "origin_country_qids_json": '["Q148"]',
        "origin_countries_json": '[{"qid":"Q148","name":"China"}]',
        "genre_qids_json": '["Q20"]',
        "genres_json": '[{"qid":"Q20","name":"drama film"}]',
        "original_language_qids_json": '["Q9192"]',
        "original_languages_json": '[{"qid":"Q9192","name":"Mandarin"}]',
        "imdb_id": "tt0000001", "tmdb_movie_id": "1", "runtime": "90.0",
        "image": "", "period_qids_json": '["Q30"]',
        "tmdb_overview": "TMDB overview", "tmdb_tagline": "Tagline",
        "overview_en": "Wikipedia overview", "overview_source": "wikipedia_en",
        "overview_source_title": "One", "overview_source_url": "https://en.wikipedia.org/wiki/One",
        "overview_license": "CC BY-SA 4.0",
    }
    place = {
        "place_qid": "Q100", "name_en": "Place", "name_zh": "地点",
        "labels_json": '{"en":"Place","zh":"地点"}', "type_qids_json": "[]",
        "p131_qids_json": "[]", "location_qids_json": "[]",
        "country_qids_json": "[]", "present_day_qids_json": "[]",
        "replaced_by_qids_json": "[]", "followed_by_qids_json": "[]",
        "coordinate": "POINT(116.4 39.9)", "dissolved_date": "",
    }
    location = {
        "movie_qid": "Q1", "is_target_match": is_target_match,
        "raw_place_qid": "Q100", "raw_place_name_en": "Place",
        "raw_place_name_zh": "地点", "raw_place_labels_json": '{"en":"Place","zh":"地点"}',
        "historical_capital_qid": "", "historical_capital_name_en": "",
        "modern_place_qid": "Q100", "modern_place_name_en": "Place",
        "city_qid": "", "city_name_en": "", "city_name_zh": "",
        "admin1_qid": "", "admin1_name_en": "", "admin1_name_zh": "",
        "country_qid": "", "country_name_en": "", "country_name_zh": "",
        "normalization_method": "direct", "normalization_path": "",
        "confidence": "1.000", "status": "ok", "notes": "",
    }
    return {
        "target.csv": [{
            "target_qid": target_qid, "target_kind": "admin1", "name_en": target_name,
            "name_zh": target_name, "labels_json": f'{{"en":"{target_name}"}}',
            "admin1_qid": target_qid, "admin1_name_en": target_name,
            "country_qid": "Q148", "country_name_en": "China",
            "film_count": "1", "candidate_count": "1",
        }],
        "movies.csv": [movie],
        "movie_target_matches.csv": [{
            "movie_qid": "Q1", "target_qid": target_qid, "target_kind": "admin1",
            "matched_raw_location_count": "1", "matched_raw_place_qids_json": '["Q100"]',
            "best_confidence": "1.000",
        }],
        "movie_locations.csv": [location],
        "movie_periods.csv": [{
            "movie_qid": "Q1", "period_qid": "Q30", "period_name_en": "2001",
            "period_name_zh": "2001年", "period_labels_json": '{"en":"2001"}',
            "start_year": "2001", "end_year": "2001", "interval_method": "P585",
        }],
        "places.csv": [place],
        "normalization_issues.csv": [{
            "movie_qid": "Q1", "raw_place_qid": "Q100", "raw_place_name_en": "Place",
            "raw_place_name_zh": "地点", "issue_type": "fixture", "status": "resolved",
            "confidence": "1.000", "notes": "same issue can occur in each target package",
        }],
    }


class ImportCSVTests(unittest.TestCase):
    def test_import_preserves_target_scoped_rows_and_deduplicates_entities(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "input"
            root.mkdir()
            for region, target_qid, match in [("alpha", "QT1", "1"), ("beta", "QT2", "0")]:
                region_dir = root / region
                region_dir.mkdir()
                for filename, rows in base_rows(target_qid, region.title(), match).items():
                    write_csv(region_dir / filename, rows)

            database = Path(directory) / "content.sqlite"
            counts = import_csv_tree(root, database)

            self.assertEqual(counts["movies"], 1)
            self.assertEqual(counts["movie_target_matches"], 2)
            self.assertEqual(counts["movie_locations"], 2)
            self.assertEqual(counts["movie_periods"], 1)
            self.assertEqual(counts["places"], 1)
            self.assertEqual(counts["normalization_issues"], 2)

            connection = sqlite3.connect(database)
            self.addCleanup(connection.close)
            flags = connection.execute(
                "SELECT source_target_qid, is_target_match FROM movie_locations ORDER BY source_target_qid"
            ).fetchall()
            self.assertEqual(flags, [("QT1", 1), ("QT2", 0)])
            self.assertEqual(connection.execute("PRAGMA foreign_key_check").fetchall(), [])
            columns = [row[1] for row in connection.execute("PRAGMA table_info(movies)")]
            self.assertEqual(columns, ["movie_qid", "id", "imdb_id", "tmdb_movie_id"])
            identity = connection.execute(
                "SELECT id,movie_qid,imdb_id,tmdb_movie_id FROM movies WHERE movie_qid='Q1'"
            ).fetchone()
            self.assertEqual(identity, (1, "Q1", "tt0000001", 1))

    def test_zip_source_is_extracted_and_imported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source" / "output" / "alpha"
            source.mkdir(parents=True)
            for filename, rows in base_rows("QT1", "Alpha", "1").items():
                write_csv(source / filename, rows)

            archive = Path(directory) / "output.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                for path in source.iterdir():
                    bundle.write(path, Path("output") / "alpha" / path.name)

            database = Path(directory) / "content.sqlite"
            counts = import_csv_source(archive, database)

            self.assertEqual(counts["targets"], 1)
            with sqlite3.connect(database) as connection:
                identity = connection.execute(
                    "SELECT movie_qid,imdb_id,tmdb_movie_id FROM movies WHERE movie_qid='Q1'"
                ).fetchone()
            self.assertEqual(identity, ("Q1", "tt0000001", 1))

    def test_global_export_merges_without_inventing_target_matches(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            regional = directory / "regional" / "alpha"
            regional.mkdir(parents=True)
            for filename, rows in base_rows("QT1", "Alpha", "1").items():
                write_csv(regional / filename, rows)

            database = directory / "content.sqlite"
            import_csv_tree(regional.parent, database)

            global_root = directory / "global"
            global_root.mkdir()
            rows = base_rows("QT1", "Alpha", "1")
            new_movie = dict(rows["movies.csv"][0], movie_qid="Q2", title_en="Two", title_zh="二")
            write_csv(global_root / "movies.csv", [new_movie])
            write_csv(global_root / "places.csv", rows["places.csv"])
            global_location_headers = [name for name in HEADERS["movie_locations.csv"] if name != "is_target_match"]
            with (global_root / "movie_locations.csv").open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=global_location_headers)
                writer.writeheader()
                writer.writerow({key: value for key, value in dict(rows["movie_locations.csv"][0], movie_qid="Q2").items() if key != "is_target_match"})
            unresolved = dict(rows["movie_periods.csv"][0], movie_qid="Q2", start_year="", end_year="")
            write_csv(global_root / "movie_periods.csv", [unresolved])
            issue = dict(rows["normalization_issues.csv"][0], movie_qid="Q2")
            write_csv(global_root / "normalization_issues.csv", [issue])

            counts = merge_global_csv_source(global_root, database)

            self.assertEqual(counts["movies"], 1)
            with sqlite3.connect(database) as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM movies").fetchone()[0], 2)
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM movie_target_matches").fetchone()[0], 1)
                self.assertEqual(
                    connection.execute("SELECT source_target_qid,is_target_match FROM movie_locations WHERE movie_qid='Q2'").fetchone(),
                    (None, None),
                )
                self.assertEqual(
                    connection.execute("SELECT start_year,end_year FROM movie_periods WHERE movie_qid='Q2'").fetchone(),
                    (None, None),
                )
                self.assertEqual(connection.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_global_merge_updates_only_movie_identity_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            regional = directory / "regional" / "alpha"
            regional.mkdir(parents=True)
            rows = base_rows("QT1", "Alpha", "1")
            for filename, values in rows.items():
                write_csv(regional / filename, values)

            database = directory / "content.sqlite"
            import_csv_tree(regional.parent, database)

            global_root = directory / "global"
            global_root.mkdir()
            updated = dict(rows["movies.csv"][0], imdb_id="tt9999999", tmdb_movie_id="99")
            write_csv(global_root / "movies.csv", [updated])
            write_csv(global_root / "places.csv", rows["places.csv"])
            headers = [name for name in HEADERS["movie_locations.csv"] if name != "is_target_match"]
            with (global_root / "movie_locations.csv").open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=headers)
                writer.writeheader()
                writer.writerow({key: value for key, value in rows["movie_locations.csv"][0].items() if key != "is_target_match"})
            write_csv(global_root / "movie_periods.csv", [])
            write_csv(global_root / "normalization_issues.csv", rows["normalization_issues.csv"])

            merge_global_csv_source(global_root, database)
            merge_global_csv_source(global_root, database)

            with sqlite3.connect(database) as connection:
                values = connection.execute(
                    "SELECT imdb_id,tmdb_movie_id FROM movies WHERE movie_qid='Q1'"
                ).fetchone()
                self.assertEqual(values, ("tt9999999", 99))
                # One target-scoped issue and one global issue; the second global merge adds none.
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM normalization_issues").fetchone()[0], 2)


if __name__ == "__main__":
    unittest.main()
