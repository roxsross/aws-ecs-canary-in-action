'use strict';

const {
  TRACKS,
  currentMinute,
  buildSeries,
  normaliseChaos,
  emptyChaosState,
} = require('./util');

const RECENT_LIMIT = 250;

// Process-local store, per task: used for `docker run` demos and as the
// fallback when DynamoDB is unreachable.
function createMemoryStore({ reason = 'no TABLE_NAME configured' } = {}) {
  const aggregates = new Map(); // `${track}#${version}` -> row
  const series = new Map(); // `${minute}#${track}` -> row
  let recent = [];
  let chaos = emptyChaosState();

  function recordHit({ track, version, taskId, latencyMs = 0, status = 200, path = '/api/hit' }) {
    const isError = Number(status) >= 500;
    const aggKey = `${track}#${version}`;
    const agg = aggregates.get(aggKey) || {
      track,
      version,
      hits: 0,
      errors: 0,
      latencySum: 0,
      lastSeen: null,
    };
    agg.hits += 1;
    agg.errors += isError ? 1 : 0;
    agg.latencySum += Number(latencyMs || 0);
    agg.lastSeen = new Date().toISOString();
    aggregates.set(aggKey, agg);

    const minute = currentMinute();
    const tsKey = `${minute}#${track}`;
    const bucket = series.get(tsKey) || { minute, track, hits: 0, errors: 0, latencySum: 0 };
    bucket.hits += 1;
    bucket.errors += isError ? 1 : 0;
    bucket.latencySum += Number(latencyMs || 0);
    series.set(tsKey, bucket);

    recent.unshift({
      at: new Date().toISOString(),
      track,
      version,
      taskId,
      latencyMs: Number(latencyMs || 0),
      status: Number(status),
      path,
    });
    if (recent.length > RECENT_LIMIT) recent.length = RECENT_LIMIT;
    return Promise.resolve();
  }

  function getAggregates() {
    return Promise.resolve([...aggregates.values()]);
  }

  function getSeries(minutes = 15) {
    const from = currentMinute() - (minutes - 1);
    const rows = [...series.values()].filter((row) => row.minute >= from);
    return Promise.resolve(buildSeries(minutes, rows));
  }

  function getRecent(limit = 40) {
    return Promise.resolve(recent.slice(0, limit));
  }

  function getChaos() {
    return Promise.resolve({ stable: { ...chaos.stable }, canary: { ...chaos.canary } });
  }

  function getChaosLocal() {
    return chaos;
  }

  function setChaos(track, patch) {
    if (!TRACKS.includes(track)) throw new Error(`unknown track: ${track}`);
    chaos[track] = normaliseChaos({
      ...chaos[track],
      ...patch,
      updatedAt: new Date().toISOString(),
    });
    return Promise.resolve(chaos[track]);
  }

  function clearChaos() {
    chaos = emptyChaosState();
    return Promise.resolve(chaos);
  }

  function reset() {
    aggregates.clear();
    series.clear();
    recent = [];
    return Promise.resolve({ cleared: true });
  }

  return {
    kind: 'memory',
    reason,
    init: async () => ({ kind: 'memory', reason }),
    health: () => ({ kind: 'memory', degraded: false, reason, lastError: null }),
    recordHit,
    getAggregates,
    getSeries,
    getRecent,
    getChaos,
    getChaosLocal,
    setChaos,
    clearChaos,
    reset,
    stop: () => {},
  };
}

module.exports = { createMemoryStore };
