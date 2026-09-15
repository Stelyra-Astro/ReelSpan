import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIR))

from backfill_tmdb_ids import backfill_database, parse_p4947, slim_database  # noqa: E402


def claim(value):
    return {"mainsnak": {"snaktype": "value", "datavalue": {"value": value}}}


class BackfillTMDBIDTests(unittest.TestCase):
    def test_parse_p4947_accepts_one_unique_positive_integer(self):
        self.assertEqual(parse_p4947([claim("550")]), (550, None))
        self.assertEqual(parse_p4947([claim("550"), claim("550")]), (550, None))

    def test_parse_p4947_rejects_missing_invalid_and_conflicting_values(self):
        self.assertEqual(parse_p4947([]), (None, "missing"))
        self.assertEqual(parse_p4947([claim("0")]), (None, "invalid"))
        self.assertEqual(parse_p4947([claim("movie-550")]), (None, "invalid"))
        self.assertEqual(parse_p4947([claim("550"), claim("551")]), (None, "conflict"))

    def test_slim_database_preserves_story_tables_and_only_movie_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.sqlite"
            output = Path(directory) / "slim.sqlite"
            with sqlite3.connect(source) as db:
                db.executescript("""
                    CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                    INSERT INTO metadata VALUES('database_version','fixture');
                    CREATE TABLE movies(movie_qid TEXT PRIMARY KEY,id INTEGER UNIQUE NOT NULL,
                      title_en TEXT NOT NULL,imdb_id TEXT,tmdb_movie_id INTEGER);
                    INSERT INTO movies VALUES('Q1',7,'Not bundled','tt1',550);
                    CREATE TABLE movie_periods(movie_qid TEXT,period_qid TEXT,start_year INTEGER,end_year INTEGER);
                    INSERT INTO movie_periods VALUES('Q1','QP',1900,1910);
                    CREATE TABLE movie_locations(id INTEGER PRIMARY KEY,movie_qid TEXT,raw_place_qid TEXT,confidence REAL);
                    INSERT INTO movie_locations VALUES(3,'Q1','QL',0.9);
                """)

            slim_database(source, output)

            with sqlite3.connect(output) as db:
                columns = [row[1] for row in db.execute("PRAGMA table_info(movies)")]
                self.assertEqual(columns, ["movie_qid", "id", "imdb_id", "tmdb_movie_id"])
                self.assertEqual(db.execute("SELECT * FROM movies").fetchone(), ("Q1", 7, "tt1", 550))
                self.assertEqual(db.execute("SELECT * FROM movie_periods").fetchone(), ("Q1", "QP", 1900, 1910))
                self.assertEqual(db.execute("SELECT * FROM movie_locations").fetchone(), (3, "Q1", "QL", 0.9))

    def test_backfill_prioritizes_story_ready_movies_and_writes_checkpoint_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "content.sqlite"
            report = root / "report.json"
            checkpoint = root / "checkpoint.json"
            with sqlite3.connect(database) as db:
                db.executescript("""
                    CREATE TABLE movies(movie_qid TEXT PRIMARY KEY,id INTEGER UNIQUE NOT NULL,
                      imdb_id TEXT,tmdb_movie_id INTEGER);
                    INSERT INTO movies VALUES('Q1',1,NULL,NULL),('Q2',2,NULL,NULL);
                    CREATE TABLE movie_locations(movie_qid TEXT);
                    INSERT INTO movie_locations VALUES('Q1'),('Q2');
                    CREATE TABLE movie_periods(movie_qid TEXT,start_year INTEGER,end_year INTEGER);
                    INSERT INTO movie_periods VALUES('Q2',1900,1910);
                    CREATE TABLE movie_target_matches(movie_qid TEXT);
                """)

            entities = {
                "Q1": {"claims": {"P4947": [claim("550")]}},
                "Q2": {"claims": {"P4947": []}},
            }
            with patch("backfill_tmdb_ids._fetch_entities", return_value=entities) as fetch:
                result = backfill_database(database, report, checkpoint, batch_size=50)

            self.assertEqual(fetch.call_args.args[0], ["Q2", "Q1"])
            self.assertEqual(result["startingMissing"], 2)
            self.assertEqual(result["added"], 1)
            self.assertEqual(result["groups"]["has_both"]["startingMissing"], 1)
            with sqlite3.connect(database) as db:
                self.assertEqual(db.execute("SELECT tmdb_movie_id FROM movies WHERE movie_qid='Q1'").fetchone()[0], 550)
            self.assertTrue(report.is_file())
            self.assertTrue(checkpoint.is_file())


if __name__ == "__main__":
    unittest.main()
