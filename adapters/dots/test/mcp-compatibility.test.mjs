import test from 'node:test';
import assert from 'node:assert/strict';
import {fixture} from './fixture.mjs';
import {MAIL_CONTRACT, MAIL_EVENT_NAME} from '../receiver/event.mjs';

// Preserve the result metadata proven by hosted receiver v5 (351609de1d24).
test('every successful MCP result is complete and tools have private zero-TTL cache metadata', async t => {
  const f = await fixture(t);
  for (const method of ['server/discover', 'ping', 'tools/list', 'events/list']) {
    const reply = await (await f.rpc(method)).json();
    assert.equal(reply.result.resultType, 'complete');
  }
  assert.deepEqual((await (await f.rpc('tools/list')).json()).result,
    {resultType: 'complete', ttlMs: 0, cacheScope: 'private', tools: []});
  f.env.DOTS_MAIL_HINTS = 'true';
  for (const params of [f.params(), {...f.params(), name: MAIL_EVENT_NAME,
    arguments: {local_ship: 'receiver'}}]) {
    const subscribed = await (await f.rpc('events/subscribe', params)).json();
    assert.equal(subscribed.result.resultType, 'complete');
    assert.ok(subscribed.result.id);
    const unsubscribed = await (await f.rpc('events/unsubscribe', params)).json();
    assert.deepEqual(unsubscribed.result, {resultType: 'complete'});
  }
  const rejected = await (await f.rpc('initialize', {protocolVersion: '2025-03-26'})).json();
  assert.equal(rejected.error.code, -32601);
  assert.equal(rejected.result, undefined);
  assert.equal((await f.rpc('notifications/initialized')).status, 202);
});

test('v5 MCP traces log only bounded method/outcome/error and validated protocol metadata', async t => {
  const f = await fixture(t);
  const logs = [];
  const info = console.info;
  console.info = value => logs.push(JSON.parse(value));
  try {
    await f.rpc('ping', {body: 'private prose'});
    await f.rpc('initialize', {protocolVersion: '2025-03-26', body: 'private prose'});
    await f.rpc('initialize', {protocolVersion: 'private prose'});
    await f.rpc('private prose', {body: 'private prose'});
    await f.rpc('notifications/initialized', {body: 'private prose'});
    f.behavior(() => {throw Error('private prose');});
    await f.rpc('events/subscribe', f.params());
    f.env.DOTS_MAIL_HINTS = 'true';
    await f.request('/hint', {contract: MAIL_CONTRACT, local_ship: 'receiver'});
    f.env.SUBSCRIPTIONS = {get() {throw Error('private storage detail');}};
    const failed = await (await f.rpc('ping')).json();
    assert.deepEqual(failed.error, {code: -32603, message: 'receiver_unavailable'});
  } finally {console.info = info;}
  assert.deepEqual(logs, [
    {method: 'ping', outcome: 'success'},
    {method: 'initialize', outcome: 'error', error_code: -32601,
      requested_protocol_version: '2025-03-26'},
    {method: 'initialize', outcome: 'error', error_code: -32601},
    {method: 'unknown', outcome: 'error', error_code: -32601},
    {method: 'notifications/initialized', outcome: 'success'},
    {method: 'events/subscribe', outcome: 'error', error_code: -32015},
    {method: 'ping', outcome: 'error', error_code: -32603},
  ]);
});
