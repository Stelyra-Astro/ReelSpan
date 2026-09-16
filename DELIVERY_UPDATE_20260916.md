# ReelSpan · list, discovery, contributions and web demo

Based solely on the user's uploaded `ReelSpan-main(2).zip`. No GitHub read, write or push was performed.

## App changes

- List mode remains the default; recommended results place the device-location country first, or the US if location is unavailable. This is a soft sort and does not set Where.
- Group by place displays continent → country → films, deduplicated within each country. Group by time merges overlapping spans and shows centuries; missing time is kept separately. Non-informative spans wider than 3,000 years get a broad/uncertain category to prevent thousands of headings.
- Where is continent → country → city using a Supabase materialized directory of countries and cities with films. It caches on the device and checks a revision; network failure offers a retry instead of an endless spinner.
- When's calendar category starts with centuries; exact dates/months/years are kept as underlying evidence rather than incorrectly displayed as historical eras. Verified people and historical states have been added to the server; no movie is tagged as being *about* a person merely because its story is contemporary.
- Search includes titles, places, periods, genres, descriptions, and cast/director metadata when available. TMDB metadata remains incomplete for some films.
- Public brand is ReelSpan, Data Sources identifies content sources versus infrastructure; contribution buttons open a dedicated full-screen flow from both list and map, with correction entry points in list rows and movie details.
- New-film proposals require title plus at least one story time and place. TMDB ID, IMDb ID and historical tags are optional. Existing-film suggestions accept ONLY multiple time/place entries (including historical text). The contribution hub shows missing-time/place categories, per-owner status totals, history and moderator notes.

## Supabase state

The production project has received the Where cache/refresh, region ordering, contribution inbox and exact-count RPC, calendar/BCE cleanup, and initial verified biography/state catalog migrations. Supabase currently lists 49,995 movies, 1,086 Where entries, 18 people and 19 regimes; 10 original tables remain in the same-project data-only snapshot. The contribution inbox is private, proposals do not automatically change production story data; see `CONTRIBUTIONS_REVIEW.md`.

## GitHub Pages

`index.html`, `styles.css` and `demo.js` comprise the updated static landing and interactive phone simulator. The preview supports filters, map/list, grouping, film details, favorites and a local-only contribution sample. It uses **illustrative content**, does not fetch production catalog data, and does not send a real contribution. The original `privacy/`, `terms/`, and `tmdb/` pages are retained and updated to describe community submissions. Deploy the website files with your normal GitHub Pages workflow.

## Limitations and verification

This Linux environment can parse Swift but cannot compile an iOS app or install it on a device; Codex's earlier reported 95 tests were on a previous code version. Static source tests, standalone Swift grouping test and JavaScript syntax were run for this delivery. Automated browser loading was blocked by the environment's browser policy; open the website in a normal browser for click-through QA. Keep the existing app's cache/favorites through upgrades; do not reset keys or bundle ID solely to change display branding. Map-to-list transition performance was intentionally deferred.
