'use strict';

// Combines two fault sources with max(): a deliberately broken image
// (FAIL_RATE / LATENCY_MS env vars) or a runtime override from the dashboard
// (state stored in DynamoDB, polled by every task).
function createChaosEngine({ config, store }) {
  function stateFor(track) {
    const remote = store.getChaosLocal()?.[track] || {};
    const isOwnTrack = track === config.track;
    return {
      track,
      failRate: Math.max(isOwnTrack ? config.baseFailRate : 0, Number(remote.failRate || 0)),
      latencyMs: Math.max(isOwnTrack ? config.baseLatencyMs : 0, Number(remote.latencyMs || 0)),
      unhealthy: (isOwnTrack && config.baseUnhealthy) || Boolean(remote.unhealthy),
      updatedAt: remote.updatedAt || null,
    };
  }

  function current() {
    return stateFor(config.track);
  }

  function shouldFail() {
    const { failRate } = current();
    if (failRate <= 0) return false;
    return Math.random() * 100 < failRate;
  }

  function extraLatencyMs() {
    return current().latencyMs;
  }

  async function applyLatency() {
    const ms = extraLatencyMs();
    if (ms <= 0) return 0;
    await new Promise((resolve) => setTimeout(resolve, ms));
    return ms;
  }

  function isUnhealthy() {
    return current().unhealthy;
  }

  function isActive() {
    const state = current();
    return state.failRate > 0 || state.latencyMs > 0 || state.unhealthy;
  }

  return { current, stateFor, shouldFail, extraLatencyMs, applyLatency, isUnhealthy, isActive };
}

module.exports = { createChaosEngine };
