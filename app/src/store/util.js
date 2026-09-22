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

function emptyRoleSlot() {
  return { hits: 0, errors: 0, latencySum: 0, versions: [], avgLatencyMs: 0, errorRate: 0, share: 0 };
}

// Turns an accumulated {hits,errors,latencySum} into a card-ready slot, with a
// single-version list so the card shows that version and its own stats.
function finaliseSlot(v) {
  const avg = v.hits ? v.latencySum / v.hits : 0;
  return {
    hits: v.hits,
    errors: v.errors,
    latencySum: v.latencySum,
    versions: [{ version: v.version, hits: v.hits, errors: v.errors, lastSeen: v.lastSeen || null }],
    avgLatencyMs: Number(avg.toFixed(avg < 10 ? 2 : 0)),
    errorRate: v.hits ? Number(((v.errors / v.hits) * 100).toFixed(2)) : 0,
    share: 0,
  };
}

// AWS native-canary mode: every task reports track=stable (there is no fixed
// "canary" service to set TRACK=canary), so the real differentiator between
// the running revisions is APP_VERSION, not track. Re-derives the two card
// slots from the versions actually serving right now — identified by presence
// in the recent hit feed, falling back to the most recent lastSeen — instead
// of piling every version ever seen onto "stable" (which also made the stable
// card show the highest all-time version, e.g. the long-retired 1.0.1, rather
// than what's live). The version taking the majority of recent traffic is the
// stable role; the minority one, present only during a rollout, is the canary.
function rolesByVersion(aggregates, recentHits) {
  const byVersion = new Map();
  for (const row of aggregates) {
    if (!row.version) continue;
    const slot = byVersion.get(row.version) || {
      version: row.version,
      hits: 0,
      errors: 0,
      latencySum: 0,
      lastSeen: null,
    };
    slot.hits += Number(row.hits || 0);
    slot.errors += Number(row.errors || 0);
    slot.latencySum += Number(row.latencySum || 0);
    if (row.lastSeen && (!slot.lastSeen || row.lastSeen > slot.lastSeen)) slot.lastSeen = row.lastSeen;
    byVersion.set(row.version, slot);
  }
  if (byVersion.size === 0) return null;

  const recentByVersion = new Map();
  for (const hit of recentHits || []) {
    if (!hit || !hit.version) continue;
    recentByVersion.set(hit.version, (recentByVersion.get(hit.version) || 0) + 1);
  }

  let ranked;
  if (recentByVersion.size > 0) {
    // Currently-serving versions, ordered by their share of recent traffic.
    ranked = [...byVersion.values()]
      .filter((v) => recentByVersion.has(v.version))
      .sort((a, b) => (recentByVersion.get(b.version) || 0) - (recentByVersion.get(a.version) || 0));
  } else {
    // No recent feed (quiet period): fall back to whichever version was seen last.
    ranked = [...byVersion.values()].sort((a, b) =>
      String(b.lastSeen || '').localeCompare(String(a.lastSeen || '')),
    );
  }
  if (ranked.length === 0) ranked = [...byVersion.values()].sort((a, b) => b.hits - a.hits);

  return {
    stable: finaliseSlot(ranked[0]),
    canary: ranked[1] ? finaliseSlot(ranked[1]) : emptyRoleSlot(),
  };
}

function summarise(aggregates, recentHits = []) {
  const totals = { hits: 0, errors: 0 };
  let byTrack = {
    stable: { hits: 0, errors: 0, latencySum: 0, versions: [] },
    canary: { hits: 0, errors: 0, latencySum: 0, versions: [] },
  };
  for (const row of aggregates) {
    const slot = byTrack[row.track];
    if (slot) {
      slot.hits += Number(row.hits || 0);
      slot.errors += Number(row.errors || 0);
      slot.latencySum += Number(row.latencySum || 0);
      slot.versions.push({
        version: row.version,
        hits: Number(row.hits || 0),
        errors: Number(row.errors || 0),
        lastSeen: row.lastSeen || null,
      });
    }
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

  // When no task ever reported track=canary (the native ECS model, where the
  // canary is a new APP_VERSION rather than a separate service), roles come
  // from the versions, not the track. Local/mini-alb, which does run a real
  // canary service, keeps the track-based grouping untouched. roleBasis tells
  // the frontend which identity to group recent-task lists by.
  const hasCanaryTrack = aggregates.some((row) => row.track === 'canary' && Number(row.hits) > 0);
  let roleBasis = 'track';
  if (!hasCanaryTrack) {
    const roled = rolesByVersion(aggregates, recentHits);
    if (roled) {
      byTrack = roled;
      roleBasis = 'version';
    }
  }

  // Share is the split between the two slots (in local mode stable+canary is
  // the whole population, so this matches the old totals-based definition).
  const pairHits = byTrack.stable.hits + byTrack.canary.hits;
  if (pairHits > 0) {
    byTrack.stable.share = Number(((byTrack.stable.hits / pairHits) * 100).toFixed(1));
    byTrack.canary.share = Number((100 - byTrack.stable.share).toFixed(1));
  }
  totals.errorRate = totals.hits ? Number(((totals.errors / totals.hits) * 100).toFixed(2)) : 0;
  return { totals, byTrack, roleBasis };
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
