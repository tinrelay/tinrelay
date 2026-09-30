#!/usr/bin/env node
import {execFile} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {setTimeout as pause} from 'node:timers/promises';
import {promisify} from 'node:util';
import {pathToFileURL} from 'node:url';
import {EVENT_NAME, readJSON, sourceIdPattern, validateEvent} from './receiver/event.mjs';

const execute = promisify(execFile);
const shipPattern = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const requireValue = condition => { if (!condition) throw Error('invalid_tinrelay_output'); };

export class Adapter {
  constructor(config, {send = fetch, signal} = {}) {
    if (typeof config.ship !== 'string' || !shipPattern.test(config.ship) || typeof config.tinrelay !== 'string' ||
        !config.tinrelay.startsWith('/')) throw Error('invalid_configuration');
    const guarded = config.expectedSourceId !== undefined || config.expectedAttention !== undefined;
    if (guarded && (typeof config.expectedSourceId !== 'string' ||
        !sourceIdPattern.test(config.expectedSourceId) || typeof config.expectedAttention !== 'string' ||
        !(config.expectedAttention === '' || shipPattern.test(config.expectedAttention)))) {
      throw Error('invalid_expected_source');
    }
    const receiver = new URL(config.receiver);
    if (receiver.pathname !== '/' || receiver.search || receiver.hash || receiver.username ||
        receiver.password || !(receiver.protocol === 'https:' ||
          (receiver.protocol === 'http:' && ['127.0.0.1', '[::1]'].includes(receiver.hostname)))) {
      throw Error('invalid_receiver');
    }
    if (typeof config.token !== 'string' || config.token.length < 16) throw Error('missing_receiver_token');
    this.config = config;
    this.receiver = receiver.origin;
    this.send = send;
    this.signal = signal;
  }
  async cli(args) {
    const env = {...process.env};
    // Never inherit Codex's private selector bypass, or forward the receiver credential.
    delete env.TINRELAY_LOCAL_DELIVERY_OWNER;
    delete env.TINRELAY_DOTS_TOKEN;
    const {stdout} = await execute(this.config.tinrelay, [...args, '--ship', this.config.ship],
      {env, signal: this.signal, maxBuffer: args[0] === 'inbox' ? Infinity : 96 * 1024});
    return JSON.parse(stdout);
  }
  async deliver(event) {
    const response = await this.send(this.receiver + '/deliver', {
      method: 'POST', redirect: 'manual',
      signal: this.signal ? AbortSignal.any([this.signal, AbortSignal.timeout(30_000)]) :
        AbortSignal.timeout(30_000),
      headers: {'Content-Type': 'application/json', 'OAI-Sites-Authorization': `Bearer ${this.config.token}`},
      body: JSON.stringify(event),
    });
    if (!response.ok) { await response.body?.cancel(); throw Error('receiver_unavailable'); }
    return readJSON(response.body, 4096);
  }
  async event(pointer) {
    requireValue(pointer.contract === 'tinrelay-radio-wait-v2' && pointer.kind === 'transmission');
    const source = await this.cli(['inbox', 'show', 'transmission', pointer.source_id]);
    requireValue(source.contract === 'tinrelay-inspected-inbox-v2' && source.kind === 'transmission' &&
      source.state === 'pending' && source.transmission_id === pointer.source_id);
    const signed = source.signed_transmission;
    requireValue(signed && signed.transmission_id === pointer.source_id &&
      source.recipient_ship === this.config.ship && signed.recipient_ship === this.config.ship &&
      source.sender_ship === signed.sender_ship && source.attention_label === pointer.name &&
      signed.to_label === pointer.name && source.author_label === signed.from_label);
    const event = {eventId: `tinrelay:${this.config.ship}:transmission:${pointer.source_id}`,
      name: EVENT_NAME, timestamp: new Date(source.received_at * 1000).toISOString(), data: {
        contract: 'tinrelay-message-delivery-v2', kind: 'transmission',
        transmission_id: pointer.source_id, local_ship: this.config.ship,
        received_at: source.received_at, sender_ship: source.sender_ship,
        attention_label: source.attention_label, author_label: source.author_label,
        classification: 'untrusted_external', body: signed.body,
      }, cursor: null};
    return validateEvent(event, this.config.ship);
  }
  async once() {
    const pointer = await this.cli(['radio', 'wait', '--local']);
    if (this.config.expectedSourceId !== undefined &&
        (pointer.kind !== 'transmission' || pointer.source_id !== this.config.expectedSourceId ||
          pointer.name !== this.config.expectedAttention)) {
      throw Error('unexpected_source');
    }
    // Hails and rejected evidence require deliberate local attention. Do not skip
    // or route them to reach a later transmission.
    if (pointer.kind !== 'transmission') throw Error('non_transmission_requires_local_attention');
    const event = await this.event(pointer);
    const receipt = await this.deliver(event);
    requireValue(receipt.event_id === event.eventId &&
      ['pending', 'received', 'refused'].includes(receipt.state));
    if (receipt.state === 'refused') throw Error('callback_refused');
    if (receipt.state === 'pending') return {state: 'pending', event_id: event.eventId};
    const routed = await this.cli(['radio', 'routed', 'transmission', pointer.source_id]);
    requireValue(routed.kind === 'transmission' && routed.source_id === pointer.source_id &&
      routed.state === 'routed');
    return {state: 'routed', event_id: event.eventId};
  }
}

async function main() {
  const [command, path, ...extra] = process.argv.slice(2);
  if (!['once', 'run'].includes(command) || !path || extra.length) {
    throw Error('usage: node adapters/dots/adapter.mjs once|run CONFIG.json');
  }
  const config = JSON.parse(await readFile(path, 'utf8'));
  config.token = process.env.TINRELAY_DOTS_TOKEN;
  const control = new AbortController();
  process.once('SIGINT', () => control.abort());
  process.once('SIGTERM', () => control.abort());
  const adapter = new Adapter(config, {signal: control.signal});
  let attempts = 0;
  do {
    const result = await adapter.once();
    process.stdout.write(JSON.stringify(result) + '\n');
    if (command === 'once') return;
    // Pending means no confirmed platform receipt, not unfinished model handling.
    if (result.state === 'pending') {
      if (++attempts === 5) throw Error('delivery_unconfirmed');
      await pause(30_000 * (2 ** (attempts - 1)), undefined, {signal: control.signal});
    } else attempts = 0;
  } while (!control.signal.aborted);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => {process.stderr.write('Dots adapter stopped; source remains recoverable\n'); process.exitCode = 1;});
}
