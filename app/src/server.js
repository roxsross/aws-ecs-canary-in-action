'use strict';

const path = require('node:path');
const express = require('express');

const { config, PALETTE } = require('./config');
const { identity, loadIdentity } = require('./ecs-metadata');
const { createStore } = require('./store');
const { createChaosEngine } = require('./chaos');
const { createMetrics } = require('./metrics');
const { createWeightsReader } = require('./alb-weights');
const { TRACKS } = require('./store/util');

const store = createStore(config);
const chaos = createChaosEngine({ config, store });
const metrics = createMetrics({ config });
const weights = createWeightsReader({ config });

const runtime = { draining: false, seq: 0 };

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', true);
app.use(express.json({ limit: '8kb' }));

function log(entry) {
  process.stdout.write(`${JSON.stringify({ time: new Date().toISOString(), ...entry })}\n`);
}

/** Every response carries the identity of the task that produced it. */
app.use((req, res, next) => {
  res.set('X-Track', config.track);
  res.set('X-Version', config.version);
  res.set('X-Task-Id', identity.taskId);
  res.set('X-Served-By', `${config.track}/${config.version}`);
  next();
});

function requireAdmin(req, res, next) {
  if (!config.adminToken) return next();
  const token = req.get('x-admin-token') || req.query.token;
  if (token && token === config.adminToken) return next();
  return res.status(401).json({ ok: false, error: 'missing or invalid X-Admin-Token' });
}

function identitySnapshot() {
  return {
    track: config.track,
    version: config.version,
    label: config.palette.label,
    accent: config.palette.accent,
    taskId: identity.taskId,
    taskArn: identity.taskArn,
    cluster: identity.cluster,
    family: identity.family,
    revision: identity.revision,
    availabilityZone: identity.availabilityZone,
    cpu: identity.cpu,
    memory: identity.memory,
    launchType: identity.launchType,
    metadataSource: identity.source,
    hostname: config.hostname,
    region: config.region,
    project: config.project,
    nodeVersion: config.nodeVersion,
    startedAt: config.startedAt,
    uptimeSeconds: Math.round(process.uptime()),
  };
}

// ---------------------------------------------------------------- health check
app.get('/api/health', (req, res) => {
  const unhealthy = chaos.isUnhealthy();
  const status = runtime.draining || unhealthy ? 503 : 200;
  if (config.logHealthChecks) {
    log({ level: 'debug', msg: 'health check', status, track: config.track });
  }
  res.status(status).json({
    ok: status === 200,
    status: status === 200 ? 'healthy' : 'unhealthy',
    reason: runtime.draining ? 'draining' : unhealthy ? 'chaos:unhealthy' : null,
    track: config.track,
    version: config.version,
    taskId: identity.taskId,
    uptimeSeconds: Math.round(process.uptime()),
  });
});

// ------------------------------------------------------------------- identity
app.get('/api/whoami', (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json({
    ...identitySnapshot(),
    chaos: chaos.current(),
    persistence: store.health(),
    client: { ip: req.ip, userAgent: req.get('user-agent') || null },
  });
});

/** Bootstrap payload for the dashboard. */
app.get('/api/config', (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json({
    project: config.project,
    region: config.region,
    servedBy: identitySnapshot(),
    palette: PALETTE,
    tracks: TRACKS,
    weightsEnabled: weights.enabled,
    adminTokenRequired: Boolean(config.adminToken),
    persistence: store.health(),
    recordMode: config.recordMode,
  });
});

// ------------------------------------------------------- the traffic endpoint
app.all('/api/hit', async (req, res) => {
  const startedAt = process.hrtime.bigint();
  const injectedLatencyMs = await chaos.applyLatency();
  const failing = chaos.shouldFail();
  const status = failing ? 500 : 200;
  const latencyMs = Number(Number(process.hrtime.bigint() - startedAt) / 1e6);
  runtime.seq += 1;

  store
    .recordHit({
      track: config.track,
      version: config.version,
      taskId: identity.taskId,
      latencyMs,
      status,
      path: '/api/hit',
    })
    .catch(() => {});
  metrics.record({ latencyMs, error: failing });

  res.set('Cache-Control', 'no-store');
  res.status(status).json({
    ok: !failing,
    error: failing ? 'chaos: injected failure' : null,
    track: config.track,
    version: config.version,
    label: config.palette.label,
    accent: config.palette.accent,
    taskId: identity.taskId,
    availabilityZone: identity.availabilityZone,
    seq: runtime.seq,
    latencyMs: Number(latencyMs.toFixed(2)),
    injectedLatencyMs,
    servedAt: new Date().toISOString(),
  });
});

// ------------------------------------------------------------------ analytics
app.get('/api/stats', async (req, res) => {
  const minutes = Math.min(Math.max(Number.parseInt(req.query.minutes, 10) || 15, 1), 120);
  const recent = Math.min(Math.max(Number.parseInt(req.query.recent, 10) || 40, 0), 100);
  try {
    const [snapshot, albWeights] = await Promise.all([
      store.getSnapshot({ minutes, recent }),
      weights.get(),
    ]);
    res.set('Cache-Control', 'no-store');
    res.json({ ...snapshot, weights: albWeights, servedBy: identitySnapshot() });
  } catch (err) {
    log({ level: 'error', msg: 'stats failed', error: err.message });
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/weights', async (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json(await weights.get());
});

app.post('/api/reset', requireAdmin, async (req, res) => {
  try {
    const result = await store.reset();
    log({ level: 'info', msg: 'counters reset', by: req.ip });
    res.json({ ok: true, ...result });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// ---------------------------------------------------------- fault injection
app.get('/api/chaos', async (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json({ ok: true, chaos: await store.getChaos(), effective: chaos.current() });
});

app.post('/api/chaos', requireAdmin, async (req, res) => {
  const body = req.body || {};
  const track = String(body.track || config.track).toLowerCase();
  if (!TRACKS.includes(track)) {
    return res.status(400).json({ ok: false, error: `track must be one of ${TRACKS.join(', ')}` });
  }
  const patch = {};
  if (body.failRate !== undefined) patch.failRate = Number(body.failRate);
  if (body.latencyMs !== undefined) patch.latencyMs = Number(body.latencyMs);
  if (body.unhealthy !== undefined) patch.unhealthy = Boolean(body.unhealthy);
  if (Object.keys(patch).length === 0) {
    return res
      .status(400)
      .json({ ok: false, error: 'provide at least one of failRate, latencyMs, unhealthy' });
  }
  try {
    const applied = await store.setChaos(track, patch);
    log({ level: 'warn', msg: 'chaos updated', track, patch, by: req.ip });
    return res.json({ ok: true, track, applied });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

app.delete('/api/chaos', requireAdmin, async (req, res) => {
  try {
    const cleared = await store.clearChaos();
    log({ level: 'info', msg: 'chaos cleared', by: req.ip });
    res.json({ ok: true, chaos: cleared });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// -------------------------------------------------------------------- metrics
app.get('/metrics', (req, res) => {
  res.set('Content-Type', 'text/plain; version=0.0.4');
  res.send(metrics.prometheus());
});

// ------------------------------------------------------------------ dashboard
app.use(
  express.static(path.join(__dirname, '..', 'public'), {
    index: 'index.html',
    maxAge: '5m',
    setHeaders: (res, filePath) => {
      if (filePath.endsWith('index.html')) res.set('Cache-Control', 'no-store');
    },
  }),
);

app.use((req, res) => {
  res.status(404).json({ ok: false, error: 'not found', path: req.originalUrl });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  log({ level: 'error', msg: 'unhandled error', error: err.message, stack: err.stack });
  metrics.record({ latencyMs: 0, error: true });
  res.status(500).json({ ok: false, error: 'internal error' });
});

async function start() {
  await store.init();
  metrics.start();
  loadIdentity().catch(() => {});

  const server = app.listen(config.port, '0.0.0.0', () => {
    log({
      level: 'info',
      msg: 'canary demo app listening',
      port: config.port,
      track: config.track,
      version: config.version,
      persistence: store.kind,
      table: config.tableName || null,
      region: config.region,
      weightsEnabled: weights.enabled,
      adminTokenRequired: Boolean(config.adminToken),
    });
  });
  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 70_000;

  let shuttingDown = false;
  const shutdown = (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    runtime.draining = true;
    log({ level: 'info', msg: 'draining before shutdown', signal, graceMs: config.shutdownGraceMs });
    // Keep answering real traffic while the load balancer drains this target.
    setTimeout(() => {
      metrics.stop();
      store.stop();
      server.close(() => {
        log({ level: 'info', msg: 'shutdown complete', signal });
        process.exit(0);
      });
      setTimeout(() => process.exit(0), 5000).unref();
    }, config.shutdownGraceMs).unref();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('unhandledRejection', (reason) => {
    log({ level: 'error', msg: 'unhandled rejection', error: String(reason) });
  });

  return server;
}

if (require.main === module) {
  start().catch((err) => {
    log({ level: 'fatal', msg: 'failed to start', error: err.message, stack: err.stack });
    process.exit(1);
  });
}

module.exports = { app, start, store, config };
