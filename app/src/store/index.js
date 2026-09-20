'use strict';

const { createMemoryStore } = require('./memory');
const { createDynamoStore } = require('./dynamo');
const { summarise } = require('./util');

/**
 * Builds the store the app will use.
 *
 * With a table configured we keep a *shadow* in-memory store alongside DynamoDB:
 * every hit is recorded in both, so if the table is throttled, missing or the
 * task lacks IAM permissions the dashboard degrades to per task counters instead
 * of going blank mid demo.
 */
function createStore(config) {
  const shadow = createMemoryStore({ reason: 'shadow copy of DynamoDB writes' });

  if (config.persistence !== 'dynamodb') {
    const store = createMemoryStore({
      reason: config.recordMode === 'off' ? 'RECORD_MODE=off' : 'no TABLE_NAME configured',
    });
    return decorate(store, store, config);
  }

  const primary = createDynamoStore({
    tableName: config.tableName,
    region: config.region,
    endpoint: config.dynamoEndpoint,
    recordMode: config.recordMode,
    hitFeedTtlSeconds: config.hitFeedTtlSeconds,
    seriesTtlSeconds: config.seriesTtlSeconds,
    chaosPollMs: config.chaosPollMs,
  });

  const composite = {
    kind: 'dynamodb',
    table: config.tableName,
    init: async () => {
      await shadow.init();
      return primary.init();
    },
    health: () => {
      const health = primary.health();
      return { ...health, fallback: health.degraded ? 'memory' : null };
    },
    recordHit: async (hit) => {
      shadow.recordHit(hit);
      return primary.recordHit(hit);
    },
    getAggregates: async () => {
      const rows = await primary.getAggregates();
      if (rows.length === 0 && primary.health().degraded) return shadow.getAggregates();
      return rows;
    },
    getSeries: async (minutes) => {
      if (primary.health().degraded) return shadow.getSeries(minutes);
      return primary.getSeries(minutes);
    },
    getRecent: async (limit) => {
      const rows = await primary.getRecent(limit);
      if (rows.length === 0 && primary.health().degraded) return shadow.getRecent(limit);
      return rows;
    },
    getChaos: async () => {
      if (primary.health().degraded) return shadow.getChaos();
      return primary.getChaos();
    },
    getChaosLocal: () => {
      if (primary.health().degraded) return shadow.getChaosLocal();
      return primary.getChaosLocal();
    },
    setChaos: async (track, patch) => {
      await shadow.setChaos(track, patch);
      try {
        return await primary.setChaos(track, patch);
      } catch (err) {
        console.error(
          JSON.stringify({
            level: 'error',
            msg: 'chaos write to dynamodb failed, applied locally only',
            error: err.message,
          }),
        );
        return shadow.getChaosLocal()[track];
      }
    },
    clearChaos: async () => {
      await shadow.clearChaos();
      return primary.clearChaos();
    },
    reset: async () => {
      await shadow.reset();
      return primary.reset();
    },
    stop: () => {
      primary.stop();
      shadow.stop();
    },
  };

  return decorate(composite, shadow, config);
}

/** Adds the composed read used by /api/stats. */
function decorate(store, shadow, config) {
  store.getSnapshot = async ({ minutes = 15, recent = 40 } = {}) => {
    const [aggregates, series, recentHits, chaos] = await Promise.all([
      store.getAggregates(),
      store.getSeries(minutes),
      store.getRecent(recent),
      store.getChaos(),
    ]);
    const { totals, byTrack } = summarise(aggregates);
    return {
      generatedAt: new Date().toISOString(),
      persistence: store.health(),
      window: { minutes },
      totals,
      tracks: byTrack,
      series,
      recent: recentHits,
      chaos,
      project: config.project,
      region: config.region,
    };
  };
  store.shadow = shadow;
  return store;
}

module.exports = { createStore };
