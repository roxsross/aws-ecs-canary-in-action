#!/usr/bin/env node
'use strict';

/**
 * mini-alb — a tiny stand-in for the Application Load Balancer, so the whole
 * canary flow (weighted routing, forced routing, target health, 503 when every
 * target is down) can be rehearsed with `docker compose up`, no AWS account.
 *
 * It mirrors the three listener behaviours the real stack uses:
 *   1. default rule  -> weighted forward to the stable / canary target groups
 *   2. query string  -> ?track=stable|canary pins a single target group
 *   3. http header   -> X-Canary: always|never pins a single target group
 *
 * Control plane (stands in for `aws elbv2 modify-listener`):
 *   GET  /_alb/status
 *   POST /_alb/weights   {"stable": 95, "canary": 5}
 *
 * Node core modules only. No dependencies, no build.
 */

const http = require('node:http');
const { URL } = require('node:url');

const PORT = Number.parseInt(process.env.PORT, 10) || 8080;
const HEALTH_PATH = process.env.HEALTH_PATH || '/api/health';
const HEALTH_INTERVAL_MS = Number.parseInt(process.env.HEALTH_INTERVAL_MS, 10) || 5000;
const HEALTH_TIMEOUT_MS = Number.parseInt(process.env.HEALTH_TIMEOUT_MS, 10) || 2000;
const HEALTHY_THRESHOLD = Number.parseInt(process.env.HEALTHY_THRESHOLD, 10) || 2;
const UNHEALTHY_THRESHOLD = Number.parseInt(process.env.UNHEALTHY_THRESHOLD, 10) || 2;

const targets = {
  stable: {
    name: 'stable',
    url: new URL(process.env.STABLE_URL || 'http://stable:8080'),
    weight: Number.parseInt(process.env.STABLE_WEIGHT, 10) || 100,
    healthy: false,
    passes: 0,
    fails: 0,
    lastCheck: null,
    lastError: null,
    requests: 0,
  },
  canary: {
    name: 'canary',
    url: new URL(process.env.CANARY_URL || 'http://canary:8080'),
    weight: Number.isFinite(Number.parseInt(process.env.CANARY_WEIGHT, 10))
      ? Number.parseInt(process.env.CANARY_WEIGHT, 10)
      : 0,
    healthy: false,
    passes: 0,
    fails: 0,
    lastCheck: null,
    lastError: null,
    requests: 0,
  },
};

function log(entry) {
  process.stdout.write(`${JSON.stringify({ time: new Date().toISOString(), ...entry })}\n`);
}

/* ------------------------------------------------------------ health checking */

function checkTarget(target) {
  return new Promise((resolve) => {
    const req = http.request(
      {
        hostname: target.url.hostname,
        port: target.url.port || 80,
        path: HEALTH_PATH,
        method: 'GET',
        timeout: HEALTH_TIMEOUT_MS,
      },
      (res) => {
        res.resume();
        resolve(res.statusCode === 200 ? null : `status ${res.statusCode}`);
      },
    );
    req.on('timeout', () => {
      req.destroy();
      resolve('timeout');
    });
    req.on('error', (err) => resolve(err.code || err.message));
    req.end();
  });
}

async function runHealthChecks() {
  await Promise.all(
    Object.values(targets).map(async (target) => {
      const failure = await checkTarget(target);
      target.lastCheck = new Date().toISOString();
      if (failure) {
        target.fails += 1;
        target.passes = 0;
        target.lastError = failure;
        if (target.healthy && target.fails >= UNHEALTHY_THRESHOLD) {
          target.healthy = false;
          log({ level: 'warn', msg: 'target unhealthy', target: target.name, reason: failure });
        }
      } else {
        target.passes += 1;
        target.fails = 0;
        target.lastError = null;
        if (!target.healthy && target.passes >= HEALTHY_THRESHOLD) {
          target.healthy = true;
          log({ level: 'info', msg: 'target healthy', target: target.name });
        }
      }
    }),
  );
}

/* ---------------------------------------------------------------- routing */

/** Mirrors the listener rules: forced routing first, then weighted default. */
function pickTarget(req, requestUrl) {
  const forcedQuery = (requestUrl.searchParams.get('track') || '').toLowerCase();
  const canaryHeader = (req.headers['x-canary'] || '').toLowerCase();

  let forced = null;
  if (forcedQuery === 'stable' || forcedQuery === 'canary') forced = forcedQuery;
  else if (canaryHeader === 'always') forced = 'canary';
  else if (canaryHeader === 'never') forced = 'stable';

  if (forced) {
    return { target: targets[forced], rule: forcedQuery ? 'query-string' : 'http-header' };
  }

  const pool = Object.values(targets).filter((t) => t.healthy && t.weight > 0);
  const total = pool.reduce((sum, t) => sum + t.weight, 0);
  if (total <= 0) return { target: null, rule: 'default-weighted' };

  let roll = Math.random() * total;
  for (const target of pool) {
    roll -= target.weight;
    if (roll <= 0) return { target, rule: 'default-weighted' };
  }
  return { target: pool[pool.length - 1], rule: 'default-weighted' };
}

function proxy(req, res, target, requestUrl, rule) {
  target.requests += 1;
  const headers = { ...req.headers };
  delete headers.host;
  headers['x-forwarded-for'] = [req.headers['x-forwarded-for'], req.socket.remoteAddress]
    .filter(Boolean)
    .join(', ');
  headers['x-forwarded-proto'] = 'http';
  headers['x-forwarded-port'] = String(PORT);
  headers.host = `${target.url.hostname}:${target.url.port || 80}`;

  const upstream = http.request(
    {
      hostname: target.url.hostname,
      port: target.url.port || 80,
      path: `${requestUrl.pathname}${requestUrl.search}`,
      method: req.method,
      headers,
      timeout: 30_000,
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode || 502, {
        ...upstreamRes.headers,
        'x-alb-target': target.name,
        'x-alb-rule': rule,
      });
      upstreamRes.pipe(res);
    },
  );

  upstream.on('timeout', () => {
    upstream.destroy();
    if (!res.headersSent) {
      res.writeHead(504, { 'Content-Type': 'application/json', 'x-alb-target': target.name });
      res.end(JSON.stringify({ ok: false, error: 'gateway timeout', target: target.name }));
    }
  });

  upstream.on('error', (err) => {
    log({ level: 'error', msg: 'upstream error', target: target.name, error: err.message });
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'application/json', 'x-alb-target': target.name });
      res.end(JSON.stringify({ ok: false, error: 'bad gateway', detail: err.message }));
    }
  });

  req.pipe(upstream);
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
  });
  res.end(payload);
}

function status() {
  const total = Object.values(targets).reduce((sum, t) => sum + t.weight, 0) || 1;
  return {
    listener: { port: PORT },
    weights: {
      stable: targets.stable.weight,
      canary: targets.canary.weight,
      stablePercent: Number(((targets.stable.weight / total) * 100).toFixed(1)),
      canaryPercent: Number(((targets.canary.weight / total) * 100).toFixed(1)),
    },
    targets: Object.values(targets).map((t) => ({
      name: t.name,
      url: t.url.origin,
      weight: t.weight,
      healthy: t.healthy,
      requests: t.requests,
      lastCheck: t.lastCheck,
      lastError: t.lastError,
    })),
  };
}

function readBody(req, limitBytes = 4096) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > limitBytes) {
        reject(new Error('payload too large'));
        req.destroy();
      }
    });
    req.on('end', () => resolve(raw));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const requestUrl = new URL(req.url, `http://localhost:${PORT}`);

  // ---- control plane -------------------------------------------------------
  if (requestUrl.pathname === '/_alb/status' && req.method === 'GET') {
    return sendJson(res, 200, status());
  }

  if (requestUrl.pathname === '/_alb/health' && req.method === 'GET') {
    const anyHealthy = Object.values(targets).some((t) => t.healthy);
    return sendJson(res, anyHealthy ? 200 : 503, { ok: anyHealthy, targets: status().targets });
  }

  if (requestUrl.pathname === '/_alb/weights' && req.method === 'POST') {
    try {
      const raw = await readBody(req);
      const body = raw ? JSON.parse(raw) : {};
      for (const name of ['stable', 'canary']) {
        if (body[name] !== undefined) {
          const weight = Number.parseInt(body[name], 10);
          if (!Number.isFinite(weight) || weight < 0 || weight > 999) {
            return sendJson(res, 400, { ok: false, error: `${name} weight must be 0..999` });
          }
          targets[name].weight = weight;
        }
      }
      log({ level: 'info', msg: 'weights updated', weights: status().weights });
      return sendJson(res, 200, { ok: true, ...status() });
    } catch (err) {
      return sendJson(res, 400, { ok: false, error: err.message });
    }
  }

  // ---- data plane ----------------------------------------------------------
  const { target, rule } = pickTarget(req, requestUrl);
  if (!target) {
    return sendJson(res, 503, {
      ok: false,
      error: 'no healthy targets for the requested weights',
      hint: 'check /_alb/status; a weight of 0 or an unhealthy target group takes it out of rotation',
      targets: status().targets,
    });
  }
  if (!target.healthy) {
    return sendJson(res, 503, {
      ok: false,
      error: `target group ${target.name} has no healthy targets`,
      rule,
    });
  }
  return proxy(req, res, target, requestUrl, rule);
});

server.listen(PORT, '0.0.0.0', () => {
  log({
    level: 'info',
    msg: 'mini-alb listening',
    port: PORT,
    stable: targets.stable.url.origin,
    canary: targets.canary.url.origin,
    weights: status().weights,
  });
});

runHealthChecks();
setInterval(runHealthChecks, HEALTH_INTERVAL_MS);

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    log({ level: 'info', msg: 'shutting down', signal });
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000).unref();
  });
}
