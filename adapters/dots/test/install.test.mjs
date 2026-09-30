import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

test('receiver lock contains complete package records for a clean npm ci', async () => {
  const lock = JSON.parse(await readFile(new URL('../receiver/package-lock.json', import.meta.url), 'utf8'));
  const packages = Object.entries(lock.packages);
  assert.ok(packages.length > 1);
  for (const [path, entry] of packages) {
    assert.ok(typeof entry.version === 'string' && entry.version.length > 0,
      `Incomplete package version: ${path}`);
    if (path) {
      assert.ok(typeof entry.resolved === 'string', `Missing resolution: ${path}`);
      assert.ok(typeof entry.integrity === 'string', `Missing integrity: ${path}`);
    }
  }
});
