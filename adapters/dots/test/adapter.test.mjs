import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, writeFile, rm, cp, readdir} from 'node:fs/promises';
import {join} from 'node:path';
import {execFile, spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {createServer} from 'node:http';
import {Adapter} from '../adapter.mjs';
import {fixture, id, pointer, source, token, secret} from './fixture.mjs';

test('once exits quiet from an empty local spool without receiver traffic', async t => {
  const f = await fixture(t);
  const config = join(f.root, 'adapter.json');
  await writeFile(config, JSON.stringify({...f.config, receiver: 'http://127.0.0.1:1', token: undefined}));
  await writeFile(join(f.root, 'quiet'), '');
  const result = await promisify(execFile)(process.execPath,
    [new URL('../adapter.mjs', import.meta.url).pathname, 'once', config],
    {env: {...process.env, TINRELAY_DOTS_TOKEN: token}, timeout: 2000});
  assert.deepEqual(JSON.parse(result.stdout), {state: 'quiet'});
  assert.equal(result.stderr, '');
  const calls = (await readFile(join(f.root, 'calls'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert.deepEqual(calls, [['radio', 'poll', '--local', '--ship', 'receiver']]);
  await assert.rejects(readFile(join(f.root, 'routed')));
});

test('run keeps the local wait and aborts it without manufacturing a quiet result or numeric code',
  {timeout: 3000}, async t => {
  const f = await fixture(t);
  const config = join(f.root, 'adapter.json');
  await writeFile(config, JSON.stringify({...f.config, receiver: 'http://127.0.0.1:1', token: undefined}));
  await writeFile(join(f.root, 'quiet'), '');
  const child = spawn(process.execPath, [new URL('../adapter.mjs', import.meta.url).pathname, 'run', config],
    {env: {...process.env, TINRELAY_DOTS_TOKEN: token}});
  t.after(() => {if (child.exitCode === null) child.kill('SIGTERM');});
  let output = '', error = '';
  child.stdout.on('data', bytes => {output += bytes;});
  child.stderr.on('data', bytes => {error += bytes;});
  const completion = new Promise((resolve, reject) => {
    child.once('close', resolve);
    child.once('error', reject);
  });
  let calls;
  for (let attempt = 0; attempt < 100; attempt++) {
    try {calls = JSON.parse((await readFile(join(f.root, 'calls'), 'utf8')).trim()); break;}
    catch (failure) {if (failure.code !== 'ENOENT') throw failure;}
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.deepEqual(calls, ['radio', 'wait', '--local', '--ship', 'receiver']);
  child.kill('SIGTERM');
  assert.equal(await completion, 1);
  assert.equal(output, '');
  assert.deepEqual(JSON.parse(error), {error: 'dots_adapter_stopped', phase: 'select'});
});

test('failure diagnostics identify only the phase and observed numeric codes', async t => {
  for (const [phase, marker, exitCode] of [
    ['select', 'blocked', 10], ['inspect', 'fail-inspect', 13],
    ['deliver', null, null], ['route', 'fail-route', 11],
  ]) {
    const f = await fixture(t);
    if (marker) await writeFile(join(f.root, marker), '');
    const server = createServer((request, response) => {
      response.setHeader('Connection', 'close');
      response.writeHead(phase === 'deliver' ? 401 : 200, {'Content-Type': 'application/json'});
      response.end(phase === 'deliver' ? JSON.stringify({private: [token, secret, source]}) :
        JSON.stringify({event_id: `tinrelay:receiver:transmission:${id}`, state: 'received'}));
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const config = join(f.root, 'adapter.json');
    await writeFile(config, JSON.stringify({...f.config,
      receiver: `http://127.0.0.1:${server.address().port}`, token: undefined}));
    let failure;
    try {
      await promisify(execFile)(process.execPath,
        [new URL('../adapter.mjs', import.meta.url).pathname, 'once', config],
        {env: {...process.env, TINRELAY_DOTS_TOKEN: token}, timeout: 3000});
    } catch (error) {failure = error;}
    assert.equal(failure.code, 1);
    assert.equal(failure.stdout, '');
    const expected = {error: 'dots_adapter_stopped', phase};
    if (exitCode !== null) expected.exit_code = exitCode;
    if (phase === 'deliver') expected.http_status = 401;
    assert.deepEqual(JSON.parse(failure.stderr), expected);
    await assert.rejects(readFile(join(f.root, 'routed')));
  }
});

test('confirmed platform callback receipt routes the exact source without model handling', async t => {
  const f = await fixture(t);
  await f.rpc('events/subscribe', f.params());
  assert.equal((await f.adapter().once()).state, 'routed');
  assert.equal(await readFile(join(f.root, 'routed'), 'utf8'), id);
  const event = JSON.parse(f.callbacks.at(-1).body);
  assert.equal(event.eventId, `tinrelay:receiver:transmission:${id}`);
  assert.equal(event.data.body, source.signed_transmission.body);
  assert.equal(event.data.classification, 'untrusted_external');
  assert.equal(event.data.author_label, null);
  assert.equal(event.timestamp, new Date(source.received_at * 1000).toISOString());
  assert.equal(f.subscriptions.objects.size, 1);
  assert.ok(!JSON.stringify(f.state()).includes(source.signed_transmission.body));
});

test('native anonymous exports with an omitted signed author deliver as anonymous', async t => {
  const f = await fixture(t);
  const anonymous = structuredClone(source);
  delete anonymous.signed_transmission.from_label;
  await writeFile(join(f.root, 'source.json'), JSON.stringify(anonymous));
  await f.rpc('events/subscribe', f.params());
  assert.equal((await f.adapter().once()).state, 'routed');
  assert.equal(await readFile(join(f.root, 'routed'), 'utf8'), id);
  const event = JSON.parse(f.callbacks.at(-1).body);
  assert.equal(event.data.author_label, null);
  assert.equal(event.data.body, anonymous.signed_transmission.body);
});

test('present signed authors must still match the verified export', async t => {
  for (const author of [null, '', 'sender-agent']) {
    const f = await fixture(t);
    const authored = structuredClone(source);
    authored.author_label = authored.signed_transmission.from_label = author;
    await writeFile(join(f.root, 'source.json'), JSON.stringify(authored));
    await f.rpc('events/subscribe', f.params());
    assert.equal((await f.adapter().once()).state, 'routed');
    assert.equal(JSON.parse(f.callbacks.at(-1).body).data.author_label, author);
    authored.author_label = author === null ? 'sender-agent' : null;
    await writeFile(join(f.root, 'source.json'), JSON.stringify(authored));
    const callbacks = f.callbacks.length;
    await assert.rejects(f.adapter().once(), /invalid_tinrelay_output/);
    assert.equal(f.callbacks.length, callbacks);
  }
});

test('ingress 200 without a matching callback never routes the source', async t => {
  const f = await fixture(t);
  assert.equal((await f.adapter().once()).state, 'pending');
  await f.rpc('events/subscribe', f.params('other'));
  assert.equal((await f.adapter().once()).state, 'pending');
  await assert.rejects(readFile(join(f.root, 'routed')));
  assert.equal(f.callbacks.length, 1); // Only the subscription challenge.
});

test('lost callback or ingress response retries the same exact event across restart', async t => {
  for (const lost of ['callback', 'ingress']) {
    const f = await fixture(t);
    await f.rpc('events/subscribe', f.params());
    const adapter = f.adapter();
    if (lost === 'callback') f.behavior(() => {throw Error('lost callback response');});
    else {
      const send = adapter.send;
      adapter.send = async (...args) => {await send(...args); throw Error('lost ingress response');};
    }
    await assert.rejects(adapter.once());
    await assert.rejects(readFile(join(f.root, 'routed')));
    const original = f.callbacks.at(-1);
    f.restart();
    f.advance(1000);
    f.behavior(undefined);
    assert.equal((await f.adapter().once()).state, 'routed');
    const retry = f.callbacks.at(-1);
    assert.equal(retry.body, original.body);
    assert.equal(retry.headers['webhook-id'], original.headers['webhook-id']);
    assert.notEqual(retry.headers['webhook-timestamp'], original.headers['webhook-timestamp']);
  }
});

test('uncertain source-routing completion leaves the immutable source retryable', async t => {
  const f = await fixture(t);
  await f.rpc('events/subscribe', f.params());
  await writeFile(join(f.root, 'fail-route'), '');
  await assert.rejects(f.adapter().once());
  f.restart();
  await rm(join(f.root, 'fail-route'));
  assert.equal((await f.adapter().once()).state, 'routed');
  const events = f.callbacks.filter(call => JSON.parse(call.body).name);
  assert.equal(events.length, 2); // At-least-once, not an invented exactly-once ledger.
  assert.equal(events[0].body, events[1].body);
});

test('a replacement callback can receive the same pending source after an uncertain receipt', async t => {
  const f = await fixture(t);
  const old = f.params();
  await f.rpc('events/subscribe', old);
  f.behavior(() => {throw Error('received but response lost');});
  await assert.rejects(f.adapter().once());
  const first = f.callbacks.at(-1);
  await f.rpc('events/unsubscribe', old);
  f.behavior(undefined);
  await f.rpc('events/subscribe', f.params('steward', 'https://callback.example/new'));
  assert.equal((await f.adapter().once()).state, 'routed');
  assert.equal(f.callbacks.at(-1).url, 'https://callback.example/new');
  assert.equal(f.callbacks.at(-1).body, first.body);
});

test('transient callbacks retain the source; terminal 410/413 stop that subscription', async t => {
  for (const status of [503, 403, 410, 413]) {
    const f = await fixture(t);
    await f.rpc('events/subscribe', f.params());
    f.behavior(() => new Response(null, {status}));
    if (status === 503) assert.equal((await f.adapter().once()).state, 'pending');
    else {
      await assert.rejects(f.adapter().once(), /callback_refused/);
      assert.equal(f.state().subscriptions.length, status === 403 ? 1 : 0);
    }
    await assert.rejects(readFile(join(f.root, 'routed')));
  }
});

test('wrong ship, repeated signed facts, and unsupported evidence fail before forwarding', async t => {
  const f = await fixture(t);
  const changed = structuredClone(source);
  changed.signed_transmission.to_label = 'other';
  await writeFile(join(f.root, 'source.json'), JSON.stringify(changed));
  await assert.rejects(f.adapter().once());
  await writeFile(join(f.root, 'pointer.json'), JSON.stringify({...pointer, kind: 'hail'}));
  await assert.rejects(f.adapter().once(), /non_transmission/);
  await writeFile(join(f.root, 'blocked'), '');
  await assert.rejects(f.adapter().once());
  assert.equal(f.callbacks.length, 0);
  await assert.rejects(f.adapter().event(pointer));
});

test('exact-source guard stops before reading unrelated correspondence', async t => {
  const f = await fixture(t);
  await writeFile(join(f.root, 'pointer.json'), JSON.stringify({...pointer, name: 'other'}));
  await assert.rejects(f.adapter({expectedSourceId: id, expectedAttention: 'steward'}).once(),
    /unexpected_source/);
  const calls = (await readFile(join(f.root, 'calls'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert.deepEqual(calls.map(args => args.slice(0, 2)), [['radio', 'wait']]);
});

test('large retained public evidence does not truncate the selected verified source', async t => {
  const f = await fixture(t);
  await writeFile(join(f.root, 'source.json'), JSON.stringify({...source,
    retained_owner_chain: 'synthetic-public-evidence'.repeat(20_000)}));
  await f.rpc('events/subscribe', f.params());
  assert.equal((await f.adapter().once()).state, 'routed');
  assert.equal(JSON.parse(f.callbacks.at(-1).body).data.body, source.signed_transmission.body);
});

test('configuration/CLI failure diagnostics expose neither body nor credential', async t => {
  const f = await fixture(t);
  const config = join(f.root, 'adapter.json');
  await writeFile(config, JSON.stringify({...f.config, token: undefined}));
  await writeFile(join(f.root, 'blocked'), '');
  let failure;
  try {
    await promisify(execFile)(process.execPath,
      [new URL('../adapter.mjs', import.meta.url).pathname, 'once', config],
      {env: {...process.env, TINRELAY_DOTS_TOKEN: token}});
  } catch (error) {failure = error;}
  assert.equal(failure.stdout, '');
  assert.ok(failure.stderr.length < 200);
  for (const value of [token, secret, source.signed_transmission.body]) {
    assert.ok(!failure.stderr.includes(value));
  }
  assert.throws(() => new Adapter({...f.config, receiver: 'https://private:credential@host.example'}));
});

test('fresh receiver build is dependency-free Worker ESM with the supplied platform binding', async t => {
  const f = await fixture(t);
  const manifest = join(f.root, 'hosting.json');
  await writeFile(manifest, JSON.stringify({project_id: 'synthetic-build-only',
    d1: null, r2: 'SUBSCRIPTIONS', capabilities: ['mcp']}));
  const checkout = join(f.root, 'fresh-receiver');
  await cp(new URL('../receiver/', import.meta.url), checkout, {recursive: true});
  const output = join(f.root, 'dist');
  await promisify(execFile)(process.execPath, [join(checkout, 'build.mjs'), manifest, output]);
  assert.equal(typeof (await import(join(output, 'server/index.js'))).default.fetch, 'function');
  assert.deepEqual((await readdir(join(output, 'server'))).sort(), ['event.mjs', 'index.js']);
  assert.equal(JSON.parse(await readFile(join(output, '.openai/hosting.json'))).project_id,
    'synthetic-build-only');
});
