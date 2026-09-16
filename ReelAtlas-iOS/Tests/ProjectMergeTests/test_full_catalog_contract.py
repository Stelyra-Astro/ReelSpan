from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SYNC = (ROOT / 'ReelAtlas/Data/StoryContentSyncService.swift').read_text()
APP = (ROOT / 'ReelAtlas/App/AppModel.swift').read_text()
SCHEMA = (ROOT / 'Data/schema.sql').read_text()

class FullCatalogContract(unittest.TestCase):
    def test_full_movie_scope_does_not_depend_on_target_matches(self):
        self.assertNotIn('ContentBootstrapScope(', SYNC)
        self.assertIn('appendingPathComponent("story_movies")', SYNC)
        self.assertIn('batchSize = 250', SYNC)

    def test_sync_persists_resume_and_completed_version_separately(self):
        self.assertIn('sync_cursor', SYNC)
        self.assertIn('sync_target_version', SYNC)
        self.assertIn('sync_complete', SYNC)

    def test_empty_location_scope_is_valid_for_global_catalog(self):
        self.assertIn('hasMoreMovies = isListMode || movieLocationScope != nil', APP)

    def test_catalog_caches_time_concepts(self):
        self.assertIn('CREATE TABLE time_concepts', SCHEMA)
        self.assertIn('CREATE INDEX idx_movie_periods_years', SCHEMA)

if __name__ == '__main__': unittest.main()

class SyncSafetyContract(unittest.TestCase):
    def test_bundled_schema_is_the_one_with_time_catalog(self):
        bundled = (ROOT / 'ReelAtlas/Resources/schema.sql').read_text()
        self.assertEqual(bundled, SCHEMA)
        self.assertIn('CREATE TABLE time_concepts', bundled)

    def test_icloud_backups_do_not_drop_uncached_favorites(self):
        self.assertIn('guard iCloudBackupEnabled, syncComplete, let content else { return }', APP)

    def test_where_rpc_is_awaited(self):
        catalog = (ROOT / 'ReelAtlas/Data/CatalogDiscoveryService.swift').read_text()
        self.assertIn('let data = try await post("reelatlas_where_places"', catalog)

class OfflineConceptContract(unittest.TestCase):
    def test_when_catalog_survives_offline_restart(self):
        repo = (ROOT / 'ReelAtlas/Data/ContentRepository.swift').read_text()
        self.assertIn('func timeConcepts(preferredLanguage:', repo)
        self.assertIn('repository.timeConcepts(preferredLanguage:', APP)

class BootstrapResponsivenessContract(unittest.TestCase):
    def test_time_catalog_network_fetch_does_not_block_initial_content(self):
        start = APP.index('private func loadStoryContent() async')
        end = APP.index('private func acceptSyncedBatch(', start)
        body = APP[start:end]
        self.assertIn('repository.timeConcepts(preferredLanguage: effectiveLanguage)', body)
        self.assertLess(body.index('contentBootstrapGate.markContentReady()'),
                        body.index('await self.catalog.concepts(language:'))

    def test_year_range_clears_previous_when_concept(self):
        for signature in ('setStoryStartYear', 'setStoryEndYear', 'setStoryTimeRange'):
            body = APP.split('func ' + signature + '(', 1)[1].split('\n    }', 1)[0]
            self.assertIn('selectedWhen = nil', body)


class UsableWhenConceptContract(unittest.TestCase):
    def test_unbounded_concepts_are_not_offered_as_exact_time_filters(self):
        repo = (ROOT / 'ReelAtlas/Data/ContentRepository.swift').read_text()
        catalog = (ROOT / 'ReelAtlas/Data/CatalogDiscoveryService.swift').read_text()
        self.assertIn('WHERE start_year IS NOT NULL AND end_year IS NOT NULL', repo)
        self.assertIn('URLQueryItem(name: "start_year", value: "not.is.null")', catalog)
        self.assertIn('URLQueryItem(name: "end_year", value: "not.is.null")', catalog)
