PRAGMA foreign_keys = OFF;
CREATE TABLE metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE movie_texts (
  movie_id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  overview TEXT NOT NULL DEFAULT ''
);
