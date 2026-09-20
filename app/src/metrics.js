'use strict';

const MAX_LATENCY_SAMPLES = 100;

/**
 * Emits CloudWatch Embedded Metric Format (EMF) log lines. CloudWatch Logs
 * extracts them into real metrics with no extra IAM permission and no agent, so
 * the canary gets per-track RequestCount / ErrorCount / LatencyMs for free.
 *
 * Also keeps process counters for the plain-text /metrics endpoint.
 */
function createMetrics({ config }) {
  const lifetime = { requests: 0, errors: 0, latencySum: 0, maxLatencyMs: 0 };
  let buffer = { requests: 0, errors: 0, latency: [] };
  let timer = null;

  function record({ latencyMs = 0, error = false } = {}) {
    lifetime.requests += 1;
    lifetime.latencySum += latencyMs;
    lifetime.maxLatencyMs = Math.max(lifetime.maxLatencyMs, latencyMs);
    if (error) lifetime.errors += 1;

    buffer.requests += 1;
    if (error) buffer.errors += 1;
    if (buffer.latency.length < MAX_LATENCY_SAMPLES) buffer.latency.push(Math.round(latencyMs));
  }

  function flush() {
    if (!config.emfEnabled) return null;
    if (buffer.requests === 0) return null;
    const payload = {
      _aws: {
        Timestamp: Date.now(),
        CloudWatchMetrics: [
          {
            Namespace: config.metricsNamespace,
            Dimensions: [['Track', 'Version'], ['Track']],
            Metrics: [
              { Name: 'RequestCount', Unit: 'Count' },
              { Name: 'ErrorCount', Unit: 'Count' },
              { Name: 'LatencyMs', Unit: 'Milliseconds' },
            ],
          },
        ],
      },
      Track: config.track,
      Version: config.version,
      RequestCount: buffer.requests,
      ErrorCount: buffer.errors,
      LatencyMs: buffer.latency.length ? buffer.latency : [0],
    };
    process.stdout.write(`${JSON.stringify(payload)}\n`);
    buffer = { requests: 0, errors: 0, latency: [] };
    return payload;
  }

  function start() {
    if (!config.emfEnabled || timer) return;
    timer = setInterval(flush, config.emfFlushMs);
    if (timer.unref) timer.unref();
  }

  function stop() {
    if (timer) clearInterval(timer);
    timer = null;
    flush();
  }

  function prometheus() {
    const avg = lifetime.requests ? lifetime.latencySum / lifetime.requests : 0;
    const labels = `track="${config.track}",version="${config.version}"`;
    return [
      '# HELP canary_requests_total Requests served by this task.',
      '# TYPE canary_requests_total counter',
      `canary_requests_total{${labels}} ${lifetime.requests}`,
      '# HELP canary_errors_total Requests answered with a 5xx by this task.',
      '# TYPE canary_errors_total counter',
      `canary_errors_total{${labels}} ${lifetime.errors}`,
      '# HELP canary_request_latency_ms_avg Average handler latency for this task.',
      '# TYPE canary_request_latency_ms_avg gauge',
      `canary_request_latency_ms_avg{${labels}} ${avg.toFixed(2)}`,
      '# HELP canary_request_latency_ms_max Highest handler latency seen by this task.',
      '# TYPE canary_request_latency_ms_max gauge',
      `canary_request_latency_ms_max{${labels}} ${lifetime.maxLatencyMs}`,
      '# HELP canary_uptime_seconds Task uptime.',
      '# TYPE canary_uptime_seconds gauge',
      `canary_uptime_seconds{${labels}} ${Math.round(process.uptime())}`,
      '',
    ].join('\n');
  }

  return { record, flush, start, stop, prometheus, lifetime };
}

module.exports = { createMetrics };
