PRAGMA foreign_keys = ON;

CREATE TABLE metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE targets (
  target_qid TEXT PRIMARY KEY,
  target_kind TEXT NOT NULL,
  name_en TEXT NOT NULL,
  name_zh TEXT NOT NULL,
  labels_json TEXT NOT NULL CHECK (json_valid(labels_json)),
  admin1_qid TEXT,
  admin1_name_en TEXT,
  country_qid TEXT NOT NULL,
  country_name_en TEXT NOT NULL,
  film_count INTEGER NOT NULL,
  candidate_count INTEGER NOT NULL
);

CREATE TABLE movies (
  movie_qid TEXT PRIMARY KEY,
  id INTEGER UNIQUE NOT NULL,
  title_en TEXT NOT NULL,
  title_zh TEXT NOT NULL,
  labels_json TEXT NOT NULL CHECK (json_valid(labels_json)),
  release_date TEXT,
  release_year INTEGER,
  director_qids_json TEXT NOT NULL CHECK (json_valid(director_qids_json)),
  directors_json TEXT NOT NULL CHECK (json_valid(directors_json)),
  origin_country_qids_json TEXT NOT NULL CHECK (json_valid(origin_country_qids_json)),
  origin_countries_json TEXT NOT NULL CHECK (json_valid(origin_countries_json)),
  genre_qids_json TEXT NOT NULL CHECK (json_valid(genre_qids_json)),
  genres_json TEXT NOT NULL CHECK (json_valid(genres_json)),
  original_language_qids_json TEXT NOT NULL CHECK (json_valid(original_language_qids_json)),
  original_languages_json TEXT NOT NULL CHECK (json_valid(original_languages_json)),
  imdb_id TEXT,
  tmdb_movie_id INTEGER,
  runtime REAL,
  image TEXT,
  period_qids_json TEXT NOT NULL CHECK (json_valid(period_qids_json)),
  tmdb_overview TEXT NOT NULL DEFAULT '',
  tmdb_tagline TEXT NOT NULL DEFAULT '',
  overview_en TEXT NOT NULL DEFAULT '',
  overview_source TEXT NOT NULL DEFAULT '',
  overview_source_title TEXT NOT NULL DEFAULT '',
  overview_source_url TEXT NOT NULL DEFAULT '',
  overview_license TEXT NOT NULL DEFAULT ''
);

CREATE TABLE movie_target_matches (
  movie_qid TEXT NOT NULL REFERENCES movies(movie_qid) ON DELETE CASCADE,
  target_qid TEXT NOT NULL REFERENCES targets(target_qid) ON DELETE CASCADE,
  target_kind TEXT NOT NULL,
  matched_raw_location_count INTEGER NOT NULL,
  matched_raw_place_qids_json TEXT NOT NULL CHECK (json_valid(matched_raw_place_qids_json)),
  best_confidence REAL NOT NULL,
  PRIMARY KEY (movie_qid, target_qid)
);

CREATE TABLE places (
  place_qid TEXT PRIMARY KEY,
  name_en TEXT NOT NULL,
  name_zh TEXT NOT NULL,
  labels_json TEXT NOT NULL CHECK (json_valid(labels_json)),
  type_qids_json TEXT NOT NULL CHECK (json_valid(type_qids_json)),
  p131_qids_json TEXT NOT NULL CHECK (json_valid(p131_qids_json)),
  location_qids_json TEXT NOT NULL CHECK (json_valid(location_qids_json)),
  country_qids_json TEXT NOT NULL CHECK (json_valid(country_qids_json)),
  present_day_qids_json TEXT NOT NULL CHECK (json_valid(present_day_qids_json)),
  replaced_by_qids_json TEXT NOT NULL CHECK (json_valid(replaced_by_qids_json)),
  followed_by_qids_json TEXT NOT NULL CHECK (json_valid(followed_by_qids_json)),
  coordinate TEXT,
  dissolved_date TEXT
);

-- is_target_match is relative to the regional package that supplied the row.
CREATE TABLE movie_locations (
  id INTEGER PRIMARY KEY,
  source_target_qid TEXT REFERENCES targets(target_qid) ON DELETE CASCADE,
  movie_qid TEXT NOT NULL REFERENCES movies(movie_qid) ON DELETE CASCADE,
  is_target_match INTEGER CHECK (is_target_match IN (0, 1)),
  raw_place_qid TEXT NOT NULL REFERENCES places(place_qid),
  raw_place_name_en TEXT NOT NULL,
  raw_place_name_zh TEXT NOT NULL,
  raw_place_labels_json TEXT NOT NULL CHECK (json_valid(raw_place_labels_json)),
  historical_capital_qid TEXT REFERENCES places(place_qid),
  historical_capital_name_en TEXT,
  modern_place_qid TEXT REFERENCES places(place_qid),
  modern_place_name_en TEXT,
  city_qid TEXT REFERENCES places(place_qid),
  city_name_en TEXT,
  city_name_zh TEXT,
  admin1_qid TEXT REFERENCES places(place_qid),
  admin1_name_en TEXT,
  admin1_name_zh TEXT,
  country_qid TEXT REFERENCES places(place_qid),
  country_name_en TEXT,
  country_name_zh TEXT,
  normalization_method TEXT NOT NULL,
  normalization_path TEXT,
  confidence REAL NOT NULL,
  status TEXT NOT NULL,
  notes TEXT
);

CREATE TABLE movie_periods (
  movie_qid TEXT NOT NULL REFERENCES movies(movie_qid) ON DELETE CASCADE,
  period_qid TEXT NOT NULL,
  period_name_en TEXT NOT NULL,
  period_name_zh TEXT NOT NULL,
  period_labels_json TEXT NOT NULL CHECK (json_valid(period_labels_json)),
  start_year INTEGER,
  end_year INTEGER,
  interval_method TEXT NOT NULL,
  PRIMARY KEY (movie_qid, period_qid)
);


CREATE TABLE time_concepts (
  concept_qid TEXT PRIMARY KEY,
  category TEXT NOT NULL,
  name_en TEXT NOT NULL,
  name_zh TEXT NOT NULL,
  labels_json TEXT NOT NULL CHECK (json_valid(labels_json)),
  start_year INTEGER,
  end_year INTEGER
);
CREATE INDEX idx_time_concepts_category ON time_concepts(category,name_en);

CREATE TABLE normalization_issues (
  id INTEGER PRIMARY KEY,
  source_target_qid TEXT REFERENCES targets(target_qid) ON DELETE CASCADE,
  movie_qid TEXT NOT NULL REFERENCES movies(movie_qid) ON DELETE CASCADE,
  raw_place_qid TEXT NOT NULL REFERENCES places(place_qid),
  raw_place_name_en TEXT NOT NULL,
  raw_place_name_zh TEXT NOT NULL,
  issue_type TEXT NOT NULL,
  status TEXT NOT NULL,
  confidence REAL NOT NULL,
  notes TEXT
);

CREATE INDEX idx_targets_names ON targets(name_en, name_zh);
CREATE INDEX idx_movies_release_year ON movies(release_year, movie_qid);
CREATE INDEX idx_movie_target_matches_target ON movie_target_matches(target_qid, movie_qid);
CREATE INDEX idx_movie_locations_movie ON movie_locations(movie_qid, raw_place_qid);
CREATE INDEX idx_movie_locations_raw_place ON movie_locations(raw_place_qid, movie_qid);
CREATE UNIQUE INDEX idx_movie_locations_regional_unique
  ON movie_locations(source_target_qid, movie_qid, raw_place_qid)
  WHERE source_target_qid IS NOT NULL;
CREATE UNIQUE INDEX idx_movie_locations_global_unique
  ON movie_locations(movie_qid, raw_place_qid)
  WHERE source_target_qid IS NULL;
CREATE INDEX idx_movie_periods_years ON movie_periods(start_year, end_year, movie_qid);
CREATE INDEX idx_normalization_issues_movie ON normalization_issues(movie_qid, raw_place_qid);
CREATE UNIQUE INDEX idx_normalization_issues_unique
  ON normalization_issues(
    COALESCE(source_target_qid,''), movie_qid, raw_place_qid, issue_type, status,
    confidence, COALESCE(notes,'')
  );
