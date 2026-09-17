from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = (ROOT / 'ReelAtlas/Features/Home/HomeView.swift').read_text()
LIST = (ROOT / 'ReelAtlas/Features/Home/FilmListView.swift').read_text()
MODEL = (ROOT / 'ReelAtlas/App/AppModel.swift').read_text()
CATALOG = (ROOT / 'ReelAtlas/Data/CatalogDiscoveryService.swift').read_text()

def test_default_map_and_first_toggle():
    assert 'var isListMode = false' in MODEL
    assert LIST.index('modeButton("Map"') < LIST.index('modeButton("List"')

def test_drawer_is_fully_dismissible_with_reopen_pill():
    assert '.interactiveDismissDisabled()' not in HOME
    assert 'tipDetent' not in HOME
    assert 'drawerState.showResults()' in HOME
    assert 'drawerState.userDismissed()' in HOME

def test_no_page_size_disguised_as_exact_count():
    assert 'MapResultsLabel.text(place:' in HOME
    assert 'model.movies.count)\\(model.hasMoreMovies' not in HOME
    assert 'func exactCount(' in (ROOT / 'ReelAtlas/Data/LocalFilmCountStore.swift').read_text()
    assert 'mapResultCount' in MODEL


def test_map_uses_native_muted_flat_style_without_pois_or_traffic():
    assert '.mapStyle(' in HOME
    assert 'elevation: .flat' in HOME
    assert 'emphasis: .muted' in HOME
    assert 'pointsOfInterest: .excludingAll' in HOME
    assert 'showsTraffic: false' in HOME


def test_locally_counted_place_keeps_reopen_entry_when_metadata_is_missing():
    # A permanent SQLite count is useful even if the discovery RPC and metadata
    # cache are unavailable; the user can still open the drawer on the map.
    assert 'if !model.movies.isEmpty || model.mapResultCount != nil {' in HOME


def test_swipe_down_from_expanded_sheet_fully_closes():
    state = (ROOT / 'ReelAtlas/Core/ResultsDrawerState.swift').read_text()
    assert 'if self.level == .full && level == .medium' in state
    assert 'userDismissed()' in state
