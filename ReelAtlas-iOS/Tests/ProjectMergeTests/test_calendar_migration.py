"""Guard the catalogue cleanup and seeded human-lifespan entries."""
from pathlib import Path

MIGRATION = Path(__file__).resolve().parents[3] / 'supabase/migrations/202609160012_clean_calendar_and_people.sql'


def test_bce_centuries_use_full_span_and_preserve_source_rows():
    sql = MIGRATION.read_text()
    assert '100 - 100 *' in sql
    assert 'story_movie_periods' in sql
    assert 'normalized_bce_century' in sql


def test_people_have_verified_qids_and_no_automatic_movie_tags():
    sql = MIGRATION.read_text()
    assert "'Q33772','person','Du Fu'" in sql
    assert "'Q692','person','William Shakespeare'" in sql
    assert 'story_movie_concept_tags' not in sql


def test_months_and_dates_move_to_calendar_not_era():
    sql = MIGRATION.read_text()
    assert "SET category='calendar'" in sql
    assert 'January|February|March' in sql
