const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const READY_TIMEOUT_MS = 10000;
const SHUTDOWN_TIMEOUT_MS = 5000;

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Ask the OS for an unused port, then release it for the child process.
function getFreePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.unref();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close((err) => (err ? reject(err) : resolve(port)));
    });
  });
}

// Start the real server on the given port and collect its output for assertions.
function startServer(port) {
  const child = spawn(process.execPath, ['server.js'], {
    cwd: ROOT,
    env: {
      ...process.env,
      PORT: String(port),
      HOST: '127.0.0.1',
      ENVIRONMENT: 'test',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });

  return {
    child,
    getOutput: () => `stdout:\n${stdout}\nstderr:\n${stderr}`,
    stdout: () => stdout,
    stderr: () => stderr,
  };
}

function healthCheck(port) {
  return new Promise((resolve) => {
    const req = http.get(
      {
        host: '127.0.0.1',
        port,
        path: '/health',
        agent: false,
        timeout: 500,
      },
      (res) => {
        res.resume();
        resolve(res.statusCode === 200);
      }
    );
    req.once('error', () => resolve(false));
    req.once('timeout', () => {
      req.destroy();
      resolve(false);
    });
  });
}

async function waitForReady(child, port, getOutput) {
  const deadline = Date.now() + READY_TIMEOUT_MS;

  while (Date.now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(
        `server exited before becoming ready ` +
          `(code=${child.exitCode}, signal=${child.signalCode}):\n${getOutput()}`
      );
    }
    if (await healthCheck(port)) return;
    await delay(100);
  }

  throw new Error(`server did not become ready on port ${port}:\n${getOutput()}`);
}

function waitForExit(child, timeout = SHUTDOWN_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve({ code: child.exitCode, signal: child.signalCode });
      return;
    }

    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`server did not exit within ${timeout}ms after SIGTERM`));
    }, timeout);

    function cleanup() {
      clearTimeout(timer);
      child.off('exit', onExit);
    }

    function onExit(code, signal) {
      cleanup();
      resolve({ code, signal });
    }

    child.once('exit', onExit);
  });
}

function isPortOpen(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: '127.0.0.1', port });
    socket.setTimeout(1000);
    socket.once('connect', () => {
      socket.destroy();
      resolve(true);
    });
    socket.once('error', () => resolve(false));
    socket.once('timeout', () => {
      socket.destroy();
      resolve(false);
    });
  });
}

// The test-only endpoint flushes its headers immediately, so resolving this
// promise proves the handler is still running when the test sends SIGTERM.
function startSlowRequest(port, delayMs) {
  let request;
  const headers = new Promise((resolve, reject) => {
    request = http.get(
      {
        host: '127.0.0.1',
        port,
        path: `/__test/slow?delay=${delayMs}`,
        agent: false,
        timeout: 5000,
      },
      (res) => {
        res.setEncoding('utf8');
        const body = new Promise((resolveBody, rejectBody) => {
          let raw = '';
          res.on('data', (chunk) => {
            raw += chunk;
          });
          res.on('end', () => {
            try {
              resolveBody(JSON.parse(raw));
            } catch (err) {
              rejectBody(new Error(`Invalid slow endpoint response: ${raw}`));
            }
          });
          res.on('error', rejectBody);
          res.on('aborted', () => rejectBody(new Error('slow response aborted')));
        });
        resolve({ statusCode: res.statusCode, body });
      }
    );
    request.once('error', reject);
    request.once('timeout', () => {
      request.destroy(new Error('slow request timed out'));
    });
  });
  return headers;
}

test(
  'SIGTERM shuts the server down gracefully',
  { skip: process.platform === 'win32', timeout: 30000 },
  async () => {
    const port = await getFreePort();
    const { child, getOutput, stdout, stderr } = startServer(port);

    try {
      await waitForReady(child, port, getOutput);

      assert.match(
        stdout(),
        new RegExp(`App running on http://127\\.0\\.0\\.1:${port}`)
      );

      // Register the exit listener before signalling so a fast exit is not missed.
      const exit = waitForExit(child);
      child.kill('SIGTERM');
      const { code, signal } = await exit;

      assert.equal(signal, null, `server was terminated by ${signal}:\n${stderr()}`);
      assert.equal(code, 0, `server exited with code ${code}:\n${stderr()}`);
      assert.match(stdout(), /SIGTERM received, shutting down gracefully\.\.\./);
      assert.match(stdout(), /HTTP server closed\./);
      assert.equal(
        await isPortOpen(port),
        false,
        `port ${port} still accepts connections after shutdown`
      );
    } finally {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill('SIGKILL');
      }
    }
  }
);

test(
  'SIGTERM waits for in-flight requests to finish before exiting',
  { skip: process.platform === 'win32', timeout: 30000 },
  async () => {
    const port = await getFreePort();
    const { child, getOutput, stdout, stderr } = startServer(port);
    const delayMs = 1200;

    try {
      await waitForReady(child, port, getOutput);

      // Headers arrive before the delayed body, so the request is in flight.
      const pending = await startSlowRequest(port, delayMs);
      const signalledAt = Date.now();

      const exit = waitForExit(child);
      child.kill('SIGTERM');

      // The process must stay alive until this response is fully delivered.
      const body = await pending.body;
      const { code, signal } = await exit;

      assert.equal(pending.statusCode, 200, getOutput());
      assert.equal(body.ok, true, getOutput());
      assert.ok(
        body.elapsedMs >= delayMs - 100,
        `response finished too early (${body.elapsedMs}ms):\n${getOutput()}`
      );
      assert.ok(
        Date.parse(body.finishedAt) >= signalledAt - 100,
        `response finished before SIGTERM was sent:\n${getOutput()}`
      );
      assert.equal(signal, null, `server was terminated by ${signal}:\n${stderr()}`);
      assert.equal(code, 0, `server exited with code ${code}:\n${stderr()}`);
      assert.match(stdout(), /SIGTERM received, shutting down gracefully\.\.\./);
      assert.match(
        stdout(),
        new RegExp(`GET /__test/slow\\?delay=${delayMs} 200`)
      );
      assert.match(stdout(), /HTTP server closed\./);
      assert.equal(
        await isPortOpen(port),
        false,
        `port ${port} still accepts connections after shutdown`
      );
    } finally {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill('SIGKILL');
      }
    }
  }
);
