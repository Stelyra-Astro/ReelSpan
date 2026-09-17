"""Regression contracts for the Build 12 cache-startup failure.

These source checks complement (not replace) device/network integration tests.
"""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
CAT = (ROOT / 'ReelAtlas/Data/CatalogDiscoveryService.swift').read_text()
MODEL = (ROOT / 'ReelAtlas/App/AppModel.swift').read_text()
CONTENT = (ROOT / 'ReelAtlas/Data/ContentRepository.swift').read_text()
META = (ROOT / 'ReelAtlas/Core/MovieMetadataCache.swift').read_text()
UI = (ROOT / 'ReelAtlas/Features/Home/FilmListView.swift').read_text()
SCHEMA = (ROOT / 'ReelAtlas/Resources/schema.sql').read_text()
SYNC = (ROOT / 'ReelAtlas/Data/StoryContentSyncService.swift').read_text()
MIGRATION = (ROOT.parent / 'supabase/migrations/202609170001_discover_fast_browse.sql')


def test_exact_cache_is_returned_before_any_rpc():
    page = CAT.split('func page(_ parameters:', 1)[1].split('static func movieData', 1)[0]
    assert 'if !refresh, let saved = try cachedPage(parameters, language: language)' in page
    assert page.index('if !refresh, let saved') < page.index('let rows = try JSONDecoder().decode')
    assert 'refresh: Bool = false' in CAT
    assert 'page(request, language: language, refresh: true)' in MODEL


def test_legacy_metadata_cache_publishes_usable_movies_without_network():
    assert 'func cachedMetadataIDs' in META
    assert 'func cachedMovie' in CONTENT
    assert 'func offlinePage' in MODEL
    segment = MODEL.split('if !favoritesOnly {', 1)[1].split('let page = await moviePages.page(', 1)[0]
    assert segment.index('await moviePages.offlinePage(') < segment.index('let page = try await catalog.page(')
    assert 'showingOfflineSamples = true' in segment


def test_sync_cloud_restore_and_rankings_do_not_blank_or_block_visible_movies():
    sync = MODEL.split('private func acceptSyncedBatch', 1)[1].split('func setListMode', 1)[0]
    assert 'if !isListMode { reload() }' not in sync
    cloud = MODEL.split('private func restoreICloudBackup', 1)[1].split('private func scheduleICloudBackup', 1)[0]
    assert 'if languageChanged' in cloud
    worker = MODEL.split('private actor MoviePageWorker', 1)[1].split('private actor SearchDataWorker', 1)[0]
    assert 'await metadataService.rankings' not in worker
    assert 'private func scheduleInitialContentRetry' in MODEL


def test_grouping_degrades_and_server_migration_defers_heavy_join():
    assert 'Grouping is unavailable offline' in UI
    assert MIGRATION.exists()
    sql = MIGRATION.read_text()
    assert 'IF trim(coalesce(p_query' in sql
    assert 'LIMIT greatest(1, least(coalesce(p_limit' in sql
    assert 'JOIN public.movies md' in sql or 'LEFT JOIN public.movies md' in sql
    assert sql.index('LIMIT greatest(1, least(coalesce(p_limit') < sql.index('LEFT JOIN public.movies md')


def test_old_cache_has_indexed_tmdb_join_and_true_local_count():
    assert 'CREATE INDEX IF NOT EXISTS idx_movies_tmdb_movie_id' in SCHEMA
    assert 'CREATE INDEX IF NOT EXISTS idx_movies_tmdb_movie_id' in SYNC
    assert 'max(model.syncDownloaded, model.syncTotal)' in UI


def test_country_browse_limits_priority_candidates_before_metadata_join():
    sql = MIGRATION.read_text()
    assert 'prioritized AS MATERIALIZED' in sql
    assert 'remainder AS MATERIALIZED' in sql
    assert sql.index('prioritized AS MATERIALIZED') < sql.index('LEFT JOIN public.movies md')


def test_failed_country_associations_are_retried_in_foreground():
    section = MODEL.split('func loadCountryAssociations()', 1)[1].split('func findModernPlaces', 1)[0]
    assert 'scheduleCountryLinksRetry()' in section
    assert 'countryLinksRetryTask?.cancel()' in MODEL


def test_sqlite_can_use_tmdb_lookup_index_for_legacy_cache():
    import sqlite3
    db = sqlite3.connect(':memory:')
    db.executescript(SCHEMA)
    plan = db.execute('EXPLAIN QUERY PLAN SELECT id FROM movies WHERE tmdb_movie_id=?', (550,)).fetchall()
    assert any('idx_movies_tmdb_movie_id' in description for _, _, _, description in plan)


def test_partial_first_batch_opens_on_a_place_with_movies_without_california_target():
    fallback = MODEL.split('private func applyCaliforniaFallback()', 1)[1].split('private actor MoviePageWorker', 1)[0]
    assert 'nearestMovieLocation(' in fallback
    assert 'if !syncComplete' in fallback


def test_initial_batch_downloads_only_referenced_parents_before_publishing():
    start = SYNC.split('private func rebuildFirstBatch', 1)[1].split('private func importBatch', 1)[0]
    assert 'requiredParentRows(table: "story_targets"' in start
    assert 'requiredParentRows(table: "story_places"' in start
    assert 'await importTargets(' not in start
    assert 'await importPlaces(' not in start
    assert 'await importTimeConcepts(' not in start
