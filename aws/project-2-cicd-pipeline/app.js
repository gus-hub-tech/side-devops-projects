const crypto = require('crypto');
const express = require('express');
const os = require('os');
const pkg = require('./package.json');

const app = express();

// The dashboard is the only HTML we serve; keep the default framework header
// and any injected markup out of responses.
app.disable('x-powered-by');
// ECS tasks sit behind an ALB: trust exactly one proxy hop so req.ip and
// req.protocol describe the real client instead of the load balancer.
app.set('trust proxy', 1);

// PORT/HOST validation and the actual listener live in server.js. Keeping the
// Express app free of startup side effects lets tests import it directly.
const ENVIRONMENT = process.env.ENVIRONMENT || 'development';
const APP_VERSION = pkg.version;

const startedAt = new Date();

const ROUTES = [
  { path: '/', description: 'Status dashboard' },
  { path: '/health', description: 'Health probe' },
  { path: '/api/info', description: 'Runtime details' },
  { path: '/api/version', description: 'App name and version' },
];

// ---------------------------------------------------------------------------
// Middleware
// ---------------------------------------------------------------------------

// Basic hardening headers (no extra dependencies needed).
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader(
    'Content-Security-Policy',
    "default-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; " +
      "base-uri 'none'; frame-ancestors 'none'"
  );
  // Every response is live runtime data; never let a proxy or browser cache it.
  res.setHeader('Cache-Control', 'no-store');
  next();
});

// Give every request an ID so a log line can be matched to a client report.
app.use((req, res, next) => {
  const incoming = req.get('x-request-id');
  req.id = /^[\w.-]{1,64}$/.test(incoming || '') ? incoming : crypto.randomUUID();
  res.setHeader('X-Request-Id', req.id);
  next();
});

// One log line per request so CloudWatch shows real traffic, not just startup.
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - start) / 1e6;
    console.log(
      `${new Date().toISOString()} ${req.method} ${req.originalUrl} ` +
        `${res.statusCode} ${ms.toFixed(1)}ms ip=${req.ip} req=${req.id}`
    );
  });
  next();
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const HTML_ESCAPES = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (ch) => HTML_ESCAPES[ch]);
}

function uptimeSeconds() {
  return Math.floor((Date.now() - startedAt.getTime()) / 1000);
}

function formatUptime(totalSeconds) {
  const d = Math.floor(totalSeconds / 86400);
  const h = Math.floor((totalSeconds % 86400) / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return [d && `${d}d`, (d || h) && `${h}h`, (d || h || m) && `${m}m`, `${s}s`]
    .filter(Boolean)
    .join(' ');
}

// Readable, timezone-unambiguous timestamp for the dashboard.
function utcStamp(date) {
  return `${date.toISOString().slice(0, 19).replace('T', ' ')} UTC`;
}

function serviceInfo() {
  const uptime = uptimeSeconds();
  return {
    app: pkg.name,
    version: APP_VERSION,
    environment: ENVIRONMENT,
    hostname: os.hostname(),
    node: process.version,
    uptimeSeconds: uptime,
    uptime: formatUptime(uptime),
    startedAt: startedAt.toISOString(),
  };
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

app.get('/', (req, res) => {
  const now = new Date();
  const uptime = formatUptime(uptimeSeconds());
  const hostname = os.hostname();

  const stats = [
    { label: 'Uptime', value: uptime, mono: true },
    { label: 'Version', value: `v${APP_VERSION}`, mono: true },
    { label: 'Environment', value: ENVIRONMENT },
    { label: 'Container', value: hostname, mono: true },
    { label: 'Node.js', value: process.version, mono: true },
    { label: 'Started', value: utcStamp(startedAt), mono: true },
  ]
    .map(
      ({ label, value, mono }) =>
        `<div class="stat">` +
        `<span class="label">${escapeHtml(label)}</span>` +
        `<span class="value${mono ? ' mono' : ''}">${escapeHtml(value)}</span>` +
        `</div>`
    )
    .join('\n      ');

  const links = ROUTES.filter((route) => route.path !== '/')
    .map(
      (route) =>
        `<a href="${route.path}">${route.path}` +
        `<span class="arrow" aria-hidden="true">→</span></a>`
    )
    .join('\n      ');

  res.type('html').send(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="description" content="Status dashboard for ${escapeHtml(pkg.name)}" />
  <meta name="theme-color" content="#f4f6fb" media="(prefers-color-scheme: light)" />
  <meta name="theme-color" content="#070b14" media="(prefers-color-scheme: dark)" />
  <title>${escapeHtml(pkg.name)} v${escapeHtml(APP_VERSION)}</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; }

    :root {
      color-scheme: light dark;
      --bg: #f4f6fb;
      --surface: rgba(255, 255, 255, 0.62);
      --card: rgba(255, 255, 255, 0.86);
      --text: #0f172a;
      --muted: #64748b;
      --border: rgba(15, 23, 42, 0.09);
      --accent: #16a34a;
      --accent-soft: rgba(22, 163, 74, 0.12);
      --shadow: 0 30px 70px -30px rgba(15, 23, 42, 0.35);
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #070b14;
        --surface: rgba(148, 163, 184, 0.08);
        --card: rgba(15, 23, 42, 0.72);
        --text: #e2e8f0;
        --muted: #94a3b8;
        --border: rgba(148, 163, 184, 0.16);
        --accent: #4ade80;
        --accent-soft: rgba(74, 222, 128, 0.14);
        --shadow: 0 30px 80px -30px rgba(0, 0, 0, 0.8);
      }
    }

    html { -webkit-text-size-adjust: 100%; }

    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: clamp(20px, 5vw, 48px);
      font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
      line-height: 1.5;
      color: var(--text);
      background:
        radial-gradient(900px 500px at 12% -10%, rgba(34, 197, 94, 0.18), transparent 60%),
        radial-gradient(800px 500px at 105% 5%, rgba(59, 130, 246, 0.16), transparent 55%),
        var(--bg);
      background-attachment: fixed;
    }

    .card {
      width: min(780px, 100%);
      padding: clamp(24px, 4.5vw, 44px);
      border: 1px solid var(--border);
      border-radius: 26px;
      background: var(--card);
      box-shadow: var(--shadow);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      animation: rise 0.5s ease-out both;
    }

    @keyframes rise {
      from { opacity: 0; transform: translateY(10px); }
      to { opacity: 1; transform: none; }
    }

    .head {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 16px;
      flex-wrap: wrap;
    }

    .identity { display: flex; align-items: center; gap: 14px; }

    .logo {
      display: grid;
      place-items: center;
      flex: 0 0 auto;
      width: 52px;
      height: 52px;
      border-radius: 16px;
      font-size: 26px;
      background: linear-gradient(140deg, rgba(34, 197, 94, 0.22), rgba(59, 130, 246, 0.22));
      border: 1px solid var(--border);
    }

    .title-row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }

    h1 {
      margin: 0;
      font-size: clamp(1.35rem, 3vw, 1.6rem);
      letter-spacing: -0.02em;
    }

    .version {
      padding: 3px 8px;
      border-radius: 999px;
      border: 1px solid var(--border);
      color: var(--muted);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 0.72rem;
    }

    .tagline { margin: 2px 0 0; color: var(--muted); font-size: 0.9rem; }

    .pill {
      display: inline-flex;
      align-items: center;
      gap: 7px;
      padding: 6px 12px;
      border-radius: 999px;
      font-size: 0.8rem;
      font-weight: 600;
      color: var(--accent);
      background: var(--accent-soft);
      border: 1px solid color-mix(in srgb, var(--accent) 30%, transparent);
    }

    .pill-dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: currentColor;
    }

    .status {
      display: flex;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
      margin-top: 26px;
      padding: 12px 16px;
      border: 1px solid var(--border);
      border-radius: 14px;
      background: var(--surface);
      font-size: 0.9rem;
    }

    .pulse {
      position: relative;
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: var(--accent);
    }

    .pulse::after {
      content: "";
      position: absolute;
      inset: -4px;
      border: 2px solid var(--accent);
      border-radius: 50%;
      animation: ping 2s ease-out infinite;
    }

    @keyframes ping {
      0% { transform: scale(0.6); opacity: 0.7; }
      80%, 100% { transform: scale(1.5); opacity: 0; }
    }

    .status-text { font-weight: 600; }

    .status-uptime {
      margin-left: auto;
      color: var(--muted);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 0.82rem;
    }

    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 12px;
      margin-top: 16px;
    }

    .stat {
      padding: 14px 16px;
      border: 1px solid var(--border);
      border-radius: 14px;
      background: var(--surface);
      transition: transform 0.15s ease, border-color 0.15s ease;
    }

    .stat:hover {
      transform: translateY(-2px);
      border-color: color-mix(in srgb, var(--accent) 35%, transparent);
    }

    .label {
      display: block;
      margin-bottom: 4px;
      color: var(--muted);
      font-size: 0.7rem;
      font-weight: 600;
      letter-spacing: 0.09em;
      text-transform: uppercase;
    }

    .value {
      display: block;
      font-size: 0.95rem;
      font-weight: 600;
      overflow-wrap: anywhere;
    }

    .mono {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 0.88rem;
    }

    .links { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 22px; }

    .links a {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 9px 14px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--surface);
      color: var(--text);
      font-size: 0.86rem;
      font-weight: 600;
      text-decoration: none;
      transition: color 0.15s ease, border-color 0.15s ease,
                  transform 0.15s ease, background 0.15s ease;
    }

    .links a:hover {
      color: var(--accent);
      border-color: color-mix(in srgb, var(--accent) 45%, transparent);
      transform: translateY(-1px);
    }

    .arrow { transition: transform 0.15s ease; }
    .links a:hover .arrow { transform: translateX(2px); }

    a:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }

    footer {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      flex-wrap: wrap;
      margin-top: 28px;
      padding-top: 16px;
      border-top: 1px solid var(--border);
      color: var(--muted);
      font-size: 0.78rem;
    }

    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after {
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0.01ms !important;
      }
    }
  </style>
</head>
<body>
  <main class="card">
    <header class="head">
      <div class="identity">
        <div class="logo" aria-hidden="true">🚀</div>
        <div>
          <div class="title-row">
            <h1>${escapeHtml(pkg.name)}</h1>
            <span class="version">v${escapeHtml(APP_VERSION)}</span>
          </div>
          <p class="tagline">Deployed automatically to AWS ECS Fargate</p>
        </div>
      </div>
      <span class="pill">
        <span class="pill-dot" aria-hidden="true"></span>${escapeHtml(ENVIRONMENT)}
      </span>
    </header>

    <section class="status" role="status">
      <span class="pulse" aria-hidden="true"></span>
      <span class="status-text">All systems operational</span>
      <span class="status-uptime">up ${escapeHtml(uptime)}</span>
    </section>

    <section class="grid" aria-label="Runtime details">
      ${stats}
    </section>

    <nav class="links" aria-label="Endpoints">
      ${links}
    </nav>

    <footer>
      <span>${escapeHtml(pkg.name)} · ${escapeHtml(ENVIRONMENT)}</span>
      <span>Rendered ${escapeHtml(utcStamp(now))}</span>
    </footer>
  </main>
</body>
</html>`);
});

// Browsers request this automatically; answer without a log-worthy 404.
app.get('/favicon.ico', (req, res) => {
  res.status(204).end();
});

app.get('/health', (req, res) => {
  res.json({
    status: 'healthy',
    uptimeSeconds: uptimeSeconds(),
    version: APP_VERSION,
    environment: ENVIRONMENT,
    time: new Date().toISOString(),
  });
});

app.get('/api/info', (req, res) => {
  res.json({ ...serviceInfo(), timestamp: new Date().toISOString() });
});

app.get('/api/version', (req, res) => {
  res.json({ name: pkg.name, version: APP_VERSION, environment: ENVIRONMENT });
});

// ---------------------------------------------------------------------------
// Fallbacks
// ---------------------------------------------------------------------------

app.use((req, res) => {
  res.status(404).json({
    error: 'Not Found',
    path: req.originalUrl,
    hint: `Available routes: ${ROUTES.map((route) => route.path).join(', ')}`,
  });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error(`Unhandled error (req=${req.id}):`, err);
  res.status(500).json({ error: 'Internal Server Error', requestId: req.id });
});

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

// server.js owns the listener and process lifecycle so tests can import the
// Express app without opening a port or registering signal handlers.
module.exports = app;
