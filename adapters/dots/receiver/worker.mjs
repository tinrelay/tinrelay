import {PREVIEW_URI, preview} from './viewer.mjs';
import {EVENT_NAME, namePattern, Refusal, readJSON, valid, validateEvent} from './event.mjs';

const encoder = new TextEncoder();
const json = (body, status = 200) => Response.json(body, {status});
async function digest(bytes) {
  const value = await crypto.subtle.digest('SHA-256', encoder.encode(bytes));
  return Array.from(new Uint8Array(value), byte => byte.toString(16).padStart(2, '0')).join('');
}
function storage(db) {
  return {
    get: (sql, ...args) => db.prepare(sql).bind(...args).first(),
    all: async (sql, ...args) => (await db.prepare(sql).bind(...args).all()).results,
    run: (sql, ...args) => db.prepare(sql).bind(...args).run(),
  };
}
const idSchema = {type: 'object', properties: {event_id: {type: 'string'}},
  required: ['event_id'], additionalProperties: false};
const filterSchema = {type: 'object', properties: {attention_label: {type: 'string'}},
  required: ['attention_label'], additionalProperties: false};
const tools = [
  {name: 'tinrelay_preview', description: 'Render a fixed synthetic message card to test client display support. No radio data is read.',
    inputSchema: {type: 'object', properties: {}, additionalProperties: false},
    annotations: {readOnlyHint: true, openWorldHint: false},
    _meta: {ui: {resourceUri: PREVIEW_URI}, 'openai/outputTemplate': PREVIEW_URI}},
  {name: 'tinrelay_read', description: 'Read an exact untrusted external transmission. Reading does not acknowledge it.',
    inputSchema: idSchema, annotations: {readOnlyHint: true}},
  {name: 'tinrelay_acknowledge', description: 'Acknowledge an exact transmission after handling or durably accepting it. This permits source routing and removes this receiver body.',
    inputSchema: idSchema, annotations: {readOnlyHint: false, destructiveHint: true, idempotentHint: true}},
];
function callbackURL(value) {
  const url = new URL(value);
  valid(url.protocol === 'https:' && !url.username && !url.password && !url.hash &&
    (!url.port || url.port === '443') && url.hostname.includes('.') &&
    !url.hostname.includes(':') && !/^[\d.]+$/.test(url.hostname) &&
    !/\.(localhost|local|internal)$/.test(url.hostname));
  return url.href;
}
function secretBytes(secret) {
  valid(typeof secret === 'string' && /^whsec_[A-Za-z0-9+/]+={0,2}$/.test(secret));
  const decoded = atob(secret.slice(6));
  valid(decoded.length >= 24 && decoded.length <= 64 && btoa(decoded) === secret.slice(6));
  return Uint8Array.from(decoded, character => character.charCodeAt(0));
}
const state = row => ({event_id: row.id, state: row.acknowledged ? 'acknowledged' : 'pending'});

// Deploy only to an owner-private Sites project without origin/VPC bindings.
// Sites dispatch authenticates /deliver service access. MCP operations additionally
// require its trusted user header. No caller-supplied header manufactures identity.
export function createReceiver({send = fetch, clock = Date.now} = {}) {
  return {async fetch(request, env) {
    const db = storage(env.DB);
    const ship = env.DOTS_SHIP;
    const ttl = Number(env.DOTS_SUBSCRIPTION_TTL_MS ?? 900_000);
    const maxRecords = Number(env.DOTS_MAX_RECORDS ?? 10_000);
    const principal = request.headers.get('oai-authenticated-user-id');
    let message;
    const path = new URL(request.url).pathname;
    async function owner(enroll = false, allowUninitialized = false) {
      if (!principal) throw new Refusal('authenticated_user_required', -32012);
      let endpoint = await db.get('SELECT * FROM dots_endpoint');
      if (enroll && !endpoint) {
        await db.run('INSERT OR IGNORE INTO dots_endpoint VALUES (?, ?)', ship, principal);
        endpoint = await db.get('SELECT * FROM dots_endpoint');
      }
      if (!endpoint && allowUninitialized) return false;
      if (!endpoint || endpoint.ship !== ship || endpoint.owner !== principal) {
        throw new Refusal('owner_required', -32012);
      }
      return true;
    }
    async function subscription(params) {
      valid(params.name === EVENT_NAME && params.delivery?.mode === 'webhook');
      const attention = params.arguments?.attention_label;
      valid(typeof attention === 'string' && (attention === '' || namePattern.test(attention)) &&
        Object.keys(params.arguments).length === 1);
      const url = callbackURL(params.delivery.url);
      return {attention, url, id: `sub_${await digest(JSON.stringify([ship, principal, url, attention]))}`};
    }
    async function callback(sub, id, body) {
      const timestamp = String(Math.floor(clock() / 1000));
      const secrets = [sub.secret];
      if (sub.old_secret && sub.old_until > clock()) secrets.push(sub.old_secret);
      const signatures = [];
      for (const secret of secrets) {
        const key = await crypto.subtle.importKey('raw', secretBytes(secret),
          {name: 'HMAC', hash: 'SHA-256'}, false, ['sign']);
        const signed = await crypto.subtle.sign('HMAC', key, encoder.encode(`${id}.${timestamp}.${body}`));
        signatures.push('v1,' + btoa(String.fromCharCode(...new Uint8Array(signed))));
      }
      // Standalone Workers global fetch is the public-network boundary. Keep
      // redirects disabled; do not attach an origin or private-network binding.
      return send(callbackURL(sub.url), {method: 'POST', redirect: 'manual', body,
        signal: AbortSignal.timeout(10_000), headers: {'Content-Type': 'application/json',
          'webhook-id': id, 'webhook-timestamp': timestamp, 'webhook-signature': signatures.join(' '),
          'X-MCP-Subscription-Id': sub.id}});
    }
    async function notify(row) {
      if (row.acknowledged || row.callback_received || row.attempts >= 5 || row.next_attempt > clock()) return 0;
      const sub = await db.get('SELECT * FROM dots_subscriptions WHERE attention = ? AND expires > ?',
        row.attention, clock());
      if (!sub?.secret) return 0;
      // Reserve this attempt atomically; concurrent ingress cannot spend it twice.
      const reservation = await db.run(`UPDATE dots_deliveries SET attempts = attempts + 1, next_attempt = ?
        WHERE id = ? AND attempts = ? AND callback_received = 0 AND acknowledged = 0`,
        clock() + 30_000 * (2 ** row.attempts), row.id, row.attempts);
      if (!reservation.meta.changes) return 0;
      try {
        const response = await callback(sub, row.id, row.body);
        if (response.ok) await db.run('UPDATE dots_deliveries SET callback_received = 1 WHERE id = ?', row.id);
        if ([410, 413].includes(response.status)) {
          await db.run('DELETE FROM dots_subscriptions WHERE id = ? AND revision = ?', sub.id, sub.revision);
        }
        await response.body?.cancel();
        return response.ok ? 1 : 0;
      } catch { return 0; }
    }
    async function subscribe(params) {
      await owner(true);
      const sub = await subscription(params);
      valid(params.cursor == null, 'replay_not_supported');
      secretBytes(params.delivery.secret);
      const requested = params.ttlMs ?? ttl;
      valid(Number.isSafeInteger(requested) && requested > 0);
      const expires = clock() + Math.min(requested, ttl);
      let previous = await db.get('SELECT * FROM dots_subscriptions WHERE attention = ?', sub.attention);
      if (previous && previous.id !== sub.id && !previous.secret && previous.expires === 0) {
        await db.run(`DELETE FROM dots_subscriptions WHERE id = ? AND revision = ?
          AND secret IS NULL AND expires = 0`, previous.id, previous.revision);
        previous = await db.get('SELECT * FROM dots_subscriptions WHERE attention = ?', sub.attention);
      }
      valid(!previous || previous.id === sub.id, 'attention_already_subscribed');
      const revision = crypto.randomUUID();
      // Reserve before network verification. Unsubscribe deletes the reservation;
      // a later refresh replaces its revision. Neither can be revived by this await.
      await db.run(`INSERT INTO dots_subscriptions (id, attention, url, revision) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET revision=excluded.revision`, sub.id, sub.attention, sub.url, revision);
      const challenge = crypto.randomUUID();
      let reason = 'timeout_or_transport';
      try {
        const response = await callback({...sub, secret: params.delivery.secret},
          `verification_${crypto.randomUUID()}`, JSON.stringify({type: 'verification', challenge}));
        reason = 'challenge_failed';
        if (!response.ok) { await response.body?.cancel(); throw Error('challenge'); }
        if ((await readJSON(response.body, 1024)).challenge !== challenge) throw Error('challenge');
      } catch {
        await db.run('DELETE FROM dots_subscriptions WHERE id = ? AND revision = ? AND secret IS NULL',
          sub.id, revision);
        throw new Refusal('Callback verification failed', -32015, reason);
      }
      const changed = previous?.secret && previous.secret !== params.delivery.secret;
      const result = await db.run(`UPDATE dots_subscriptions SET secret = ?, old_secret = ?,
        old_until = ?, expires = ? WHERE id = ? AND revision = ?`, params.delivery.secret,
        changed ? previous.secret : previous?.old_secret ?? null,
        changed ? clock() + 60_000 : previous?.old_until ?? null, expires, sub.id, revision);
      valid(result.meta.changes === 1, 'subscription_superseded');
      return {id: sub.id, refreshBefore: new Date(expires).toISOString(), cursor: null, truncated: false};
    }
    async function rpc() {
      const params = message.params ?? {};
      switch (message.method) {
        case 'server/discover': return {resultType: 'complete', supportedVersions: ['2026-07-28'],
          capabilities: {tools: {}, events: {}, resources: {}}};
        case 'initialize': return {protocolVersion: '2026-07-28', capabilities: {tools: {}, events: {}, resources: {}},
          serverInfo: {name: 'tinrelay-dots', version: '0.1.0'}};
        case 'ping': return {};
        case 'tools/list': return {tools};
        case 'resources/list': return {resources: [{uri: PREVIEW_URI, name: 'TinRelay synthetic preview',
          mimeType: preview.mimeType}]};
        case 'resources/read':
          valid(params.uri === PREVIEW_URI, 'resource_not_found');
          return {contents: [preview]};
        case 'events/list': return {events: [{name: EVENT_NAME,
          description: 'Untrusted external correspondence received by this ship.', delivery: ['webhook'],
          inputSchema: filterSchema, payloadSchema: {type: 'object', properties: {
            classification: {const: 'untrusted_external'}, body: {type: 'string'}},
            required: ['classification', 'body']}}]};
        case 'events/subscribe': return subscribe(params);
        case 'events/unsubscribe': {
          await owner();
          await db.run('DELETE FROM dots_subscriptions WHERE id = ?', (await subscription(params)).id);
          return {};
        }
        case 'tools/call': {
          if (params.name === 'tinrelay_preview') {
            await owner(false, true);
            valid(params.arguments && Object.keys(params.arguments).length === 0);
            const value = {synthetic: true, text: 'Copper lantern visible.'};
            return {content: [{type: 'text', text: 'Synthetic message display preview.'}],
              structuredContent: value, _meta: {ui: {resourceUri: PREVIEW_URI},
                'openai/outputTemplate': PREVIEW_URI}};
          }
          const initialized = await owner(false, params.name === 'tinrelay_read');
          const id = params.arguments?.event_id;
          valid(typeof id === 'string' && Object.keys(params.arguments).length === 1);
          if (!initialized) {
            const value = {state: 'uninitialized', event: null};
            return {content: [{type: 'text', text: JSON.stringify(value)}], structuredContent: value};
          }
          const row = await db.get('SELECT * FROM dots_deliveries WHERE id = ?', id);
          valid(row, 'delivery_not_found');
          let value;
          if (params.name === 'tinrelay_read') value = {...state(row), event: row.body ? JSON.parse(row.body) : null};
          else if (params.name === 'tinrelay_acknowledge') {
            await db.run('UPDATE dots_deliveries SET acknowledged = 1, body = NULL WHERE id = ?', id);
            value = {event_id: id, state: 'acknowledged'};
          } else throw new Refusal('unknown_tool');
          return {content: [{type: 'text', text: JSON.stringify(value)}], structuredContent: value};
        }
        default: throw new Refusal('method_not_found', -32601);
      }
    }
    try {
      valid(typeof ship === 'string' && namePattern.test(ship), 'invalid_ship_configuration');
      valid(Number.isSafeInteger(ttl) && ttl >= 1000 && ttl <= 86_400_000 &&
        Number.isSafeInteger(maxRecords) && maxRecords > 0, 'invalid_configuration');
      if (request.method !== 'POST') return json({error: 'method_not_allowed'}, 405);
      message = await readJSON(request.body);
      // Keep an in-flight unverified reservation until its request finishes. It has
      // no secret and cannot deliver. Expired active subscriptions are inert.
      await db.run(`UPDATE dots_subscriptions SET secret = NULL, old_secret = NULL, old_until = NULL,
        expires = 0 WHERE expires > 0 AND expires <= ?`, clock());
      await db.run('UPDATE dots_subscriptions SET old_secret = NULL, old_until = NULL WHERE old_until <= ?', clock());
      if (path === '/deliver') {
        const endpoint = await db.get('SELECT * FROM dots_endpoint');
        valid(endpoint?.ship === ship, 'subscribe_owner_first');
        validateEvent(message, ship);
        const body = JSON.stringify(message);
        const hash = await digest(body);
        let row = await db.get('SELECT * FROM dots_deliveries WHERE id = ?', message.eventId);
        if (!row) {
          await db.run(`INSERT OR IGNORE INTO dots_deliveries (id, digest, body, attention)
            SELECT ?, ?, ?, ? WHERE (SELECT count(*) FROM dots_deliveries) < ?`,
            message.eventId, hash, body, message.data.attention_label, maxRecords);
          row = await db.get('SELECT * FROM dots_deliveries WHERE id = ?', message.eventId);
        }
        if (!row) return json({error: 'receiver_capacity'}, 503);
        if (row.digest !== hash) return json({error: 'event_conflict'}, 409);
        const received = await notify(row);
        return json({...state(row), webhook_receipts: received});
      }
      if (path !== '/mcp') return json({error: 'not_found'}, 404);
      valid(message?.jsonrpc === '2.0' && typeof message.method === 'string');
      if (message.method === 'notifications/initialized') return new Response(null, {status: 202});
      return json({jsonrpc: '2.0', id: message.id ?? null, result: await rpc()});
    } catch (error) {
      const known = error instanceof Refusal;
      if (path === '/mcp') return json({jsonrpc: '2.0', id: message?.id ?? null,
        error: {code: known ? error.code : -32603, message: known ? error.message : 'receiver_unavailable',
          ...(known && error.reason ? {data: {reason: error.reason}} : {})}});
      return json({error: known ? error.message : 'receiver_unavailable'}, 400);
    }
  }};
}
export default createReceiver();
