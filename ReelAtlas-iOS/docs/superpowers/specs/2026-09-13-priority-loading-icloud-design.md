# Priority Loading and iCloud Backup Design

- Visible movie rows wait one second, with at most two low-priority requests active.
- Opening a detail view cancels queued/background row work and immediately starts that movie at high priority.
- Leaving a view cancels its API and image work. Returning restarts only currently visible rows.
- TMDB genres replace CSV genres after enrichment; CSV remains the offline fallback.
- iCloud stores a versioned snapshot of favorite movie QIDs and interface language plus the existing on-demand TMDB metadata and `w185` poster cache. It never stores the API key or content database and never triggers new downloads.
- Settings expose language, iCloud sync/status, TMDB key/removal, clear cache, legal/support links, website, and app version. Internal database/cache diagnostics are hidden.
