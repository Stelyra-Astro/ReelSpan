# Supabase search: deployed work and unresolved risks

Project: `injisguyqfxfwgnbtghe`. Status: optimization incomplete; further deployment paused by the user. Client Build 13 release is independent of these remaining server changes.

## Root causes

1. The released search delegate joined roughly 50,000 story rows and metadata, read/cast/lowered wide JSON fields, calculated scores for the entire catalogue and only then paginated. Default browse and filtered/search paths did not share the same fast path.
2. Generic plans and materialized input hid actual filter selectivity. Bad cardinality estimates forced full-table joins for tiny candidate sets; forced point lookups then became costly for broad matches.
3. A trigram candidate index alone cannot eliminate expensive heap rechecks of large cast JSON. Broad substrings still match thousands of rows and repeatedly read wide text. This is a general input-frequency/field-width issue, not a special `war` bug.
4. Anonymous database statements originally timed out after 3 seconds. The role now has a 5-second limit, but raising that limit does not optimize a query and affects other anonymous statements in this project.

## Already deployed

Default browse ID-first pagination; combined text trigram candidates; preserved literal wildcard semantics and relevance scores; scoped geography/time candidates; bound parameter-aware dynamic SQL; private lowercased text projection with restricted incremental trigger; point lookup plans; literal character/pair indexes; explicit character order; prefiltered pagination and delayed display metadata; field-level trigram indexes.

Latest confirmed migration: `discover_field_rank_indexes`, remote version `20260917035304`. Local migration names/timestamps differ from MCP history versions; do not blindly replay historical root migrations with `db push` against this existing project.

## Evidence and failures

- Original Titanic query: approximately 7.01 seconds database execution and anonymous SQLSTATE 57014.
- Before final field indexes, nine full-JSON regression cases passed; literal `%`, `_`, backslash and Chinese `纽约` also returned HTTP 200. High-frequency `war` still returned HTTP 500 / 57014 at the 5-second limit.
- The proposed adaptive field-plan experiment after field indexes measured 8.429 seconds in EXPLAIN ANALYZE; metadata field rechecks accounted for a substantial part. It was a read-only diagnostic, not a deployed adaptive function or passing performance result.
- Live metadata enrichment changed a New York snapshot during a repeat. Full parity should use one current transaction snapshot for original and optimized queries. A stale fixture failure is not automatically proof of a search regression, nor permission to replace expected data without investigation.
- One four-column generated-column rewrite was cancelled before commit after excessive work and brief schema-cache 503 responses. The committed replacement avoids this rewrite.
- Some MCP migration calls returned HTTP 504 even though the backend later committed. Migration history and active backend state were checked before retrying; a transport timeout is not a reliable rollback signal.

## Deferred generic redesign

Search all fields as bounded inline chunks, with 79-character overlap preserving all allowed <=80-character literal matches. Aggregate candidate scores before story mapping and let bound input inform join planning. This avoids reading a whole large cast document for each broad match; no word-specific exceptions are intended.

The preparation migration was rejected by safety review because source-table write locks plus bulk backfill could interrupt production writes. It did NOT execute; activation did not execute either. Drafts were moved outside the migration directory. Deployment requires an explicitly approved maintenance/write-lock window or a safer online backfill design, isolated correctness/concurrency tests and broad performance verification first.

No claim is made that all high-frequency searches are fixed, that drafts pass real database tests, or that a new client archive alone fixes the remaining Supabase path.
