# Location Overview Import and Lazy TMDB Plan

> Execute this plan in the current session with test-first checkpoints.

1. Extend importer fixtures and schema for the seven supplied overview/source fields.
2. Make global merging update overlapping movies and remain idempotent.
3. Include movies without story periods only for the complete 1600–2100 selection.
4. Add Codable TMDB details, on-demand persistent metadata/image caching, and safe API-IP TLS fallback.
5. Wire visible rows and details to request and render enrichment; saving a key performs no fetch.
6. Import the supplied archive, verify counts/integrity/duplicates/nulls, build, and install on the iPhone 12 mini.
