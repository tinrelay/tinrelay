import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {fixture, pointer, source, secret} from './fixture.mjs';

test('legacy initialization reports the supported modern discovery boundary without side effects', async t => {
  const f = await fixture(t);
  for (const [index, protocolVersion] of ['2025-03-26', '2025-06-18', '2025-11-25'].entries()) {
    const id = 40 + index;
    const response = await f.request('/mcp', {jsonrpc: '2.0', id, method: 'initialize', params: {
      protocolVersion, capabilities: {}, clientInfo: {name: 'synthetic-client', version: '1'},
    }}, {'x-test-session': 'owner'});
    const reply = await response.json();
    assert.equal(reply.jsonrpc, '2.0');
    assert.equal(reply.id, id);
    assert.equal(reply.error?.code, -32601);
    assert.match(reply.error.message, /2026-07-28/);
    assert.match(reply.error.message, /server\/discover/);
    assert.equal(reply.result, undefined);
  }
  assert.equal(f.subscriptions.objects.size, 0);
  assert.equal(f.callbacks.length, 0);
});

test('modern discovery exposes the implemented tools and event catalog without side effects', async t => {
  const f = await fixture(t);
  const discovered = await (await f.rpc('server/discover')).json();
  assert.deepEqual(discovered.result, {resultType: 'complete', supportedVersions: ['2026-07-28'],
    capabilities: {tools: {}, events: {}}});
  assert.deepEqual((await (await f.rpc('tools/list')).json()).result,
    {resultType: 'complete', ttlMs: 0, cacheScope: 'private', tools: []});
  const catalog = (await (await f.rpc('events/list')).json()).result;
  assert.equal(catalog.events.length, 1);
  assert.equal(catalog.events[0].name, 'tinrelay.transmission.received');
  assert.deepEqual(catalog.events[0].delivery, ['webhook']);
  assert.equal(f.subscriptions.objects.size, 0);
  assert.equal(f.callbacks.length, 0);
});

test('private dispatcher and owner authorization protect subscription changes', async t => {
  const f = await fixture(t);
  const subscribe = {jsonrpc: '2.0', id: 1, method: 'events/subscribe', params: f.params()};
  assert.equal((await f.request('/mcp', subscribe, {'oai-authenticated-user-id': 'owner'})).status, 401);
  assert.equal(f.subscriptions.objects.size, 0);
  assert.ok((await (await f.rpc('events/subscribe', f.params())).json()).result.id);
  assert.equal((await f.rpc('events/unsubscribe', f.params(), 'other')).status, 403);
  assert.equal(f.state().subscriptions.length, 1);
  assert.equal((await f.request('/deliver', {}, {'OAI-Sites-Authorization': 'Bearer wrong'})).status, 401);
});

test('subscription challenge and callbacks sign exact bytes and do not redirect', async t => {
  const f = await fixture(t);
  const params = f.params();
  params.delivery.url = 'http://127.0.0.1/events';
  assert.ok((await (await f.rpc('events/subscribe', params)).json()).error);
  assert.equal(f.callbacks.length, 0);
  await f.rpc('events/subscribe', f.params());
  await f.adapter().once();
  for (const call of f.callbacks) {
    const headers = call.headers;
    const signature = createHmac('sha256', Buffer.alloc(32, 'x'))
      .update(`${headers['webhook-id']}.${headers['webhook-timestamp']}.${call.body}`).digest('base64');
    assert.equal(headers['webhook-signature'], 'v1,' + signature);
    assert.equal(call.redirect, 'manual');
    assert.equal(call.signal.aborted, false);
  }
  f.behavior(() => new Response(null, {status: 302, headers: {Location: 'https://elsewhere.example'}}));
  assert.ok((await (await f.rpc('events/subscribe', f.params())).json()).error);
  assert.equal(f.state().subscriptions.length, 1);
});

test('failed verification does not enroll an owner or disturb a valid attention mapping', async t => {
  const f = await fixture(t);
  f.behavior(() => Response.json({challenge: 'wrong'}));
  const failure = await (await f.rpc('events/subscribe', f.params())).json();
  assert.equal(failure.error.code, -32015);
  assert.equal(failure.error.data.reason, 'challenge_failed');
  assert.equal(f.subscriptions.objects.size, 0);
  f.behavior(undefined);
  await f.rpc('events/subscribe', f.params());
  const original = f.state();
  f.behavior(() => {throw Error('private transport detail');});
  const failed = await (await f.rpc('events/subscribe', f.params('other'))).json();
  assert.equal(failed.error.data.reason, 'timeout_or_transport');
  assert.deepEqual(f.state(), original);
  assert.ok(!JSON.stringify(failed).includes(secret));
  assert.ok(!JSON.stringify(failed).includes('private transport detail'));
});

test('multiple attention names including empty retain their independent callbacks across restart', async t => {
  const f = await fixture(t);
  await f.rpc('events/subscribe', f.params());
  await f.rpc('events/subscribe', f.params('', 'https://callback.example/general'));
  f.restart();
  assert.equal(f.state().subscriptions.length, 2);
  await f.adapter().once();
  assert.equal(f.callbacks.at(-1).url, 'https://callback.example/events');
  const general = structuredClone(source);
  general.attention_label = general.signed_transmission.to_label = '';
  await writeFile(join(f.root, 'source.json'), JSON.stringify(general));
  await writeFile(join(f.root, 'pointer.json'), JSON.stringify({...pointer, name: ''}));
  await f.adapter().once();
  assert.equal(f.callbacks.at(-1).url, 'https://callback.example/general');
});

test('expiry and unsubscribe stop callbacks but keep local delivery pending', async t => {
  const f = await fixture(t);
  await f.rpc('events/subscribe', f.params());
  f.advance(60_001);
  assert.equal((await f.adapter().once()).state, 'pending');
  await f.rpc('events/subscribe', f.params());
  await f.rpc('events/unsubscribe', f.params());
  assert.equal((await f.adapter().once()).state, 'pending');
  assert.equal(f.callbacks.length, 2); // Verification only.
});

test('refresh rotates signing keys for a bounded overlap without changing subscription identity', async t => {
  const f = await fixture(t);
  const first = await (await f.rpc('events/subscribe', f.params())).json();
  const params = f.params();
  params.delivery.secret = 'whsec_' + Buffer.alloc(32, 'y').toString('base64');
  const refreshed = await (await f.rpc('events/subscribe', params)).json();
  assert.equal(refreshed.result.id, first.result.id);
  await f.adapter().once();
  assert.equal(f.callbacks.at(-1).headers['webhook-signature'].split(' ').length, 2);
  f.advance(30_000);
  await f.rpc('events/subscribe', params);
  f.advance(30_001);
  await f.adapter().once();
  assert.equal(f.callbacks.at(-1).headers['webhook-signature'].split(' ').length, 1);
});

test('unsubscribe during an initial challenge prevents late activation', async t => {
  const f = await fixture(t);
  let release, entered;
  const started = new Promise(resolve => {entered = resolve;});
  f.behavior(value => new Promise(resolve => {
    release = () => resolve(Response.json({challenge: value.challenge}));
    entered();
  }));
  const subscribing = f.rpc('events/subscribe', f.params());
  await started;
  await f.rpc('events/unsubscribe', f.params());
  release();
  assert.equal((await (await subscribing).json()).error.message, 'subscription_changed');
  assert.deepEqual(f.state().subscriptions, []);
});

test('a late older refresh cannot replace newer keys or erase another attention', async t => {
  const f = await fixture(t);
  await f.rpc('events/subscribe', f.params());
  let release, entered;
  const started = new Promise(resolve => {entered = resolve;});
  f.behavior(value => new Promise(resolve => {
    release = () => resolve(Response.json({challenge: value.challenge}));
    entered();
  }));
  const params = f.params();
  params.delivery.secret = 'whsec_' + Buffer.alloc(32, 'y').toString('base64');
  const old = f.rpc('events/subscribe', params);
  await started;
  f.behavior(undefined);
  const newer = {...params, delivery: {...params.delivery,
    secret: 'whsec_' + Buffer.alloc(32, 'z').toString('base64')}};
  await f.rpc('events/subscribe', newer);
  await f.rpc('events/subscribe', f.params('other', 'https://callback.example/other'));
  release();
  assert.equal((await (await old).json()).error.message, 'subscription_changed');
  assert.equal(f.state().subscriptions.find(sub => sub.attention === 'steward').secret,
    newer.delivery.secret);
  assert.equal(f.state().subscriptions.length, 2);
});

test('an expired attention can move to a new callback without reviving a late refresh', async t => {
  const f = await fixture(t);
  await f.rpc('events/subscribe', f.params());
  let release, entered;
  const started = new Promise(resolve => {entered = resolve;});
  f.behavior(value => new Promise(resolve => {
    release = () => resolve(Response.json({challenge: value.challenge})); entered();
  }));
  const old = f.rpc('events/subscribe', f.params());
  await started;
  f.advance(60_001);
  f.behavior(undefined);
  await f.rpc('events/subscribe', f.params('steward', 'https://callback.example/new'));
  release();
  assert.ok((await (await old).json()).error);
  await f.adapter().once();
  assert.equal(f.callbacks.at(-1).url, 'https://callback.example/new');
});
