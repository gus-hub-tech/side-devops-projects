const express = require('express');
const os = require('os');
const pkg = require('./package.json');

const app = express();

// PORT defaults to 3001; ECS/ALB can override it via the task definition.
const PORT = Number(process.env.PORT) || 3001;
const HOST = process.env.HOST || '0.0.0.0'; // must bind all interfaces inside a container
const ENVIRONMENT = process.env.ENVIRONMENT || 'development';
const APP_VERSION = pkg.version;

const startedAt = new Date();

// ---------------------------------------------------------------------------
// Middleware
// ---------------------------------------------------------------------------

// Basic hardening headers (no extra dependencies needed).
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  next();
});

// One log line per request so CloudWatch shows real traffic, not just startup.
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - start) / 1e6;
    console.log(
      `${new Date().toISOString()} ${req.method} ${req.originalUrl} ` +
        `${res.statusCode} ${ms.toFixed(1)}ms ${req.ip}`
    );
  });
  next();
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
  return {
    app: pkg.name,
    version: APP_VERSION,
    environment: ENVIRONMENT,
    hostname: os.hostname(),
    node: process.version,
    uptimeSeconds: uptimeSeconds(),
    uptime: formatUptime(uptimeSeconds()),
    startedAt: startedAt.toISOString(),
  };
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

app.get('/', (req, res) => {
  res.type('html').send(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${pkg.name} v${APP_VERSION}</title>
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
  <h1>🚀 ${pkg.name} <span class="badge">${ENVIRONMENT}</span></h1>
  <p>Deployed automatically to AWS ECS Fargate by GitHub Actions.</p>

  <table>
    <tr><th>Version</th><td><code>v${APP_VERSION}</code></td></tr>
    <tr><th>Environment</th><td>${ENVIRONMENT}</td></tr>
    <tr><th>Container</th><td><code>${os.hostname()}</code></td></tr>
    <tr><th>Node.js</th><td>${process.version}</td></tr>
    <tr><th>Uptime</th><td>${formatUptime(uptimeSeconds())}</td></tr>
    <tr><th>Started at</th><td>${startedAt.toISOString()}</td></tr>
    <tr><th>Server time</th><td>${new Date().toISOString()}</td></tr>
  </table>

  <p>
    <a href="/health">/health</a> ·
    <a href="/api/info">/api/info</a> ·
    <a href="/api/version">/api/version</a>
  </p>

  <footer>Rendered by ${pkg.name} on ${new Date().toLocaleString()}</footer>
</body>
</html>`);
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
    hint: 'Available routes: /, /health, /api/info, /api/version',
  });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal Server Error' });
});

// ---------------------------------------------------------------------------
// Startup / shutdown
// ---------------------------------------------------------------------------

const server = app.listen(PORT, HOST, () => {
  console.log(`App running on http://${HOST}:${PORT}`);
  console.log(`Environment: ${ENVIRONMENT} | Version: ${APP_VERSION}`);
});

// ECS sends SIGTERM before replacing a task: stop accepting connections and
// finish in-flight requests so deploys don't drop traffic.
function shutdown(signal) {
  console.log(`${signal} received, shutting down gracefully...`);
  server.close(() => {
    console.log('HTTP server closed.');
    process.exit(0);
  });
  setTimeout(() => {
    console.error('Forced shutdown after timeout.');
    process.exit(1);
  }, 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = server;
