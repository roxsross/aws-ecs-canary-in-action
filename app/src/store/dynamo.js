'use strict';

const {
  DynamoDBClient,
  CreateTableCommand,
  UpdateTimeToLiveCommand,
} = require('@aws-sdk/client-dynamodb');
const {
  DynamoDBDocumentClient,
  UpdateCommand,
  PutCommand,
  QueryCommand,
  BatchWriteCommand,
} = require('@aws-sdk/lib-dynamodb');

const {
  TRACKS,
  currentMinute,
  pad,
  buildSeries,
  normaliseChaos,
  emptyChaosState,
} = require('./util');

const PK = { AGG: 'AGG', TS: 'TS', HIT: 'HIT', CHAOS: 'CHAOS' };
const MINUTE_KEY_WIDTH = 12;
const MS_KEY_WIDTH = 15;
const ERROR_LOG_THROTTLE_MS = 30_000;

// Single table shared by every task of every track:
//   pk=AGG    sk=<track>#<version>   rolling counters per track+version
//   pk=TS     sk=<minute>#<track>    per minute buckets for the timeline chart
//   pk=HIT    sk=<epochMs>#<rand>    recent request feed (TTL)
//   pk=CHAOS  sk=<track>             fault injection state, polled by all tasks
function createDynamoStore(options) {
  const {
    tableName,
    region,
    endpoint = '',
    recordMode = 'full',
    hitFeedTtlSeconds = 1800,
    seriesTtlSeconds = 10_800,
    chaosPollMs = 3000,
  } = options;

  const client = new DynamoDBClient({
    region,
    ...(endpoint ? { endpoint } : {}),
    maxAttempts: 3,
  });
  const doc = DynamoDBDocumentClient.from(client, {
    marshallOptions: { removeUndefinedValues: true },
  });

  const state = {
    degraded: false,
    lastError: null,
    lastErrorAt: null,
    writeErrors: 0,
    readErrors: 0,
    lastLoggedAt: 0,
  };

  let chaosCache = emptyChaosState();
  let chaosTimer = null;

  function noteError(scope, err) {
    state.degraded = true;
    state.lastError = `${scope}: ${err.name || 'Error'} ${err.message}`;
    state.lastErrorAt = new Date().toISOString();
    if (scope === 'write') state.writeErrors += 1;
    else state.readErrors += 1;
    const now = Date.now();
    if (now - state.lastLoggedAt > ERROR_LOG_THROTTLE_MS) {
      state.lastLoggedAt = now;
      console.error(
        JSON.stringify({
          level: 'error',
          msg: 'dynamodb operation failed, serving in degraded mode',
          scope,
          error: state.lastError,
          table: tableName,
        }),
      );
    }
  }

  function noteSuccess() {
    if (state.degraded) {
      state.degraded = false;
      console.log(
        JSON.stringify({ level: 'info', msg: 'dynamodb recovered', table: tableName }),
      );
    }
  }

  const ttl = (seconds) => Math.floor(Date.now() / 1000) + seconds;

  // Only used against dynamodb-local. Retries since the Java process takes a
  // moment to accept connections.
  async function ensureLocalTable({ attempts = 8, delayMs = 2500 } = {}) {
    if (!endpoint) return;
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        await client.send(
          new CreateTableCommand({
            TableName: tableName,
            BillingMode: 'PAY_PER_REQUEST',
            AttributeDefinitions: [
              { AttributeName: 'pk', AttributeType: 'S' },
              { AttributeName: 'sk', AttributeType: 'S' },
            ],
            KeySchema: [
              { AttributeName: 'pk', KeyType: 'HASH' },
              { AttributeName: 'sk', KeyType: 'RANGE' },
            ],
          }),
        );
        console.log(JSON.stringify({ level: 'info', msg: 'created local table', table: tableName }));
        await client
          .send(
            new UpdateTimeToLiveCommand({
              TableName: tableName,
              TimeToLiveSpecification: { Enabled: true, AttributeName: 'expiresAt' },
            }),
          )
          .catch(() => {});
        return;
      } catch (err) {
        if (err.name === 'ResourceInUseException') return; // already created by the other track
        if (attempt === attempts) {
          console.warn(
            JSON.stringify({
              level: 'warn',
              msg: 'could not ensure local table, continuing in degraded mode',
              attempts,
              error: err.message,
            }),
          );
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      }
    }
  }

  async function recordHit({ track, version, taskId, latencyMs = 0, status = 200, path = '/api/hit' }) {
    if (recordMode === 'off') return;
    const isError = Number(status) >= 500;
    const now = new Date().toISOString();
    const writes = [];

    writes.push(
      doc.send(
        new UpdateCommand({
          TableName: tableName,
          Key: { pk: PK.AGG, sk: `${track}#${version}` },
          UpdateExpression:
            'SET #lastSeen = :now, #track = :track, #version = :version ' +
            'ADD #hits :one, #errors :err, #latencySum :lat',
          ExpressionAttributeNames: {
            '#lastSeen': 'lastSeen',
            '#track': 'track',
            '#version': 'version',
            '#hits': 'hits',
            '#errors': 'errors',
            '#latencySum': 'latencySum',
          },
          ExpressionAttributeValues: {
            ':now': now,
            ':track': track,
            ':version': version,
            ':one': 1,
            ':err': isError ? 1 : 0,
            ':lat': Number(latencyMs || 0),
          },
        }),
      ),
    );

    if (recordMode === 'full') {
      const minute = currentMinute();
      writes.push(
        doc.send(
          new UpdateCommand({
            TableName: tableName,
            Key: { pk: PK.TS, sk: `${pad(minute, MINUTE_KEY_WIDTH)}#${track}` },
            UpdateExpression:
              'SET #expiresAt = :exp, #track = :track, #minute = :minute ' +
              'ADD #hits :one, #errors :err, #latencySum :lat',
            ExpressionAttributeNames: {
              '#expiresAt': 'expiresAt',
              '#track': 'track',
              '#minute': 'minute',
              '#hits': 'hits',
              '#errors': 'errors',
              '#latencySum': 'latencySum',
            },
            ExpressionAttributeValues: {
              ':exp': ttl(seriesTtlSeconds),
              ':track': track,
              ':minute': minute,
              ':one': 1,
              ':err': isError ? 1 : 0,
              ':lat': Number(latencyMs || 0),
            },
          }),
        ),
      );

      const rand = Math.random().toString(36).slice(2, 8);
      writes.push(
        doc.send(
          new PutCommand({
            TableName: tableName,
            Item: {
              pk: PK.HIT,
              sk: `${pad(Date.now(), MS_KEY_WIDTH)}#${rand}`,
              at: now,
              track,
              version,
              taskId,
              latencyMs: Number(latencyMs || 0),
              status: Number(status),
              path,
              expiresAt: ttl(hitFeedTtlSeconds),
            },
          }),
        ),
      );
    }

    try {
      await Promise.all(writes);
      noteSuccess();
    } catch (err) {
      noteError('write', err);
    }
  }

  async function queryAll(params, cap = 20) {
    const items = [];
    let key;
    let pages = 0;
    do {
      const res = await doc.send(
        new QueryCommand({ ...params, ...(key ? { ExclusiveStartKey: key } : {}) }),
      );
      items.push(...(res.Items || []));
      key = res.LastEvaluatedKey;
      pages += 1;
    } while (key && pages < cap);
    return items;
  }

  async function getAggregates() {
    try {
      const items = await queryAll({
        TableName: tableName,
        KeyConditionExpression: '#pk = :pk',
        ExpressionAttributeNames: { '#pk': 'pk' },
        ExpressionAttributeValues: { ':pk': PK.AGG },
      });
      noteSuccess();
      return items.map((item) => ({
        track: item.track,
        version: item.version,
        hits: Number(item.hits || 0),
        errors: Number(item.errors || 0),
        latencySum: Number(item.latencySum || 0),
        lastSeen: item.lastSeen || null,
      }));
    } catch (err) {
      noteError('read', err);
      return [];
    }
  }

  async function getSeries(minutes = 15) {
    const to = currentMinute();
    const from = to - (minutes - 1);
    try {
      const items = await queryAll({
        TableName: tableName,
        KeyConditionExpression: '#pk = :pk AND #sk BETWEEN :from AND :to',
        ExpressionAttributeNames: { '#pk': 'pk', '#sk': 'sk' },
        ExpressionAttributeValues: {
          ':pk': PK.TS,
          ':from': `${pad(from, MINUTE_KEY_WIDTH)}#`,
          ':to': `${pad(to, MINUTE_KEY_WIDTH)}#~`,
        },
      });
      noteSuccess();
      return buildSeries(minutes, items);
    } catch (err) {
      noteError('read', err);
      return buildSeries(minutes, []);
    }
  }

  async function getRecent(limit = 40) {
    if (recordMode !== 'full') return [];
    try {
      const res = await doc.send(
        new QueryCommand({
          TableName: tableName,
          KeyConditionExpression: '#pk = :pk',
          ExpressionAttributeNames: { '#pk': 'pk' },
          ExpressionAttributeValues: { ':pk': PK.HIT },
          ScanIndexForward: false,
          Limit: Math.min(Number(limit) || 40, 100),
        }),
      );
      noteSuccess();
      return (res.Items || []).map((item) => ({
        at: item.at,
        track: item.track,
        version: item.version,
        taskId: item.taskId,
        latencyMs: Number(item.latencyMs || 0),
        status: Number(item.status || 200),
        path: item.path || '/api/hit',
      }));
    } catch (err) {
      noteError('read', err);
      return [];
    }
  }

  async function getChaos() {
    try {
      const items = await queryAll({
        TableName: tableName,
        KeyConditionExpression: '#pk = :pk',
        ExpressionAttributeNames: { '#pk': 'pk' },
        ExpressionAttributeValues: { ':pk': PK.CHAOS },
      });
      const next = emptyChaosState();
      for (const item of items) {
        if (TRACKS.includes(item.sk)) next[item.sk] = normaliseChaos(item);
      }
      chaosCache = next;
      noteSuccess();
      return next;
    } catch (err) {
      noteError('read', err);
      return chaosCache;
    }
  }

  function getChaosLocal() {
    return chaosCache;
  }

  async function setChaos(track, patch) {
    if (!TRACKS.includes(track)) throw new Error(`unknown track: ${track}`);
    const merged = normaliseChaos({
      ...chaosCache[track],
      ...patch,
      updatedAt: new Date().toISOString(),
    });
    chaosCache = { ...chaosCache, [track]: merged };
    await doc.send(
      new PutCommand({
        TableName: tableName,
        Item: { pk: PK.CHAOS, sk: track, ...merged },
      }),
    );
    return merged;
  }

  async function clearChaos() {
    chaosCache = emptyChaosState();
    await Promise.all(
      TRACKS.map((track) =>
        doc.send(
          new PutCommand({
            TableName: tableName,
            Item: { pk: PK.CHAOS, sk: track, ...normaliseChaos({}) },
          }),
        ),
      ),
    );
    return chaosCache;
  }

  async function deletePartition(pk) {
    let key;
    let removed = 0;
    let pages = 0;
    do {
      const res = await doc.send(
        new QueryCommand({
          TableName: tableName,
          KeyConditionExpression: '#pk = :pk',
          ExpressionAttributeNames: { '#pk': 'pk' },
          ExpressionAttributeValues: { ':pk': pk },
          ProjectionExpression: 'pk, sk',
          ...(key ? { ExclusiveStartKey: key } : {}),
        }),
      );
      const items = res.Items || [];
      for (let i = 0; i < items.length; i += 25) {
        const chunk = items.slice(i, i + 25);
        await doc.send(
          new BatchWriteCommand({
            RequestItems: {
              [tableName]: chunk.map((item) => ({
                DeleteRequest: { Key: { pk: item.pk, sk: item.sk } },
              })),
            },
          }),
        );
        removed += chunk.length;
      }
      key = res.LastEvaluatedKey;
      pages += 1;
    } while (key && pages < 40);
    return removed;
  }

  async function reset() {
    try {
      const counts = {};
      for (const pk of [PK.AGG, PK.TS, PK.HIT]) {
        counts[pk] = await deletePartition(pk);
      }
      noteSuccess();
      return { cleared: true, counts };
    } catch (err) {
      noteError('write', err);
      throw err;
    }
  }

  async function init() {
    await ensureLocalTable();
    await getChaos();
    chaosTimer = setInterval(() => {
      getChaos().catch(() => {});
    }, chaosPollMs);
    if (chaosTimer.unref) chaosTimer.unref();
    return { kind: 'dynamodb', table: tableName };
  }

  function stop() {
    if (chaosTimer) clearInterval(chaosTimer);
    chaosTimer = null;
  }

  return {
    kind: 'dynamodb',
    table: tableName,
    init,
    health: () => ({
      kind: 'dynamodb',
      table: tableName,
      degraded: state.degraded,
      lastError: state.lastError,
      lastErrorAt: state.lastErrorAt,
      writeErrors: state.writeErrors,
      readErrors: state.readErrors,
    }),
    recordHit,
    getAggregates,
    getSeries,
    getRecent,
    getChaos,
    getChaosLocal,
    setChaos,
    clearChaos,
    reset,
    stop,
  };
}

module.exports = { createDynamoStore };
