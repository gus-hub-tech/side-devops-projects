const pkg = require('./package.json');

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

// Importing the app has no side effects, so tests can use it directly.
const app = require('./app');

const server = app.listen(PORT, HOST, () => {
  console.log(`App running on http://${HOST}:${PORT}`);
  console.log(`Environment: ${ENVIRONMENT} | Version: ${pkg.version}`);
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
