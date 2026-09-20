'use strict';

const TRACKS = ['stable', 'canary'];
const MINUTE_MS = 60_000;

const DEFAULT_CHAOS = Object.freeze({
  failRate: 0,
  latencyMs: 0,
  unhealthy: false,
  updatedAt: null,
});

function currentMinute(now = Date.now()) {
  return Math.floor(now / MINUTE_MS);
}

/** Zero padded so lexicographic sort keys match numeric order in DynamoDB. */
function pad(value, width) {
  return String(value).padStart(width, '0');
}

function emptySlot() {
  return { hits: 0, errors: 0, latencySum: 0 };
}

function emptyBucket(minute) {
  return {
    minute,
    at: new Date(minute * MINUTE_MS).toISOString(),
    stable: emptySlot(),
    canary: emptySlot(),
  };
}

/**
 * Normalises raw per-minute rows into a dense series so the dashboard chart
 * never has to deal with gaps.
 * @param {number} minutes how many buckets back from now
 * @param {Array<{minute:number, track:string, hits:number, errors:number, latencySum:number}>} rows
 */
function buildSeries(minutes, rows) {
  const to = currentMinute();
  const from = to - (minutes - 1);
  const buckets = new Map();
  for (let minute = from; minute <= to; minute += 1) {
    buckets.set(minute, emptyBucket(minute));
  }
  for (const row of rows) {
    const bucket = buckets.get(Number(row.minute));
    if (!bucket) continue;
    const track = TRACKS.includes(row.track) ? row.track : null;
    if (!track) continue;
    bucket[track].hits += Number(row.hits || 0);
    bucket[track].errors += Number(row.errors || 0);
    bucket[track].latencySum += Number(row.latencySum || 0);
  }
  return [...buckets.values()];
}

function normaliseChaos(raw = {}) {
  const failRate = Math.min(100, Math.max(0, Number(raw.failRate || 0)));
  const latencyMs = Math.min(30_000, Math.max(0, Number(raw.latencyMs || 0)));
  return {
    failRate,
    latencyMs,
    unhealthy: Boolean(raw.unhealthy),
    updatedAt: raw.updatedAt || null,
  };
}

function emptyChaosState() {
  return {
    stable: { ...DEFAULT_CHAOS },
    canary: { ...DEFAULT_CHAOS },
  };
}

function summarise(aggregates) {
  const totals = { hits: 0, errors: 0 };
  const byTrack = {
    stable: { hits: 0, errors: 0, latencySum: 0, versions: [] },
    canary: { hits: 0, errors: 0, latencySum: 0, versions: [] },
  };
  for (const row of aggregates) {
    const slot = byTrack[row.track];
    if (!slot) continue;
    slot.hits += Number(row.hits || 0);
    slot.errors += Number(row.errors || 0);
    slot.latencySum += Number(row.latencySum || 0);
    slot.versions.push({
      version: row.version,
      hits: Number(row.hits || 0),
      errors: Number(row.errors || 0),
      lastSeen: row.lastSeen || null,
    });
    totals.hits += Number(row.hits || 0);
    totals.errors += Number(row.errors || 0);
  }
  for (const track of TRACKS) {
    const slot = byTrack[track];
    const avg = slot.hits ? slot.latencySum / slot.hits : 0;
    // Keep two decimals for sub-10ms handlers, whole milliseconds otherwise.
    slot.avgLatencyMs = Number(avg.toFixed(avg < 10 ? 2 : 0));
    slot.errorRate = slot.hits ? Number(((slot.errors / slot.hits) * 100).toFixed(2)) : 0;
    slot.share = 0;
    slot.versions.sort((a, b) => b.hits - a.hits);
  }
  if (totals.hits > 0) {
    byTrack.stable.share = Number(((byTrack.stable.hits / totals.hits) * 100).toFixed(1));
    byTrack.canary.share = Number((100 - byTrack.stable.share).toFixed(1));
  }
  totals.errorRate = totals.hits ? Number(((totals.errors / totals.hits) * 100).toFixed(2)) : 0;
  return { totals, byTrack };
}

module.exports = {
  TRACKS,
  MINUTE_MS,
  DEFAULT_CHAOS,
  currentMinute,
  pad,
  emptySlot,
  emptyBucket,
  buildSeries,
  normaliseChaos,
  emptyChaosState,
  summarise,
};
