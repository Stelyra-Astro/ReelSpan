"""Local atlas count and permanent disk-store regression contracts.

Source checks supplement executable Swift SQLite integration checks.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = (ROOT / 'ReelAtlas/Data')
MODEL = (ROOT / 'ReelAtlas/App/AppModel.swift').read_text()
CACHE = (DATA / 'CatalogDiscoveryService.swift').read_text()
META = (ROOT / 'ReelAtlas/Core/MovieMetadataCache.swift').read_text()


def test_exact_map_count_reads_local_sqlite_before_any_network():
    count = (DATA / 'LocalFilmCountStore.swift').read_text()
    assert 'SELECT COUNT(*) FROM movies m' in count
    assert 'EXISTS (SELECT 1 FROM movie_periods' in count
    assert 'EXISTS (SELECT 1 FROM movie_locations' in count
    assert 'EXISTS (SELECT 1 FROM movie_target_matches' in count
    assert 'mapResultCount = count' in MODEL
    assert 'LocalFilmCountStore(databaseURL:' in MODEL
    assert 'func exactCount(' not in CACHE or 'readCachedPage' in CACHE


def test_catalog_snapshots_are_permanent_and_old_where_cache_migrates():
    assert 'applicationSupportDirectory' in CACHE
    assert 'legacyWhereCacheURL' in CACHE
    assert 'prefix(60)' not in CACHE
    assert 'pageCache.removeValue' not in CACHE
    assert 'whereSnapshot = next' in CACHE


def test_cached_movie_metadata_never_expires_or_gets_evicted_by_image_budget():
    assert 'func readMetadata(tmdbID: Int, allowExpired: Bool = false)' in META
    assert 'guard allowExpired || !isExpired(url)' not in META
    assert 'where !file.url.lastPathComponent.hasPrefix("movie-en-US-")' in META


def test_offline_uses_all_saved_metadata_ids_and_reads_only_matching_movies():
    service = (ROOT / 'ReelAtlas/Core/MovieMetadataService.swift').read_text()
    worker = MODEL.split('private actor MoviePageWorker', 1)[1].split('private actor SearchDataWorker', 1)[0]
    assert 'public func cachedMetadataIDs(limit: Int = .max)' in service
    assert 'public func cachedMetadata(tmdbIDs: [Int])' in service
    assert 'cachedMetadataIDs(limit: .max)' in worker
    assert 'content.cachedMovie(tmdbID:' in worker
    assert 'cachedMetadata(limit: 400)' not in worker
