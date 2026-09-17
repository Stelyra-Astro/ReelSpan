from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FILM = (ROOT / 'ReelAtlas-iOS/ReelAtlas/Features/Home/FilmListView.swift').read_text()
SITE = (ROOT / 'index.html').read_text()
MODEL = (ROOT / 'ReelAtlas-iOS/ReelAtlas/App/AppModel.swift').read_text()

def test_grouping_exposes_continent_country_and_centuries():
    assert 'continentGroups' in FILM
    assert 'countryGroups' in FILM
    assert 'FilmGroupRules.centuries' in FILM
    assert 'Unspecified time' in FILM

def test_where_is_three_level_navigation_with_cached_catalog():
    assert 'selectedContinent' in FILM
    assert 'selectedCountryQID' in FILM
    assert 'whereCatalog' in FILM
    assert 'Search countries or cities' in FILM

def test_calendar_browses_centuries_and_excludes_raw_dates():
    assert 'selectedCentury' in FILM
    assert 'FilmGroupRules.centuryLabel' in FILM

def test_marketing_demo_is_clickable_and_offline_static():
    assert 'id="try-app"' in SITE
    assert 'demo.js' in SITE
    assert 'Demo data' in SITE

def test_default_country_sort_survives_location_fallback():
    assert 'preferredCountryQID = "Q30"' in MODEL
    assert r'country:\(preferredCountryQID)' in MODEL

def test_where_catalog_network_failure_is_silent_and_retries_on_foreground():
    assert 'whereCatalogError' in MODEL
    assert 'Retry place catalog' not in FILM
    assert 'if whereCatalog.isEmpty { await ensureWhereCatalog() }' in MODEL
    assert 'isLoadingWhereCatalog' in MODEL

def test_static_preview_has_nested_place_headings_and_all_missing_data_paths():
    script = (ROOT / 'demo.js').read_text()
    assert 'demo-continent-label' in script
    assert 'demo-country-label' in script
    assert 'Has time, missing story place' in script
    assert 'Has place, missing story time' in script
    assert 'Missing both story time and place' in script
