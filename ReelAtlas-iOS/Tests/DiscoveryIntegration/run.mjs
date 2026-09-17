import fs from 'node:fs';
import assert from 'node:assert/strict';

// Read only the public publishable key shipped by the app; never use service_role.
const source = fs.readFileSync(new URL('../../ReelAtlas/Core/MovieMetadataRequest.swift', import.meta.url), 'utf8');
const key = source.match(/sb_publishable_[A-Za-z0-9_-]+/)[0];
const baseline = JSON.parse(fs.readFileSync(new URL('./baseline.json', import.meta.url)));
const stress = ['%', '_', '\\', '纽约', 'war', 'a\nb', 'Q25167']
  .map(p_query => ({args: {p_query, p_limit: 16}}));
for (const {args, expected} of [...baseline, ...stress]) {
  const start = Date.now();
  const response = await fetch('https://injisguyqfxfwgnbtghe.supabase.co/rest/v1/rpc/reelatlas_discover', {
    method: 'POST', headers: {apikey: key, 'Content-Type': 'application/json'}, body: JSON.stringify(args),
    signal: AbortSignal.timeout(15000)
  });
  const rows = await response.json();
  assert.equal(response.status, 200, JSON.stringify({args, rows}));
  if (expected) {
    assert.deepEqual(rows, expected);
  }
  console.log(JSON.stringify({args, count: rows.length, ms: Date.now() - start, passed: true}));
}
