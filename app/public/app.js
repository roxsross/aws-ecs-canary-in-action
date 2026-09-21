/* ===========================================================================
   ECS Canary in Action — dashboard client
   Sends its own probes to /api/hit, so the split you see is real traffic
   going through the ALB weighted target groups, not a simulation.
   =========================================================================== */
'use strict';

const SVG_NS = 'http://www.w3.org/2000/svg';
const PROBE_BUFFER = 240;
const BARCODE_TICKS = 120;
const MAX_INFLIGHT = 8;
const STATS_INTERVAL_MS = 2500;
const WINDOW_MINUTES = 15;

const el = (name) => document.querySelector(`[data-bind="${name}"]`);
const els = {};
[
  'project',
  'region',
  'persistence',
  'cluster',
  'servedByChip',
  'servedByLabel',
  'servedByVersion',
  'servedByTask',
  'probeToggleLabel',
  'phase',
  'albBar',
  'albStable',
  'albCanary',
  'albNote',
  'observedBar',
  'observedStable',
  'observedCanary',
  'observedNote',
  'globalBar',
  'globalStable',
  'globalCanary',
  'globalNote',
  'barcode',
  'card-stable',
  'card-canary',
  'stableVersion',
  'canaryVersion',
  'stableHits',
  'canaryHits',
  'stableErrors',
  'canaryErrors',
  'stableErrorRate',
  'canaryErrorRate',
  'stableLatency',
  'canaryLatency',
  'stableSpark',
  'canarySpark',
  'stableTasks',
  'canaryTasks',
  'stableForceLink',
  'canaryForceLink',
  'chart',
  'chartGrid',
  'chartBars',
  'chartSummary',
  'feed',
  'feedSource',
  'rateOut',
  'failOut',
  'latencyOut',
  'chaosBlock',
  'chaosTag',
  'footerMeta',
  'toasts',
].forEach((name) => {
  els[name] = el(name);
});

const inputs = {
  rate: document.getElementById('rate'),
  failRate: document.getElementById('failRate'),
  latency: document.getElementById('latency'),
  unhealthy: document.getElementById('unhealthy'),
};

const state = {
  config: null,
  stats: null,
  probes: [],
  paused: false,
  inFlight: 0,
  settings: { rate: 4, pin: 'auto', chaosTrack: 'canary' },
  adminToken: sessionStorage.getItem('canaryAdminToken') || '',
  warned: { degraded: false, statsError: false },
  statsFailures: 0,
};

/* ------------------------------------------------------------------ helpers */

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
const pct = (value) => `${Number(value || 0).toFixed(value >= 10 || value === 0 ? 0 : 1)}%`;
const nf = new Intl.NumberFormat('es-ES');

function timeLabel(iso) {
  const date = iso ? new Date(iso) : new Date();
  return date.toLocaleTimeString('es-ES', { hour12: false });
}

function shortTask(taskId) {
  if (!taskId || taskId === '?') return '—';
  return taskId.length > 12 ? `…${taskId.slice(-10)}` : taskId;
}

function toast(message, kind = 'info', ttl = 6000) {
  if (!els.toasts) return;
  const node = document.createElement('div');
  node.className = 'toast';
  node.dataset.kind = kind;
  node.textContent = message;
  els.toasts.append(node);
  setTimeout(() => node.remove(), ttl);
}

function adminHeaders(extra = {}) {
  const headers = { ...extra };
  if (state.config?.adminTokenRequired) {
    if (!state.adminToken) {
      // eslint-disable-next-line no-alert
      const token = window.prompt('Este entorno exige un token de administración (X-Admin-Token):');
      if (token) {
        state.adminToken = token;
        sessionStorage.setItem('canaryAdminToken', token);
      }
    }
    if (state.adminToken) headers['X-Admin-Token'] = state.adminToken;
  }
  return headers;
}

async function api(path, init = {}) {
  const res = await fetch(path, { cache: 'no-store', ...init });
  const text = await res.text();
  let body = text;
  try {
    body = JSON.parse(text);
  } catch {
    /* not json */
  }
  if (!res.ok) {
    const message = typeof body === 'object' && body?.error ? body.error : `HTTP ${res.status}`;
    throw new Error(message);
  }
  return body;
}

/* -------------------------------------------------------------- probe engine */

let probeTimer = null;
let renderQueued = false;

function queueLiveRender() {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => {
    renderQueued = false;
    renderObserved();
    renderBarcode();
    if (!state.stats?.recent?.length) renderFeed();
  });
}

function pushProbe(entry) {
  state.probes.push(entry);
  if (state.probes.length > PROBE_BUFFER) state.probes.shift();
}

async function probe() {
  const { pin } = state.settings;
  const url = pin === 'auto' ? '/api/hit' : `/api/hit?track=${pin}`;
  const startedAt = performance.now();
  state.inFlight += 1;
  try {
    const res = await fetch(url, { cache: 'no-store', headers: { Accept: 'application/json' } });
    const rtt = performance.now() - startedAt;
    let body = null;
    try {
      body = await res.json();
    } catch {
      /* 503 from the ALB has no json body */
    }
    pushProbe({
      at: Date.now(),
      track: (res.headers.get('x-track') || body?.track || 'unknown').toLowerCase(),
      version: res.headers.get('x-version') || body?.version || '?',
      taskId: res.headers.get('x-task-id') || body?.taskId || '?',
      status: res.status,
      rtt,
      serverLatencyMs: typeof body?.latencyMs === 'number' ? body.latencyMs : null,
      error: res.status >= 400,
      pinned: pin !== 'auto',
    });
  } catch (err) {
    pushProbe({
      at: Date.now(),
      track: 'unknown',
      version: '?',
      taskId: '?',
      status: 0,
      rtt: performance.now() - startedAt,
      serverLatencyMs: null,
      error: true,
      pinned: pin !== 'auto',
      message: err.message,
    });
  } finally {
    state.inFlight -= 1;
    queueLiveRender();
  }
}

function scheduleProbes() {
  if (probeTimer) clearInterval(probeTimer);
  probeTimer = null;
  const { rate } = state.settings;
  if (state.paused || rate <= 0) return;
  const interval = Math.max(40, Math.round(1000 / rate));
  probeTimer = setInterval(() => {
    if (state.inFlight < MAX_INFLIGHT) probe();
  }, interval);
}

/* ----------------------------------------------------------------- renderers */

function setBar(barEl, stablePercent, canaryPercent) {
  if (!barEl) return;
  const segs = barEl.querySelectorAll('.bar-seg');
  const stable = clamp(Number(stablePercent) || 0, 0, 100);
  const canary = clamp(Number(canaryPercent) || 0, 0, 100);
  if (segs[0]) {
    segs[0].style.width = `${stable}%`;
    segs[0].dataset.empty = stable < 8 ? 'true' : 'false';
  }
  if (segs[1]) {
    segs[1].style.width = `${canary}%`;
    segs[1].dataset.empty = canary < 8 ? 'true' : 'false';
  }
}

function renderIdentity() {
  const config = state.config;
  if (!config) return;
  const served = config.servedBy || {};
  els.project.textContent = config.project || 'canary-lab';
  els.region.textContent = config.region || '—';
  els.cluster.textContent = served.cluster ? `cluster ${served.cluster}` : 'sin cluster ECS';

  const persistence = config.persistence || {};
  els.persistence.textContent =
    persistence.kind === 'dynamodb'
      ? persistence.degraded
        ? 'dynamodb (degradado)'
        : `dynamodb ${persistence.table || ''}`.trim()
      : 'memoria local';

  els.servedByChip.dataset.track = served.track || 'stable';
  els.servedByLabel.textContent = served.label || (served.track || 'stable').toUpperCase();
  els.servedByVersion.textContent = served.version || '—';
  els.servedByTask.textContent = `task ${shortTask(served.taskId)}${
    served.availabilityZone ? ` · ${served.availabilityZone}` : ''
  }`;

  els.footerMeta.textContent = [
    `node ${served.nodeVersion || '—'}`,
    `task ${shortTask(served.taskId)}`,
    served.family ? `${served.family}:${served.revision}` : null,
    `registro ${config.recordMode}`,
  ]
    .filter(Boolean)
    .join(' · ');

  if (persistence.degraded && !state.warned.degraded) {
    state.warned.degraded = true;
    toast(
      'DynamoDB no responde: el panel usa contadores locales de cada tarea. Revisa el IAM role o el nombre de la tabla.',
      'error',
      12000,
    );
  }
}

function renderObserved() {
  const sample = state.probes.filter((p) => !p.pinned);
  const counts = { stable: 0, canary: 0, unknown: 0 };
  for (const p of sample) counts[p.track] = (counts[p.track] || 0) + 1;
  const known = counts.stable + counts.canary;
  const stablePercent = known ? (counts.stable / known) * 100 : 0;
  const canaryPercent = known ? (counts.canary / known) * 100 : 0;

  els.observedStable.textContent = known ? pct(stablePercent) : '—';
  els.observedCanary.textContent = known ? pct(canaryPercent) : '—';
  setBar(els.observedBar, known ? stablePercent : 100, known ? canaryPercent : 0);

  const errors = sample.filter((p) => p.error).length;
  const avgRtt = sample.length
    ? Math.round(sample.reduce((sum, p) => sum + p.rtt, 0) / sample.length)
    : 0;
  const pinnedCount = state.probes.length - sample.length;
  els.observedNote.textContent = sample.length
    ? [
        `${nf.format(sample.length)} solicitudes de prueba`,
        `${counts.stable} estable / ${counts.canary} canary`,
        errors ? `${errors} con error` : 'sin errores',
        `rtt medio ${avgRtt} ms`,
        pinnedCount ? `${pinnedCount} forzadas excluidas` : null,
      ]
        .filter(Boolean)
        .join(' · ')
    : state.paused || state.settings.rate === 0
      ? 'muestreo en pausa'
      : 'esperando la primera solicitud de prueba…';

  if (counts.unknown > 0) {
    els.observedNote.textContent += ` · ${counts.unknown} sin identificar (5xx del ALB)`;
  }
}

function renderWeights() {
  const weights = state.stats?.weights;
  const observed = () => {
    const sample = state.probes.filter((p) => !p.pinned && p.track !== 'unknown');
    if (!sample.length) return null;
    const canary = sample.filter((p) => p.track === 'canary').length;
    return (canary / sample.length) * 100;
  };

  if (weights && weights.source === 'alb') {
    els.albStable.textContent = pct(weights.stablePercent);
    els.albCanary.textContent = pct(weights.canaryPercent);
    setBar(els.albBar, weights.stablePercent, weights.canaryPercent);
    els.albNote.textContent = `weight stable=${weights.stable} canary=${weights.canary} · leído del listener ${timeLabel(
      weights.fetchedAt,
    )}`;
    renderPhase(weights.canaryPercent, 'alb');
    return;
  }

  const fallback = observed();
  els.albStable.textContent = '—';
  els.albCanary.textContent = '—';
  setBar(els.albBar, fallback === null ? 100 : 100 - fallback, fallback === null ? 0 : fallback);
  els.albNote.textContent =
    weights?.source === 'error'
      ? `no se pudo leer el listener: ${weights.error}`
      : 'sin LISTENER_ARN: mostrando la estimación observada';
  renderPhase(fallback, 'observed');
}

function renderPhase(canaryPercent, source) {
  const suffix = source === 'alb' ? '' : ' (estimado)';
  if (canaryPercent === null || canaryPercent === undefined) {
    els.phase.textContent = 'Esperando tráfico…';
    return;
  }
  const value = pct(canaryPercent);
  let label;
  if (canaryPercent <= 0) label = 'Solo versión estable · sin canary en tráfico';
  else if (canaryPercent <= 10) label = `Canary al ${value} · fase inicial`;
  else if (canaryPercent <= 30) label = `Canary al ${value} · ampliando`;
  else if (canaryPercent < 100) label = `Canary al ${value} · a punto de promover`;
  else label = 'Canary al 100% · lista para promover';
  els.phase.textContent = `${label}${suffix}`;

  document.title =
    canaryPercent > 0
      ? `canary ${value} · ECS Canary in Action`
      : 'ECS Canary in Action · Monitor de tráfico';
}

function renderGlobal() {
  const tracks = state.stats?.tracks;
  const totals = state.stats?.totals;
  if (!tracks || !totals) return;

  els.globalStable.textContent = totals.hits ? pct(tracks.stable.share) : '—';
  els.globalCanary.textContent = totals.hits ? pct(tracks.canary.share) : '—';
  setBar(
    els.globalBar,
    totals.hits ? tracks.stable.share : 100,
    totals.hits ? tracks.canary.share : 0,
  );
  els.globalNote.textContent = totals.hits
    ? `${nf.format(totals.hits)} solicitudes · ${nf.format(totals.errors)} errores (${pct(
        totals.errorRate,
      )}) · ventana acumulada`
    : 'sin solicitudes registradas todavía';
}

function renderCards() {
  const stats = state.stats;
  if (!stats) return;
  const lastProbe = [...state.probes].reverse().find((p) => p.track !== 'unknown');

  for (const track of ['stable', 'canary']) {
    const data = stats.tracks[track];
    const card = els[`card-${track}`];
    const prefix = track === 'stable' ? 'stable' : 'canary';
    const topVersion = data.versions[0];

    els[`${prefix}Version`].textContent = topVersion ? `v${topVersion.version}` : '—';
    els[`${prefix}Hits`].textContent = nf.format(data.hits);
    els[`${prefix}Errors`].textContent = nf.format(data.errors);
    els[`${prefix}ErrorRate`].textContent = pct(data.errorRate);
    els[`${prefix}ErrorRate`].dataset.alert = data.errorRate > 1 ? 'true' : 'false';
    els[`${prefix}Errors`].dataset.alert = data.errors > 0 ? 'true' : 'false';
    els[`${prefix}Latency`].textContent = `${nf.format(data.avgLatencyMs)} ms`;
    els[`${prefix}Latency`].dataset.alert = data.avgLatencyMs > 500 ? 'true' : 'false';

    const tasks = new Set(
      (stats.recent || []).filter((hit) => hit.track === track).map((hit) => hit.taskId),
    );
    for (const p of state.probes) if (p.track === track && p.taskId !== '?') tasks.add(p.taskId);
    const versions = data.versions.map((v) => `v${v.version}`).join(', ');
    els[`${prefix}Tasks`].textContent = tasks.size
      ? `${tasks.size} tarea${tasks.size > 1 ? 's' : ''} vista${tasks.size > 1 ? 's' : ''}${
          versions ? ` · ${versions}` : ''
        }`
      : 'sin tareas vistas';

    card.dataset.active = lastProbe?.track === track ? 'true' : 'false';
    card.dataset.idle = data.hits === 0 ? 'true' : 'false';
    renderSparkline(els[`${prefix}Spark`], stats.series, track);
  }
}

function renderSparkline(svg, series, track) {
  if (!svg || !series?.length) return;
  const width = 240;
  const height = 48;
  const max = Math.max(
    1,
    ...series.map((bucket) => Math.max(bucket.stable.hits, bucket.canary.hits)),
  );
  const step = series.length > 1 ? width / (series.length - 1) : width;
  const points = series.map((bucket, index) => {
    const value = bucket[track].hits;
    return [index * step, height - (value / max) * (height - 4) - 2];
  });
  const line = points.map(([x, y], i) => `${i === 0 ? 'M' : 'L'}${x.toFixed(1)} ${y.toFixed(1)}`).join(' ');
  const area = `${line} L${width} ${height} L0 ${height} Z`;
  svg.querySelector('.spark-line').setAttribute('d', line);
  svg.querySelector('.spark-area').setAttribute('d', area);
}

function renderBarcode() {
  const container = els.barcode;
  if (!container) return;
  const ticks = state.probes.slice(-BARCODE_TICKS);
  if (!ticks.length) {
    container.innerHTML = '<p class="barcode-empty">Sin solicitudes de prueba todavía.</p>';
    return;
  }
  const fragment = document.createDocumentFragment();
  for (const tick of ticks) {
    const node = document.createElement('span');
    node.className = 'tick';
    node.dataset.track = tick.track;
    node.dataset.error = tick.error ? 'true' : 'false';
    node.title = `${timeLabel(new Date(tick.at).toISOString())} · ${tick.track} v${tick.version} · ${
      tick.status || 'sin respuesta'
    } · ${Math.round(tick.rtt)} ms`;
    fragment.append(node);
  }
  container.replaceChildren(fragment);
}

function renderChart() {
  const series = state.stats?.series;
  const svg = els.chart;
  if (!svg || !series?.length) return;

  const width = 960;
  const height = 260;
  const pad = { top: 14, right: 10, bottom: 28, left: 46 };
  const plotW = width - pad.left - pad.right;
  const plotH = height - pad.top - pad.bottom;

  const totals = series.map((bucket) => bucket.stable.hits + bucket.canary.hits);
  const rawMax = Math.max(1, ...totals);
  const magnitude = 10 ** Math.floor(Math.log10(rawMax));
  const max = Math.ceil(rawMax / magnitude) * magnitude;

  const grid = els.chartGrid;
  const bars = els.chartBars;
  grid.replaceChildren();
  bars.replaceChildren();

  const line = (x1, y1, x2, y2) => {
    const node = document.createElementNS(SVG_NS, 'line');
    node.setAttribute('x1', x1);
    node.setAttribute('y1', y1);
    node.setAttribute('x2', x2);
    node.setAttribute('y2', y2);
    node.setAttribute('class', 'grid-line');
    return node;
  };
  const text = (x, y, value, anchor = 'end') => {
    const node = document.createElementNS(SVG_NS, 'text');
    node.setAttribute('x', x);
    node.setAttribute('y', y);
    node.setAttribute('class', 'grid-label');
    node.setAttribute('text-anchor', anchor);
    node.textContent = value;
    return node;
  };

  for (const ratio of [0, 0.25, 0.5, 0.75, 1]) {
    const y = pad.top + plotH - plotH * ratio;
    grid.append(line(pad.left, y, width - pad.right, y));
    grid.append(text(pad.left - 8, y + 4, nf.format(Math.round(max * ratio))));
  }

  const slot = plotW / series.length;
  const barWidth = Math.max(3, slot * 0.62);

  series.forEach((bucket, index) => {
    const x = pad.left + index * slot + (slot - barWidth) / 2;
    const stableHits = bucket.stable.hits;
    const canaryHits = bucket.canary.hits;
    const errors = bucket.stable.errors + bucket.canary.errors;

    const scale = (value) => (value / max) * plotH;
    let cursorY = pad.top + plotH;

    if (stableHits > 0) {
      const barHeight = Math.max(1, scale(stableHits));
      cursorY -= barHeight;
      const rect = document.createElementNS(SVG_NS, 'rect');
      rect.setAttribute('x', x.toFixed(1));
      rect.setAttribute('y', cursorY.toFixed(1));
      rect.setAttribute('width', barWidth.toFixed(1));
      rect.setAttribute('height', barHeight.toFixed(1));
      rect.setAttribute('rx', '2');
      rect.setAttribute('class', 'bar-stable');
      bars.append(rect);
    }
    if (canaryHits > 0) {
      const barHeight = Math.max(1, scale(canaryHits));
      cursorY -= barHeight;
      const rect = document.createElementNS(SVG_NS, 'rect');
      rect.setAttribute('x', x.toFixed(1));
      rect.setAttribute('y', cursorY.toFixed(1));
      rect.setAttribute('width', barWidth.toFixed(1));
      rect.setAttribute('height', barHeight.toFixed(1));
      rect.setAttribute('rx', '2');
      rect.setAttribute('class', 'bar-canary');
      bars.append(rect);
    }
    if (errors > 0) {
      const rect = document.createElementNS(SVG_NS, 'rect');
      rect.setAttribute('x', x.toFixed(1));
      rect.setAttribute('y', (cursorY - 4).toFixed(1));
      rect.setAttribute('width', barWidth.toFixed(1));
      rect.setAttribute('height', '3');
      rect.setAttribute('class', 'bar-error');
      bars.append(rect);
    }

    const everyN = series.length > 20 ? 4 : 3;
    if (index % everyN === 0 || index === series.length - 1) {
      grid.append(
        text(
          x + barWidth / 2,
          height - 9,
          new Date(bucket.at).toLocaleTimeString('es-ES', {
            hour: '2-digit',
            minute: '2-digit',
            hour12: false,
          }),
          'middle',
        ),
      );
    }
  });

  const totalHits = totals.reduce((sum, value) => sum + value, 0);
  els.chartSummary.textContent = `Últimos ${series.length} minutos: ${nf.format(
    totalHits,
  )} solicitudes, pico de ${nf.format(rawMax)} por minuto.`;
}

function renderFeed() {
  const container = els.feed;
  if (!container) return;

  const globalRows = state.stats?.recent || [];
  const useGlobal = globalRows.length > 0;
  const rows = useGlobal
    ? globalRows.slice(0, 30).map((hit) => ({
        at: hit.at,
        track: hit.track,
        version: hit.version,
        taskId: hit.taskId,
        status: hit.status,
        latency: hit.latencyMs,
        error: Number(hit.status) >= 500,
      }))
    : [...state.probes]
        .reverse()
        .slice(0, 30)
        .map((probeEntry) => ({
          at: new Date(probeEntry.at).toISOString(),
          track: probeEntry.track,
          version: probeEntry.version,
          taskId: probeEntry.taskId,
          status: probeEntry.status,
          latency: Math.round(probeEntry.rtt),
          error: probeEntry.error,
        }));

  els.feedSource.textContent = useGlobal
    ? 'origen: DynamoDB · todas las tareas'
    : 'origen: solicitudes de prueba de este navegador';

  if (!rows.length) {
    container.innerHTML = '<li class="feed-empty">Sin solicitudes todavía.</li>';
    return;
  }

  const fragment = document.createDocumentFragment();
  for (const row of rows) {
    const item = document.createElement('li');
    item.className = 'feed-row';
    item.dataset.track = row.track || 'unknown';
    item.dataset.error = row.error ? 'true' : 'false';

    const time = document.createElement('span');
    time.className = 'feed-time';
    time.textContent = timeLabel(row.at);

    const track = document.createElement('span');
    track.className = 'feed-track';
    track.textContent = `${(row.track || '?').toUpperCase()} v${row.version || '?'}`;

    const task = document.createElement('span');
    task.className = 'feed-task';
    task.textContent = shortTask(row.taskId);

    const status = document.createElement('span');
    status.className = 'feed-status';
    status.dataset.error = row.error ? 'true' : 'false';
    status.textContent = row.status || 'ERR';

    const latency = document.createElement('span');
    latency.className = 'feed-latency';
    latency.textContent = `${nf.format(Math.round(row.latency || 0))} ms`;

    item.append(time, track, task, status, latency);
    fragment.append(item);
  }
  container.replaceChildren(fragment);
}

function renderChaos() {
  const chaos = state.stats?.chaos;
  if (!chaos) return;
  const track = state.settings.chaosTrack;
  const current = chaos[track] || { failRate: 0, latencyMs: 0, unhealthy: false };

  if (document.activeElement !== inputs.failRate) inputs.failRate.value = current.failRate;
  if (document.activeElement !== inputs.latency) inputs.latency.value = current.latencyMs;
  inputs.unhealthy.checked = Boolean(current.unhealthy);
  els.failOut.textContent = `${current.failRate}%`;
  els.latencyOut.textContent = `${current.latencyMs} ms`;

  const anyActive = ['stable', 'canary'].some((name) => {
    const entry = chaos[name] || {};
    return entry.failRate > 0 || entry.latencyMs > 0 || entry.unhealthy;
  });
  els.chaosBlock.dataset.active = anyActive ? 'true' : 'false';
  els.chaosTag.hidden = !anyActive;
}

function renderAll() {
  renderWeights();
  renderGlobal();
  renderCards();
  renderChart();
  renderFeed();
  renderChaos();
  renderObserved();
}

/* ---------------------------------------------------------------- data loops */

async function loadStats() {
  try {
    state.stats = await api(`/api/stats?minutes=${WINDOW_MINUTES}&recent=40`);
    state.statsFailures = 0;
    if (state.stats.persistence?.degraded && !state.warned.degraded) {
      state.warned.degraded = true;
      toast(
        'DynamoDB no responde: contadores locales por tarea. Revisa TABLE_NAME y los permisos IAM.',
        'error',
        12000,
      );
    }
    renderAll();
  } catch (err) {
    state.statsFailures += 1;
    if (state.statsFailures === 3 && !state.warned.statsError) {
      state.warned.statsError = true;
      toast(`No se pueden leer las métricas: ${err.message}`, 'error');
    }
  }
}

async function loadConfig() {
  state.config = await api('/api/config');
  renderIdentity();
}

/* ------------------------------------------------------------------ controls */

function setPin(pin) {
  state.settings.pin = pin;
  document.querySelectorAll('[data-pin]').forEach((button) => {
    button.setAttribute('aria-checked', button.dataset.pin === pin ? 'true' : 'false');
  });
  if (pin !== 'auto') {
    toast(
      `Solicitudes de prueba forzadas a la versión ${pin}. La distribución observada ignora estas solicitudes.`,
      'info',
      5000,
    );
  }
}

function setChaosTrack(track) {
  state.settings.chaosTrack = track;
  document.querySelectorAll('[data-chaos-track]').forEach((button) => {
    button.setAttribute('aria-checked', button.dataset.chaosTrack === track ? 'true' : 'false');
  });
  renderChaos();
}

let chaosDebounce = null;
function pushChaos(patch, immediate = false) {
  const body = { track: state.settings.chaosTrack, ...patch };
  const send = async () => {
    try {
      await api('/api/chaos', {
        method: 'POST',
        headers: adminHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(body),
      });
      await loadStats();
    } catch (err) {
      toast(`No se pudo aplicar la inyección de fallos: ${err.message}`, 'error');
    }
  };
  if (immediate) {
    send();
    return;
  }
  if (chaosDebounce) clearTimeout(chaosDebounce);
  chaosDebounce = setTimeout(send, 350);
}

function wireControls() {
  inputs.rate.addEventListener('input', () => {
    state.settings.rate = Number(inputs.rate.value);
    els.rateOut.textContent = state.settings.rate;
    scheduleProbes();
  });

  inputs.failRate.addEventListener('input', () => {
    els.failOut.textContent = `${inputs.failRate.value}%`;
    pushChaos({ failRate: Number(inputs.failRate.value) });
  });

  inputs.latency.addEventListener('input', () => {
    els.latencyOut.textContent = `${inputs.latency.value} ms`;
    pushChaos({ latencyMs: Number(inputs.latency.value) });
  });

  inputs.unhealthy.addEventListener('change', () => {
    pushChaos({ unhealthy: inputs.unhealthy.checked }, true);
    if (inputs.unhealthy.checked) {
      toast(
        'Las tareas de esa versión responderán 503 en /api/health: el ALB las marcará unhealthy.',
        'info',
        8000,
      );
    }
  });

  document.querySelectorAll('[data-pin]').forEach((button) => {
    button.addEventListener('click', () => setPin(button.dataset.pin));
  });

  document.querySelectorAll('[data-chaos-track]').forEach((button) => {
    button.addEventListener('click', () => setChaosTrack(button.dataset.chaosTrack));
  });

  document.querySelector('[data-action="toggle-probes"]').addEventListener('click', (event) => {
    state.paused = !state.paused;
    const button = event.currentTarget;
    button.setAttribute('aria-pressed', state.paused ? 'false' : 'true');
    els.probeToggleLabel.textContent = state.paused ? 'Reanudar muestreo' : 'Pausar muestreo';
    scheduleProbes();
    renderObserved();
  });

  document.querySelector('[data-action="reset"]').addEventListener('click', async () => {
    try {
      await api('/api/reset', { method: 'POST', headers: adminHeaders() });
      state.probes = [];
      toast('Contadores reiniciados.', 'success', 4000);
      await loadStats();
      queueLiveRender();
    } catch (err) {
      toast(`No se pudieron reiniciar los contadores: ${err.message}`, 'error');
    }
  });

  document.querySelector('[data-action="break-canary"]').addEventListener('click', () => {
    inputs.failRate.value = 50;
    inputs.latency.value = 1200;
    els.failOut.textContent = '50%';
    els.latencyOut.textContent = '1200 ms';
    pushChaos({ failRate: 50, latencyMs: 1200 }, true);
    toast(
      `Simulando incidente en la versión ${state.settings.chaosTrack}: 50% de 5xx y 1200 ms extra. Las alarmas deberían disparar el rollback.`,
      'error',
      9000,
    );
  });

  document.querySelector('[data-action="clear-chaos"]').addEventListener('click', async () => {
    try {
      await api('/api/chaos', { method: 'DELETE', headers: adminHeaders() });
      inputs.failRate.value = 0;
      inputs.latency.value = 0;
      inputs.unhealthy.checked = false;
      els.failOut.textContent = '0%';
      els.latencyOut.textContent = '0 ms';
      toast('Inyección de fallos desactivada en ambas versiones.', 'success', 4000);
      await loadStats();
    } catch (err) {
      toast(`No se pudo desactivar la inyección de fallos: ${err.message}`, 'error');
    }
  });

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      if (probeTimer) clearInterval(probeTimer);
      probeTimer = null;
    } else {
      scheduleProbes();
      loadStats();
    }
  });
}

/* ---------------------------------------------------------------------- boot */

async function boot() {
  wireControls();
  els.rateOut.textContent = state.settings.rate;
  setPin('auto');
  setChaosTrack('canary');

  try {
    await loadConfig();
  } catch (err) {
    toast(`No se pudo leer /api/config: ${err.message}`, 'error');
  }

  await loadStats();
  scheduleProbes();
  setInterval(loadStats, STATS_INTERVAL_MS);
  document.body.dataset.state = 'ready';
}

boot();
