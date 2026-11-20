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

// PORT defaults to 3001; ECS/ALB can override it via the task definition.
// Fail fast on a malformed value instead of silently listening elsewhere.
const rawPort = (process.env.PORT || '').trim();
const PORT = rawPort ? Number(rawPort) : 3001;
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
  console.error(`Invalid PORT: "${process.env.PORT}" (expected 1-65535)`);
  process.exit(1);
}

const HOST = process.env.HOST || '0.0.0.0'; // must bind all interfaces inside a container
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
  const uptime = uptimeSeconds();
  const rows = [
    ['Version', `<code>v${escapeHtml(APP_VERSION)}</code>`],
    ['Environment', escapeHtml(ENVIRONMENT)],
    ['Container', `<code>${escapeHtml(os.hostname())}</code>`],
    ['Node.js', escapeHtml(process.version)],
    ['Uptime', escapeHtml(formatUptime(uptime))],
    ['Started at', escapeHtml(startedAt.toISOString())],
    ['Server time', escapeHtml(new Date().toISOString())],
  ]
    .map(([label, value]) => `<tr><th>${label}</th><td>${value}</td></tr>`)
    .join('\n    ');

  const links = ROUTES.filter((route) => route.path !== '/')
    .map((route) => `<a href="${route.path}">${route.path}</a>`)
    .join(' ·\n    ');

  res.type('html').send(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(pkg.name)} v${escapeHtml(APP_VERSION)}</title>
  <style>
    :root { color-scheme: light dark; }
    body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
           max-width: 720px; margin: 48px auto; padding: 0 20px; line-height: 1.5; }
    h1 { margin-bottom: .25rem; }
    .badge { display: inline-block; padding: 2px 10px; border-radius: 999px;
             background: #16a34a; color: #fff; font-size: .8rem; vertical-align: middle; }
    table { border-collapse: collapse; width: 100%; margin-top: 1.5rem; }
    th, td { text-align: left; padding: .5rem .25rem; border-bottom: 1px solid #8883; }
    th { width: 38%; font-weight: 600; opacity: .75; }
    code { background: #8881; padding: 2px 6px; border-radius: 4px; }
    footer { margin-top: 2rem; font-size: .85rem; opacity: .7; }
  </style>
</head>
<body>
  <h1>🚀 ${escapeHtml(pkg.name)} <span class="badge">${escapeHtml(ENVIRONMENT)}</span></h1>
  <p>Deployed automatically to AWS ECS Fargate by GitHub Actions.</p>

  <table>
    ${rows}
  </table>

  <p>
    ${links}
  </p>

  <footer>Rendered by ${escapeHtml(pkg.name)} on ${escapeHtml(new Date().toISOString())}</footer>
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
// Startup / shutdown
// ---------------------------------------------------------------------------

const server = app.listen(PORT, HOST, () => {
  console.log(`App running on http://${HOST}:${PORT}`);
  console.log(`Environment: ${ENVIRONMENT} | Version: ${APP_VERSION}`);
});

// Keep idle keep-alive sockets a little longer than the ALB's 60s idle
// timeout, otherwise the load balancer can reuse a connection the app is
// already closing (the classic 502 on the next request).
server.keepAliveTimeout = 65000;
server.headersTimeout = 66000;

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already in use.`);
  } else {
    console.error('HTTP server error:', err);
  }
  process.exit(1);
});

// ECS sends SIGTERM before replacing a task: stop accepting connections and
// finish in-flight requests so deploys don't drop traffic.
let shuttingDown = false;

function shutdown(signal, exitCode = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`${signal} received, shutting down gracefully...`);

  const forceTimer = setTimeout(() => {
    console.error('Forced shutdown after timeout.');
    if (typeof server.closeAllConnections === 'function') {
      server.closeAllConnections();
    }
    process.exit(1);
  }, 10000);
  forceTimer.unref();

  server.close((err) => {
    clearTimeout(forceTimer);
    if (err) {
      console.error('Error closing HTTP server:', err);
      process.exit(1);
    }
    console.log('HTTP server closed.');
    process.exit(exitCode);
  });

  // Drop sockets that are merely idle so close() can complete promptly.
  if (typeof server.closeIdleConnections === 'function') {
    server.closeIdleConnections();
  }
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

process.on('uncaughtException', (err) => {
  console.error('Uncaught exception:', err);
  shutdown('uncaughtException', 1);
});

process.on('unhandledRejection', (reason) => {
  console.error('Unhandled promise rejection:', reason);
});

module.exports = server;
module.exports.app = app;
