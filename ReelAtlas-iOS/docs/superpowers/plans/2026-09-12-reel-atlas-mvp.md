# Reel Atlas MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native SwiftUI/MapKit iOS MVP with local SQLite content, local favorites, year/place filtering, administrative fallback, movie details, settings, optional large-image downloads and StoreKit 2 one-time purchase plumbing.

**Architecture:** Pure Swift core rules are isolated and Linux-testable. The iOS app consumes the same core models, reads a bundled seed SQLite database copied to Application Support, and keeps user state in a separate SQLite database. SwiftUI views use MapKit; optional image downloads write to Application Support and never change the content database.

**Tech Stack:** Swift 6-compatible source, SwiftUI, MapKit, SQLite3, StoreKit 2, URLSession, XCTest/Swift Testing via SwiftPM core tests.

**Spec:** `docs/superpowers/specs/2026-09-12-reel-atlas-mvp-design.md`

## Global Constraints
- iOS 17+.
- No third-party dependencies.
- No account or custom backend.
- Apple Maps / MapKit only.
- Independent time ranges and administrative location fallback.
- Preferred language => English => original language fallback.
- Small posters bundled locally; large poster/backdrop optional local download.
- Content DB and user DB remain separate.

---

### Task 1: Core domain and filtering rules
**Files:** `Package.swift`, `ReelAtlas/Core/*.swift`, `Tests/ReelAtlasCoreTests/*.swift`
**Produces:** Movie domain models, story-year matcher, language resolver, Bayesian ranking, location fallback resolver.
- [ ] Write failing tests for independent time ranges, contemporary normalization, language fallback, Bayesian ranking behavior, and parent fallback.
- [ ] Run `swift test` and confirm tests fail because APIs are missing.
- [ ] Implement minimal core types and rules.
- [ ] Run `swift test` and confirm all tests pass.

### Task 2: Local SQLite data contract and seed
**Files:** `Data/schema.sql`, `Data/sample_movies.json`, `Data/content_seed.sqlite`, `ReelAtlas/Data/*.swift`, `docs/DATA_PIPELINE.md`
**Produces:** Wikidata-aligned schema and sample database plus iOS repositories.
- [ ] Define normalized/raw provenance tables and sample records.
- [ ] Build bundled SQLite seed with local poster filenames and localization rows.
- [ ] Implement read-only content repository and separate writable favorites database.
- [ ] Document Wikidata P2408/P840 normalization and TMDB enrichment mapping.

### Task 3: Native SwiftUI shell and MapKit home
**Files:** `ReelAtlas/App/*.swift`, `ReelAtlas/Features/Home/*.swift`, `ReelAtlas/Resources/*`, `ReelAtlas.xcodeproj/*`
**Produces:** Native app, Apple map, place search, year controls, pin and bottom movie list.
- [ ] Create Xcode project and app entry point.
- [ ] Wire local repository into app model.
- [ ] Implement MapKit search and selected pin.
- [ ] Implement slider/direct year picker and exact->parent location fallback disclosure.
- [ ] Implement movie cards with story locations/times and favorite toggle.

### Task 4: Movie detail and local images
**Files:** `ReelAtlas/Features/MovieDetail/*.swift`, `ReelAtlas/Services/ImageDownloadManager.swift`, `ReelAtlas/Resources/SmallPosters/*`
**Produces:** Detail page and optional local large-image cache.
- [ ] Implement backdrop/poster hero with local-image fallback.
- [ ] Display overview, director, cast, details, genres, all time ranges and locations.
- [ ] Implement download manager for large poster/backdrop URLs and clear/cache-size operations.

### Task 5: Settings, localization, purchase plumbing and legal pages
**Files:** `ReelAtlas/Features/Settings/*.swift`, `ReelAtlas/Services/PurchaseManager.swift`, `ReelAtlas/Resources/Legal/*`
**Produces:** Complete settings surface and StoreKit 2 manager.
- [ ] Add system-language default and language resolver explanation/selection.
- [ ] Add Local Data placeholder section and image download controls.
- [ ] Add purchase/restore UI and StoreKit 2 non-consumable manager.
- [ ] Add Privacy, Terms, Data Sources, TMDB Attribution, Licenses, Help, About.

### Task 6: Verification and delivery
**Files:** all project files plus `README.md`
**Produces:** zipped Xcode project with verified core tests and structural checks.
- [ ] Run `swift test` fresh.
- [ ] Validate SQLite schema/queries with Python sqlite3.
- [ ] Validate `.pbxproj` references and Swift file inventory structurally (full Xcode build unavailable in Linux environment).
- [ ] Create ZIP and record exact Xcode-side verification steps in README.
