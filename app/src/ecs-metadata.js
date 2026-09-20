'use strict';

const os = require('node:os');

/**
 * Reads the ECS task metadata endpoint (v4) so the dashboard can show which
 * Fargate task answered each request. Falls back to the hostname when running
 * locally or in plain Docker.
 */
const identity = {
  taskId: os.hostname(),
  taskArn: null,
  cluster: null,
  family: null,
  revision: null,
  availabilityZone: null,
  cpu: null,
  memory: null,
  launchType: null,
  source: 'hostname',
};

async function fetchJson(url, timeoutMs = 2000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) throw new Error(`metadata endpoint returned ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

function shortTaskId(taskArn) {
  if (!taskArn) return null;
  const parts = String(taskArn).split('/');
  return parts[parts.length - 1] || null;
}

/** Resolves once (best effort). Retries a few times because the endpoint can lag at boot. */
async function loadIdentity({ attempts = 3, delayMs = 1500 } = {}) {
  const base = process.env.ECS_CONTAINER_METADATA_URI_V4 || process.env.ECS_CONTAINER_METADATA_URI;
  if (!base) return identity;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const task = await fetchJson(`${base}/task`);
      identity.taskArn = task.TaskARN || null;
      identity.taskId = shortTaskId(task.TaskARN) || identity.taskId;
      identity.cluster = task.Cluster ? String(task.Cluster).split('/').pop() : null;
      identity.family = task.Family || null;
      identity.revision = task.Revision || null;
      identity.availabilityZone = task.AvailabilityZone || null;
      identity.cpu = task.Limits?.CPU ?? null;
      identity.memory = task.Limits?.Memory ?? null;
      identity.launchType = task.LaunchType || null;
      identity.source = 'ecs-metadata-v4';
      return identity;
    } catch (err) {
      if (attempt === attempts) {
        console.warn(
          JSON.stringify({
            level: 'warn',
            msg: 'could not read ECS task metadata, falling back to hostname',
            error: err.message,
          }),
        );
      } else {
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      }
    }
  }
  return identity;
}

/** Short, display friendly task id (last 8 chars). */
function displayTaskId() {
  const id = identity.taskId || 'unknown';
  return id.length > 10 ? id.slice(-10) : id;
}

module.exports = { identity, loadIdentity, displayTaskId };
