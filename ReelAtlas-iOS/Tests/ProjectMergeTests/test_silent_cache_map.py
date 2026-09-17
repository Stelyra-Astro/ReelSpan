"""Regression contracts for silent sync, resilient catalog browsing and unified map chrome."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SYNC = (ROOT / 'ReelAtlas/Data/StoryContentSyncService.swift').read_text()
CATALOG = (ROOT / 'ReelAtlas/Data/CatalogDiscoveryService.swift').read_text()
MODEL = (ROOT / 'ReelAtlas/App/AppModel.swift').read_text()
LIST = (ROOT / 'ReelAtlas/Features/Home/FilmListView.swift').read_text()
MAP = (ROOT / 'ReelAtlas/Features/Home/HomeView.swift').read_text()


def test_sync_logs_http_status_and_postgrest_code_instead_of_uninformative_generic_failure():
    assert 'http.statusCode' in SYNC
    assert 'Supabase HTTP' in SYNC
    assert 'PostgREST' in SYNC


def test_catalog_can_reuse_successfully_loaded_exact_filter_page_on_failure():
    assert 'CachedPage' in CATALOG
    assert 'cacheKey' in CATALOG
    assert 'readCachedPage' in CATALOG
    assert 'writeCachedPage' in CATALOG
    assert 'http.statusCode' in CATALOG


def test_sync_failures_are_not_user_visible_and_retry_happens_silently():
    assert 'Retry cached story update' not in LIST
    assert 'Story data update paused' not in LIST
    assert 'Retry full catalog' not in LIST
    assert 'Full catalog search is temporarily unavailable.' not in LIST
    assert 'retryContentSyncIfNeeded' in MODEL
    assert 'scheduleCatalogRetry' in MODEL
    assert 'catalogRetryTask?.cancel()' in MODEL
    assert 'model.setAppActive(phase == .active)' in MAP


def test_map_uses_same_search_filter_header_and_avoids_old_floating_controls():
    assert 'FilmListView(showsMap: true)' in MAP
    assert 'FilmListView(showsMap: false)' in MAP
    assert 'if !showsMap' in LIST
    assert 'topControls\n' not in MAP.split('var body: some View {', 1)[1].split('private var resultsSheetIsPresented', 1)[0]


def test_map_discovery_has_filtered_catalog_and_pins_from_discovery_results():
    assert 'if !favoritesOnly' in MODEL
    assert 'listMode ? listScope : (listScope ?? mapScope)' in MODEL
    assert 'page.movies.flatMap(\\.locations)' in MODEL


def test_background_story_reconciliation_retries_while_app_remains_active():
    assert 'scheduleContentSyncRetry()' in MODEL
    assert 'contentSyncRetryTask?.cancel()' in MODEL
    assert 'contentSyncError != nil' in MODEL


def test_stale_catalog_pages_refresh_without_clearing_visible_film_rows():
    assert 'isStale: Bool' in CATALOG
    assert 'if page.isStale' in MODEL
    assert 'retryCatalogSilently()' in MODEL


def test_foreground_sync_does_not_bypass_retry_throttle():
    app = (ROOT / 'ReelAtlas/App/ReelAtlasApp.swift').read_text()
    assert 'await model.resumeContentSync()' not in app
    assert 'retryContentSyncIfNeeded()' in app
