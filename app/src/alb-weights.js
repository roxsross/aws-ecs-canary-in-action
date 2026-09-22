'use strict';

// Reads the configured traffic split from the ALB listener, so the dashboard
// can compare intent (weights) against reality (observed hits). Optional:
// needs LISTENER_ARN plus elasticloadbalancing:DescribeRules.
function createWeightsReader({ config }) {
  const enabled = Boolean(
    config.listenerArn && config.stableTargetGroupArn && config.canaryTargetGroupArn,
  );

  let client = null;
  let DescribeRulesCommand = null;
  let cache = {
    source: enabled ? 'pending' : 'not-configured',
    stable: null,
    canary: null,
    stablePercent: null,
    canaryPercent: null,
    fetchedAt: null,
    error: null,
  };
  let fetchedAtMs = 0;
  let inFlight = null;

  function lazyClient() {
    if (client) return client;
    // eslint-disable-next-line global-require
    const sdk = require('@aws-sdk/client-elastic-load-balancing-v2');
    DescribeRulesCommand = sdk.DescribeRulesCommand;
    client = new sdk.ElasticLoadBalancingV2Client({ region: config.region, maxAttempts: 2 });
    return client;
  }

  async function refresh() {
    const elb = lazyClient();
    // ECS's native canary/blue-green strategy rewrites the weighted
    // ForwardConfig on the production listener *rule* (a non-default rule
    // with its own priority), not on the listener's default action — the
    // default action stays a plain 100%-to-one-target-group forward the
    // whole time. When productionListenerRuleArn is set, look that rule up
    // directly instead of scanning for IsDefault.
    const res = config.productionListenerRuleArn
      ? await elb.send(new DescribeRulesCommand({ RuleArns: [config.productionListenerRuleArn] }))
      : await elb.send(new DescribeRulesCommand({ ListenerArn: config.listenerArn }));
    const rule = config.productionListenerRuleArn
      ? (res.Rules || [])[0]
      : (res.Rules || []).find((r) => r.IsDefault);
    const forward = rule?.Actions?.find((action) => action.Type === 'forward');
    const groups = forward?.ForwardConfig?.TargetGroups || [];

    let stable = null;
    let canary = null;
    for (const group of groups) {
      if (group.TargetGroupArn === config.stableTargetGroupArn) stable = Number(group.Weight ?? 0);
      if (group.TargetGroupArn === config.canaryTargetGroupArn) canary = Number(group.Weight ?? 0);
    }
    if (stable === null && canary === null) {
      const ruleKind = config.productionListenerRuleArn ? 'production listener rule' : 'default listener rule';
      throw new Error(`${ruleKind} does not forward to the expected target groups`);
    }
    const total = (stable || 0) + (canary || 0);
    cache = {
      source: 'alb',
      stable: stable ?? 0,
      canary: canary ?? 0,
      stablePercent: total ? Number((((stable ?? 0) / total) * 100).toFixed(1)) : 0,
      canaryPercent: total ? Number((((canary ?? 0) / total) * 100).toFixed(1)) : 0,
      fetchedAt: new Date().toISOString(),
      error: null,
    };
    fetchedAtMs = Date.now();
    return cache;
  }

  async function get() {
    if (!enabled) return cache;
    if (Date.now() - fetchedAtMs < config.weightsCacheMs && cache.source === 'alb') return cache;
    if (inFlight) return inFlight;
    inFlight = refresh()
      .catch((err) => {
        cache = { ...cache, source: 'error', error: err.message, fetchedAt: new Date().toISOString() };
        fetchedAtMs = Date.now();
        return cache;
      })
      .finally(() => {
        inFlight = null;
      });
    return inFlight;
  }

  return { enabled, get };
}

module.exports = { createWeightsReader };
