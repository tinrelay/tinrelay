import test from 'node:test';
import assert from 'node:assert/strict';
import {fixture} from './fixture.mjs';

test('successful MCP responses carry complete-result and private tool-cache metadata', async t => {
  const f = await fixture(t);
  for (const method of ['server/discover', 'ping', 'tools/list', 'events/list']) {
    const response = await f.rpc(method);
    assert.equal(response.status, 200);
    const reply = await response.json();
    assert.equal(reply.result.resultType, 'complete', method);
  }
  assert.deepEqual((await (await f.rpc('tools/list')).json()).result,
    {resultType: 'complete', ttlMs: 0, cacheScope: 'private', tools: []});
  const subscribed = await (await f.rpc('events/subscribe', f.params())).json();
  assert.equal(subscribed.result.resultType, 'complete');
  assert.ok(subscribed.result.id);
  const unsubscribed = await (await f.rpc('events/unsubscribe', f.params())).json();
  assert.deepEqual(unsubscribed.result, {resultType: 'complete'});
});
