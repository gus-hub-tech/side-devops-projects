const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');

for (const port of ['not-a-port', '0', '65536']) {
  test(`server rejects PORT=${port}`, () => {
    const result = spawnSync(process.execPath, ['server.js'], {
      cwd: ROOT,
      env: { ...process.env, PORT: port },
      encoding: 'utf8',
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /Invalid PORT/);
  });
}
