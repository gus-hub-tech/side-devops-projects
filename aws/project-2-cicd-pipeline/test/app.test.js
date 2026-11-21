process.env.ENVIRONMENT = 'test';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const app = require('../app');
const pkg = require('../package.json');

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

test('GET /health returns a healthy payload', async () => {
  const res = await request(app).get('/health').expect(200);

  assert.match(res.headers['content-type'], /application\/json/);
  assert.equal(res.body.status, 'healthy');
  assert.equal(res.body.version, pkg.version);
  assert.equal(res.body.environment, 'test');
  assert.equal(typeof res.body.uptimeSeconds, 'number');
  assert.ok(res.body.uptimeSeconds >= 0);
  assert.ok(!Number.isNaN(Date.parse(res.body.time)));
});

test('GET /api/version returns app metadata', async () => {
  const res = await request(app).get('/api/version').expect(200);

  assert.deepEqual(res.body, {
    name: pkg.name,
    version: pkg.version,
    environment: 'test',
  });
});

test('GET /api/info returns runtime details', async () => {
  const res = await request(app).get('/api/info').expect(200);

  assert.equal(res.body.app, pkg.name);
  assert.equal(res.body.version, pkg.version);
  assert.equal(res.body.environment, 'test');
  assert.equal(res.body.node, process.version);
  assert.equal(typeof res.body.hostname, 'string');
  assert.equal(typeof res.body.uptimeSeconds, 'number');
  assert.ok(res.body.uptimeSeconds >= 0);
  assert.ok(!Number.isNaN(Date.parse(res.body.startedAt)));
  assert.ok(!Number.isNaN(Date.parse(res.body.timestamp)));
});

test('GET / renders the dashboard', async () => {
  const res = await request(app).get('/').expect(200);

  assert.match(res.headers['content-type'], /text\/html/);
  assert.ok(res.text.includes(pkg.name));
  assert.ok(res.text.includes(`v${pkg.version}`));
  assert.ok(res.text.includes('All systems operational'));
  assert.ok(res.text.includes('/health'));
});

test('GET /favicon.ico returns 204', async () => {
  await request(app).get('/favicon.ico').expect(204);
});

test('unknown routes return a JSON 404 with route hints', async () => {
  const res = await request(app).get('/does-not-exist').expect(404);

  assert.equal(res.body.error, 'Not Found');
  assert.equal(res.body.path, '/does-not-exist');
  assert.match(res.body.hint, /\/health/);
  assert.match(res.body.hint, /\/api\/info/);
});

test('responses include hardening headers and no-store caching', async () => {
  const res = await request(app).get('/health').expect(200);

  assert.equal(res.headers['cache-control'], 'no-store');
  assert.equal(res.headers['x-content-type-options'], 'nosniff');
  assert.equal(res.headers['x-frame-options'], 'DENY');
  assert.equal(res.headers['referrer-policy'], 'no-referrer');
  assert.match(
    res.headers['content-security-policy'],
    /default-src 'self'/
  );
});

test('a valid incoming request ID is echoed back', async () => {
  const res = await request(app)
    .get('/health')
    .set('X-Request-Id', 'test-request-1')
    .expect(200);

  assert.equal(res.headers['x-request-id'], 'test-request-1');
});

test('an invalid incoming request ID is replaced with a UUID', async () => {
  const res = await request(app)
    .get('/health')
    .set('X-Request-Id', 'not a valid request id')
    .expect(200);

  assert.match(res.headers['x-request-id'], UUID_RE);
});
