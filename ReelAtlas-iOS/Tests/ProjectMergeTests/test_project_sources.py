from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "ReelAtlas"
PBX = (ROOT / "ReelSpan.xcodeproj" / "project.pbxproj").read_text()

class ProjectMergeTests(unittest.TestCase):
    def test_removed_legacy_runtime_dependencies_are_not_referenced(self):
        app_text = "\n".join(p.read_text(errors="ignore") for p in APP.rglob("*.swift"))
        self.assertNotIn("model.imageManager", app_text)
        self.assertNotIn("ImageDownloadManager", app_text)
        self.assertNotIn("TMDBImageMetadata", app_text)
        self.assertNotIn("IMDbSafariView", app_text)
        self.assertNotIn("reelspan-tmdb.xiaoguiwk.workers.dev", app_text)
        self.assertNotIn("qvfdtvfgnlpctcykpfgy", app_text)

    def test_obsolete_small_poster_resources_are_removed_from_target(self):
        self.assertNotIn("SmallPosters", PBX)
        self.assertNotRegex(PBX, r"movie_[1-8]\\.jpg")

    def test_dead_supabase_only_helpers_are_not_compiled(self):
        self.assertNotIn("MovieTextStore.swift in Sources", PBX)
        self.assertNotIn("MovieArtworkView.swift in Sources", PBX)

    def test_dynamic_metadata_sources_are_compiled_once(self):
        expected = [
            "SearchAndTip.swift in Sources",
            "MovieMetadataService.swift in Sources",
            "MovieMetadataStore.swift in Sources",
            "MovieMetadataModels.swift in Sources",
            "MovieMetadataRequest.swift in Sources",
            "MovieMetadataCache.swift in Sources",
            "MovieCachePolicy.swift in Sources",
        ]
        start = PBX.index("/* Begin PBXSourcesBuildPhase section */")
        end = PBX.index("/* End PBXSourcesBuildPhase section */")
        source_phase = PBX[start:end]
        for needle in expected:
            self.assertEqual(source_phase.count(needle), 1, needle)

    def test_delivery_build_number_is_nine(self):
        self.assertEqual(PBX.count("CURRENT_PROJECT_VERSION = 9;"), 2)
        self.assertNotIn("CURRENT_PROJECT_VERSION = 8;", PBX)

if __name__ == "__main__":
    unittest.main()
