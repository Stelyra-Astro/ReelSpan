import importlib.util
import sqlite3
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "upload_story_content.py"
SPEC = importlib.util.spec_from_file_location("upload_story_content", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class UploadStoryContentTests(unittest.TestCase):
    def test_movie_rows_only_keep_story_identity_fields(self):
        connection = sqlite3.connect(":memory:")
        connection.executescript(
            """
            create table movies (
              movie_qid text, id integer, tmdb_movie_id integer, imdb_id text,
              title_en text
            );
            insert into movies values ('Q1', 7, 857, 'tt0120815', 'Ignored title');
            """
        )

        rows = list(MODULE.transformed_rows(connection, "story_movies", "movies"))

        self.assertEqual(
            rows,
            [{"movie_qid": "Q1", "legacy_id": 7, "tmdb_id": 857, "imdb_id": "tt0120815"}],
        )

    def test_place_coordinates_are_split_without_losing_original_value(self):
        connection = sqlite3.connect(":memory:")
        connection.executescript(
            """
            create table places (
              place_qid text, name_en text, name_zh text, labels_json text,
              type_qids_json text, p131_qids_json text, location_qids_json text,
              country_qids_json text, present_day_qids_json text,
              replaced_by_qids_json text, followed_by_qids_json text,
              coordinate text, dissolved_date text
            );
            insert into places values (
              'Q2','Normandy','诺曼底','{}','[]','[]','[]','[]','[]','[]','[]',
              'POINT(-0.6 49.3)',null
            );
            """
        )

        row = next(MODULE.transformed_rows(connection, "story_places", "places"))

        self.assertEqual(row["coordinate"], "POINT(-0.6 49.3)")
        self.assertEqual(row["latitude"], 49.3)
        self.assertEqual(row["longitude"], -0.6)
        self.assertEqual(row["labels"], {})

    def test_batches_do_not_drop_final_partial_batch(self):
        rows = [{"id": value} for value in range(5)]
        self.assertEqual([len(batch) for batch in MODULE.batches(rows, 2)], [2, 2, 1])

    def test_unusable_wikidata_coordinate_is_preserved_but_not_split(self):
        raw = "<http://www.wikidata.org/entity/Q111> Point(339.26 49.76)"
        self.assertEqual(MODULE.parse_coordinate(raw), (None, None))

    def test_reversed_story_period_is_normalized(self):
        connection = sqlite3.connect(":memory:")
        connection.executescript(
            """
            create table movie_periods (
              movie_qid text, period_qid text, period_name_en text,
              period_name_zh text, period_labels_json text,
              start_year integer, end_year integer, interval_method text
            );
            insert into movie_periods values (
              'Q1','Q2','Lower Paleolithic','旧石器时代初期','{}',
              300000,-300000,'P580/P582'
            );
            """
        )

        row = next(
            MODULE.transformed_rows(
                connection, "story_movie_periods", "movie_periods"
            )
        )

        self.assertEqual((row["start_year"], row["end_year"]), (-300000, 300000))


if __name__ == "__main__":
    unittest.main()
