#!/usr/bin/env node
'use strict';

/**
 * Minimal end to end probe used by CI and by `make smoke`.
 * Checks the endpoints the ALB, the dashboard and the canary scripts depend on.
 *
 *   BASE_URL=http://localhost:8080 node scripts/smoke.js
 */

const baseUrl = (process.env.BASE_URL || 'http://localhost:8080').replace(/\/$/, '');
const timeoutMs = Number.parseInt(process.env.SMOKE_TIMEOUT_MS, 10) || 8000;
const retries = Number.parseInt(process.env.SMOKE_RETRIES, 10) || 20;

const results = [];

async function request(path, init = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${baseUrl}${path}`, { ...init, signal: controller.signal });
    const text = await res.text();
    let body = text;
    try {
      body = JSON.parse(text);
    } catch {
      /* plain text endpoint */
    }
    return { status: res.status, headers: res.headers, body };
  } finally {
    clearTimeout(timer);
  }
}

async function waitForApp() {
  for (let attempt = 1; attempt <= retries; attempt += 1) {
    try {
      const res = await request('/api/health');
      if (res.status === 200) return;
    } catch {
      /* not up yet */
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`app at ${baseUrl} never became healthy after ${retries} attempts`);
}

async function check(name, fn) {
  try {
    const detail = await fn();
    results.push({ name, ok: true, detail: detail || '' });
    console.log(`  ok   ${name}${detail ? ` — ${detail}` : ''}`);
  } catch (err) {
    results.push({ name, ok: false, detail: err.message });
    console.error(`  FAIL ${name} — ${err.message}`);
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function main() {
  console.log(`smoke testing ${baseUrl}`);
  await waitForApp();

  await check('GET /api/health returns 200', async () => {
    const res = await request('/api/health');
    assert(res.status === 200, `got ${res.status}`);
    assert(res.body.ok === true, 'body.ok is not true');
    return `track=${res.body.track} version=${res.body.version}`;
  });

  await check('GET /api/config exposes palette and tracks', async () => {
    const res = await request('/api/config');
    assert(res.status === 200, `got ${res.status}`);
    assert(res.body.palette?.stable?.accent, 'missing stable palette');
    assert(res.body.palette?.canary?.accent, 'missing canary palette');
    assert(Array.isArray(res.body.tracks), 'tracks is not an array');
    return `persistence=${res.body.persistence?.kind}`;
  });

  await check('GET /api/hit records traffic and identifies the track', async () => {
    const res = await request('/api/hit');
    assert(res.status === 200, `got ${res.status}`);
    assert(res.headers.get('x-track'), 'missing X-Track header');
    assert(typeof res.body.seq === 'number', 'missing seq');
    return `x-track=${res.headers.get('x-track')} seq=${res.body.seq}`;
  });

  await check('GET /api/stats aggregates the hit', async () => {
    const res = await request('/api/stats?minutes=5&recent=5');
    assert(res.status === 200, `got ${res.status}`);
    assert(res.body.totals, 'missing totals');
    assert(Array.isArray(res.body.series), 'missing series');
    assert(res.body.totals.hits >= 1, `expected at least 1 hit, got ${res.body.totals.hits}`);
    return `hits=${res.body.totals.hits} series=${res.body.series.length} buckets`;
  });

  await check('chaos round trip (fail 100% then clear)', async () => {
    const headers = { 'Content-Type': 'application/json' };
    if (process.env.ADMIN_TOKEN) headers['X-Admin-Token'] = process.env.ADMIN_TOKEN;
    const track = process.env.TRACK || 'stable';
    const set = await request('/api/chaos', {
      method: 'POST',
      headers,
      body: JSON.stringify({ track, failRate: 100 }),
    });
    assert(set.status === 200, `set chaos got ${set.status}`);
    const failing = await request('/api/hit');
    assert(failing.status === 500, `expected an injected 500, got ${failing.status}`);
    const cleared = await request('/api/chaos', { method: 'DELETE', headers });
    assert(cleared.status === 200, `clear chaos got ${cleared.status}`);
    const healthy = await request('/api/hit');
    assert(healthy.status === 200, `expected recovery, got ${healthy.status}`);
    return 'injected 500 and recovered';
  });

  await check('GET /metrics serves prometheus text', async () => {
    const res = await request('/metrics');
    assert(res.status === 200, `got ${res.status}`);
    assert(String(res.body).includes('canary_requests_total'), 'missing canary_requests_total');
    return 'exposition format ok';
  });

  await check('GET / serves the dashboard', async () => {
    const res = await request('/');
    assert(res.status === 200, `got ${res.status}`);
    assert(String(res.body).includes('<!DOCTYPE html>'), 'response is not html');
    return 'dashboard html ok';
  });

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length > 0) process.exit(1);
}

main().catch((err) => {
  console.error(`smoke run aborted: ${err.message}`);
  process.exit(1);
});
