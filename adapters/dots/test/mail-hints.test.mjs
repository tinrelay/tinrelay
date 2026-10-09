import test from 'node:test';
import assert from 'node:assert/strict';
import {access} from 'node:fs/promises';
import {createHash, createHmac} from 'node:crypto';
import {join} from 'node:path';
import {fixture, secret} from './fixture.mjs';
import {MAIL_EVENT_NAME, MAIL_CONTRACT} from '../receiver/event.mjs';

const hint = {contract: MAIL_CONTRACT, local_ship: 'receiver'};
const params = (ship = 'receiver') => ({name: MAIL_EVENT_NAME, arguments: {local_ship: ship},
  delivery: {mode: 'webhook', url: 'https://callback.example/collect', secret}});
const enable = f => {f.env.DOTS_MAIL_HINTS = 'true';};
const subscribe = async f => {
  const reply = await (await f.rpc('events/subscribe', params())).json();
  assert.ok(reply.result?.id, JSON.stringify(reply));
  return reply.result;
};

test('mail hints are opt-in and advertise a strictly ship-bound body-free event', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('/hint', hint)).status, 404);
  assert.ok((await (await f.rpc('events/subscribe', params())).json()).error);
  enable(f);
  const catalog = (await (await f.rpc('events/list')).json()).result.events;
  assert.equal(catalog.length, 2);
  const event = catalog.find(value => value.name === MAIL_EVENT_NAME);
  assert.deepEqual(event.inputSchema, {type: 'object', properties: {local_ship: {const: 'receiver'}},
    required: ['local_ship'], additionalProperties: false});
  assert.deepEqual(Object.keys(event.payloadSchema.properties).sort(),
    ['classification', 'contract', 'local_ship']);
  assert.equal(event.payloadSchema.additionalProperties, false);
  assert.equal(f.subscriptions.objects.size, 0);
});

test('malformed, oversized, extra-field, and wrong-ship hints cannot issue callbacks', async t => {
  const f = await fixture(t); enable(f); await subscribe(f);
  for (const value of [null, [], {}, {...hint, local_ship: 'other-ship'}, {...hint, contract: 'v0'},
    {...hint, attention_label: 'steward'}, {...hint, body: 'external'}, {...hint, count: 1},
    {...hint, body: 'x'.repeat(2000)}]) {
    assert.equal((await f.request('/hint', value)).status, 400);
  }
  const raw = new Request('https://receiver.example/hint', {method: 'POST',
    body: '{broken', headers: {'oai-authenticated-user-id': 'owner'}});
  // Use the same receiver directly only to exercise malformed HTTP JSON.
  const {createReceiver} = await import('../receiver/worker.mjs');
  assert.equal((await createReceiver().fetch(raw, f.env)).status, 400);
  assert.equal(f.callbacks.length, 1);
  for (const arguments_ of [{}, {local_ship: 'other-ship'}, {local_ship: 'receiver', attention_label: ''}]) {
    assert.ok((await (await f.rpc('events/subscribe', {...params(), arguments: arguments_})).json()).error);
  }
});

test('hints stay pending until matching callback receipt; duplicates carry only fresh notification metadata', async t => {
  const f = await fixture(t); enable(f);
  assert.equal((await f.request('/hint', hint)).status, 503);
  await f.rpc('events/subscribe', f.params());
  assert.equal((await f.request('/hint', hint)).status, 503); // An attention callback cannot collect.
  const subscription = await subscribe(f);
  const state = f.state();
  const events = [];
  for (let i = 0; i < 2; i++) {
    const response = await f.request('/hint', hint);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {state: 'received'});
    const call = f.callbacks.at(-1);
    assert.equal(call.url, params().delivery.url);
    assert.equal(call.headers['X-MCP-Subscription-Id'], subscription.id);
    assert.equal(call.redirect, 'manual');
    const event = JSON.parse(call.body); events.push(event);
    assert.equal(event.name, MAIL_EVENT_NAME);
    assert.deepEqual(event.data, {...hint, classification: 'untrusted_external'});
    assert.deepEqual(Object.keys(event).sort(), ['cursor', 'data', 'eventId', 'name', 'timestamp']);
    assert.equal(event.cursor, null);
    assert.equal(call.headers['webhook-id'], event.eventId);
    const signature = createHmac('sha256', Buffer.alloc(32, 'x'))
      .update(`${event.eventId}.${call.headers['webhook-timestamp']}.${call.body}`).digest('base64');
    assert.equal(call.headers['webhook-signature'], 'v1,' + signature);
    assert.ok(event.eventId.startsWith('tinrelay:receiver:hint:'));
  }
  assert.notEqual(events[0].eventId, events[1].eventId);
  assert.deepEqual(f.state(), state); // Neither a receipt ledger nor a radio ACK.
  await assert.rejects(access(join(f.root, 'calls'))); // No client/collector was invoked.
  await assert.rejects(access(join(f.root, 'routed')));
});

test('failed and uncertain callbacks never become ingress success or leak private errors', async t => {
  const f = await fixture(t); enable(f); await subscribe(f);
  const state = f.state();
  for (const status of [302, 400, 401, 408, 410, 413, 429, 500, 503]) {
    f.behavior(() => new Response(null, {status}));
    const response = await f.request('/hint', hint);
    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), {state: 'pending'});
  }
  f.behavior(() => {throw Error('private endpoint and credential');});
  const response = await f.request('/hint', hint);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {state: 'pending'});
  assert.deepEqual(f.state(), state);
});

test('callback timeout is bounded and leaves the hint pending', async t => {
  const f = await fixture(t); enable(f); await subscribe(f);
  const {createReceiver} = await import('../receiver/worker.mjs');
  // A public fetch consumes AbortSignal; keep Node alive while its timeout fires.
  const keepAlive = setTimeout(() => {}, 15_000); t.after(() => clearTimeout(keepAlive));
  let attempts = 0;
  const receiver = createReceiver({clock: () => Date.parse('2026-09-30T08:00:00Z'),
    send: (_, options) => new Promise((resolve, reject) => {
      attempts++;
      options.signal.addEventListener('abort', () => reject(options.signal.reason), {once: true});
    })});
  const started = performance.now();
  const response = await receiver.fetch(new Request('https://receiver.example/hint',
    {method: 'POST', body: JSON.stringify(hint)}), f.env);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {state: 'pending'});
  assert.equal(attempts, 1);
  assert.ok(performance.now() - started < 14_000);
  assert.equal(f.state().subscriptions.length, 1);
});

test('refresh, restart, expiry, and unsubscribe isolate collection from legacy attention state', async t => {
  const f = await fixture(t); enable(f);
  const legacy = (await (await f.rpc('events/subscribe', f.params())).json()).result;
  const first = await subscribe(f);
  f.restart();
  const rotated = params(); rotated.delivery.secret = 'whsec_' + Buffer.alloc(32, 'y').toString('base64');
  const refreshed = (await (await f.rpc('events/subscribe', rotated)).json()).result;
  assert.equal(refreshed.id, first.id);
  assert.equal(f.state().subscriptions.length, 2);
  await f.request('/hint', hint);
  assert.equal(f.callbacks.at(-1).headers['webhook-signature'].split(' ').length, 2);
  const other = params(); other.delivery.url = 'https://callback.example/other';
  assert.equal((await (await f.rpc('events/subscribe', other)).json()).error.message,
    'ship_already_subscribed');
  await f.rpc('events/unsubscribe', params());
  assert.equal((await f.request('/hint', hint)).status, 503);
  assert.equal(f.state().subscriptions[0].id, legacy.id);
  assert.equal((await f.adapter().once()).state, 'routed');
  await subscribe(f); f.advance(60_001);
  assert.equal((await f.request('/hint', hint)).status, 503);
  await subscribe(f); f.env.DOTS_MAIL_HINTS = 'false';
  assert.equal((await f.request('/hint', hint)).status, 404);
  f.env.DOTS_MAIL_HINTS = 'true'; f.restart();
  assert.equal((await f.request('/hint', hint)).status, 200);
});

test('unsubscribe during mail verification cannot revive collection on a late challenge', async t => {
  const f = await fixture(t); enable(f);
  let release, entered;
  const started = new Promise(resolve => {entered = resolve;});
  f.behavior(value => new Promise(resolve => {
    release = () => resolve(Response.json({challenge: value.challenge})); entered();
  }));
  const subscribing = f.rpc('events/subscribe', params());
  await started; await f.rpc('events/unsubscribe', params()); release();
  assert.equal((await (await subscribing).json()).error.message, 'subscription_changed');
  assert.equal((await f.request('/hint', hint)).status, 503);
});

test('private dispatch and pinned owner apply equally to mail hints and subscriptions', async t => {
  const f = await fixture(t); enable(f);
  assert.equal((await f.request('/hint', hint,
    {'OAI-Sites-Authorization': 'Bearer wrong', 'oai-authenticated-user-id': 'owner'})).status, 401);
  const request = {jsonrpc: '2.0', id: 1, method: 'events/subscribe', params: params()};
  assert.equal((await f.request('/mcp', request, {'oai-authenticated-user-id': 'owner'})).status, 401);
  assert.equal(f.callbacks.length, 0);
  await subscribe(f);
  assert.equal((await f.rpc('events/unsubscribe', params(), 'other')).status, 403);
  assert.equal((await f.rpc('events/subscribe', params(), 'other')).status, 403);
  assert.equal(f.state().subscriptions.length, 1);
});

test('pre-hint persisted subscription rows and IDs survive mail enrollment unchanged', async t => {
  const f = await fixture(t);
  const url = 'https://callback.example/events';
  const id = 'sub_' + createHash('sha256')
    .update(JSON.stringify(['receiver', 'owner', url, 'steward'])).digest('hex');
  const legacy = {id, attention: 'steward', url, secret,
    expires: Date.parse('2026-09-30T08:01:00Z'), old_secret: null, old_until: null};
  await f.subscriptions.put('tinrelay-dots/receiver.json',
    JSON.stringify({owner: 'owner', revision: 'pre-hint', subscriptions: [legacy]}),
    {onlyIf: {etagDoesNotMatch: '*'}});
  enable(f); f.restart(); await subscribe(f);
  assert.deepEqual(f.state().subscriptions.find(value => value.id === id), legacy);
  assert.equal((await f.adapter().once()).state, 'routed');
  assert.equal(f.callbacks.at(-1).headers['X-MCP-Subscription-Id'], id);
  const refreshed = (await (await f.rpc('events/subscribe', f.params())).json()).result;
  assert.equal(refreshed.id, id);
  assert.deepEqual(f.state().subscriptions.find(value => value.id === id), legacy);
  assert.equal((await f.request('/hint', hint)).status, 200);
});
