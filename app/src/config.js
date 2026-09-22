'use strict';

const os = require('node:os');

const PALETTE = {
  stable: {
    label: 'STABLE',
    accent: '#22d3ee',
    accentDim: 'rgba(34, 211, 238, 0.16)',
    glow: 'rgba(34, 211, 238, 0.45)',
  },
  canary: {
    label: 'CANARY',
    accent: '#f472b6',
    accentDim: 'rgba(244, 114, 182, 0.16)',
    glow: 'rgba(244, 114, 182, 0.45)',
  },
};

function num(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function bool(value, fallback = false) {
  if (value === undefined || value === null || value === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
}

const track = (process.env.TRACK || 'stable').toLowerCase() === 'canary' ? 'canary' : 'stable';

const config = {
  project: process.env.PROJECT_NAME || 'canary-lab',
  track,
  version: process.env.APP_VERSION || '1.0.0',
  palette: PALETTE[track],
  hostname: os.hostname(),
  nodeVersion: process.version,
  startedAt: new Date().toISOString(),

  port: num(process.env.PORT, 8080),
  region: process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || 'us-east-1',
  logHealthChecks: bool(process.env.LOG_HEALTH_CHECKS, false),

  tableName: process.env.TABLE_NAME || '',
  dynamoEndpoint: process.env.DYNAMO_ENDPOINT || '',
  // full = aggregates + timeseries + hit feed | agg = counters only | off = memory only
  recordMode: (process.env.RECORD_MODE || 'full').toLowerCase(),
  hitFeedTtlSeconds: num(process.env.HIT_FEED_TTL_SECONDS, 30 * 60),
  seriesTtlSeconds: num(process.env.SERIES_TTL_SECONDS, 3 * 60 * 60),
  chaosPollMs: num(process.env.CHAOS_POLL_MS, 3000),

  // Live ALB weights, needs elasticloadbalancing:DescribeRules.
  listenerArn: process.env.LISTENER_ARN || '',
  stableTargetGroupArn: process.env.STABLE_TARGET_GROUP_ARN || '',
  canaryTargetGroupArn: process.env.CANARY_TARGET_GROUP_ARN || '',
  // Optional: ECS's native canary/blue-green strategy puts the weighted
  // ForwardConfig on the production listener *rule* it rewrites during a
  // rollout, not on the listener's default action. When set, alb-weights.js
  // reads this rule instead of the default one. Unset (e.g. local/mini-alb,
  // which has no such rule) falls back to the default action, unchanged.
  productionListenerRuleArn: process.env.PRODUCTION_LISTENER_RULE_ARN || '',
  weightsCacheMs: num(process.env.WEIGHTS_CACHE_MS, 8000),

  metricsNamespace: process.env.METRICS_NAMESPACE || 'CanaryLab',
  emfEnabled: bool(process.env.EMF_ENABLED, true),
  emfFlushMs: num(process.env.EMF_FLUSH_MS, 10000),

  // Baseline failure/latency injected via env, for shipping a deliberately bad image.
  baseFailRate: num(process.env.FAIL_RATE, 0),
  baseLatencyMs: num(process.env.LATENCY_MS, 0),
  baseUnhealthy: bool(process.env.UNHEALTHY, false),

  // When set, /api/chaos and /api/reset require the X-Admin-Token header.
  adminToken: process.env.ADMIN_TOKEN || '',

  shutdownGraceMs: num(process.env.SHUTDOWN_GRACE_MS, 12000),
};

config.isCanary = config.track === 'canary';
config.persistence = config.tableName && config.recordMode !== 'off' ? 'dynamodb' : 'memory';

module.exports = { config, PALETTE, num, bool };
