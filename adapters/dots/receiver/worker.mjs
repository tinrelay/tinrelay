import {EVENT_NAME, MAIL_EVENT_NAME, MAIL_CONTRACT, mailEvent, namePattern, Refusal,
  readJSON, valid, validateEvent} from './event.mjs';

const encoder = new TextEncoder();
const json = (body, status = 200) => Response.json(body, {status,
  headers: {'Cache-Control': 'private, no-store'}});
const filterSchema = {type: 'object', properties: {attention_label: {type: 'string'}},
  required: ['attention_label'], additionalProperties: false};

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

// Private Sites dispatch owns OAuth, service access, and the trusted user header.
// Workers global fetch is public-network-only: no origin/private-network binding.
export function createReceiver({send = fetch, clock = Date.now} = {}) {
  return {async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const principal = request.headers.get('oai-authenticated-user-id');
    let message;
    const traceMcp = (result, errorCode) => {
      const knownMethods = ['server/discover', 'initialize', 'notifications/initialized', 'ping',
        'tools/list', 'tools/call', 'events/list', 'events/subscribe', 'events/unsubscribe',
        'resources/list', 'resources/templates/list', 'resources/read', 'prompts/list',
        'prompts/get', 'skills/list', 'logging/setLevel'];
      const method = knownMethods.includes(message?.method) ? message.method : 'unknown';
      const summary = {method, outcome: errorCode === undefined ? 'success' : 'error'};
      if (errorCode !== undefined) summary.error_code = errorCode;
      if (method === 'initialize') {
        const requested = message?.params?.protocolVersion;
        if (typeof requested === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(requested)) {
          summary.requested_protocol_version = requested;
        }
        if (result?.protocolVersion === '2026-07-28') summary.returned_protocol_version = '2026-07-28';
      }
      console.info(JSON.stringify(summary));
    };
    try {
      const ship = env.DOTS_SHIP;
      const ttl = Number(env.DOTS_SUBSCRIPTION_TTL_MS ?? 900_000);
      valid(typeof ship === 'string' && namePattern.test(ship), 'invalid_ship_configuration');
      valid(Number.isSafeInteger(ttl) && ttl >= 1000 && ttl <= 86_400_000, 'invalid_configuration');
      if (request.method !== 'POST') return json({error: 'method_not_allowed'}, 405);
      const mailEnabled = env.DOTS_MAIL_HINTS === 'true';
      if (!['/mcp', '/deliver', ...(mailEnabled ? ['/hint'] : [])].includes(path)) {
        return json({error: 'not_found'}, 404);
      }
      try {message = await readJSON(request.body, path === '/hint' ? 1024 : undefined);} catch (error) {
        if (path === '/hint' && (error instanceof SyntaxError || error instanceof TypeError)) {
          throw new Refusal('invalid_request');
        }
        throw error;
      }
      const key = `tinrelay-dots/${ship}.json`;
      const object = await env.SUBSCRIPTIONS.get(key);
      const state = object ? await object.json() : {owner: null, subscriptions: []};
      const active = state.subscriptions.filter(sub => sub.expires > clock());
      async function save(subscriptions) {
        // Every change has new bytes, including an idempotent unsubscribe. Native
        // conditional writes prevent a late challenge reviving a removed callback.
        return env.SUBSCRIPTIONS.put(key, JSON.stringify({owner: state.owner ?? principal,
          revision: crypto.randomUUID(), subscriptions}), {
          onlyIf: object ? {etagMatches: object.etag} : {etagDoesNotMatch: '*'},
        });
      }
      async function callback(sub, id, body) {
        const timestamp = String(Math.floor(clock() / 1000));
        const secrets = [sub.secret];
        if (sub.old_secret && sub.old_until > clock()) secrets.push(sub.old_secret);
        const signatures = [];
        for (const secret of secrets) {
          const signingKey = await crypto.subtle.importKey('raw', secretBytes(secret),
            {name: 'HMAC', hash: 'SHA-256'}, false, ['sign']);
          const signed = await crypto.subtle.sign('HMAC', signingKey,
            encoder.encode(`${id}.${timestamp}.${body}`));
          signatures.push('v1,' + btoa(String.fromCharCode(...new Uint8Array(signed))));
        }
        return send(callbackURL(sub.url), {method: 'POST', redirect: 'manual', body,
          signal: AbortSignal.timeout(10_000), headers: {'Content-Type': 'application/json',
            'webhook-id': id, 'webhook-timestamp': timestamp, 'webhook-signature': signatures.join(' '),
            'X-MCP-Subscription-Id': sub.id}});
      }
      if (path === '/hint') {
        const event = mailEvent(message, ship, clock());
        const sub = active.find(value => value.event === MAIL_EVENT_NAME);
        if (!sub) return json({state: 'pending'}, 503);
        try {
          const response = await callback(sub, event.eventId, JSON.stringify(event));
          await response.body?.cancel();
          // Receipt only completes this hint attempt. No radio state is accessible here.
          return json({state: response.ok ? 'received' : 'pending'}, response.ok ? 200 : 503);
        } catch {return json({state: 'pending'}, 503);}
      }
      if (path === '/deliver') {
        validateEvent(message, ship);
        const sub = active.find(value => !value.event && value.attention === message.data.attention_label);
        if (!sub) return json({event_id: message.eventId, state: 'pending'});
        const response = await callback(sub, message.eventId, JSON.stringify(message));
        await response.body?.cancel();
        if ([410, 413].includes(response.status)) {
          await save(active.filter(value => value.id !== sub.id));
          return json({event_id: message.eventId, state: 'refused'});
        }
        const retryable = response.status === 408 || response.status === 429 || response.status >= 500;
        return json({event_id: message.eventId,
          state: response.ok ? 'received' : retryable ? 'pending' : 'refused'});
      }
      valid(message?.jsonrpc === '2.0' && typeof message.method === 'string');
      const params = message.params ?? {};
      let result;
      switch (message.method) {
        case 'server/discover': result = {resultType: 'complete', supportedVersions: ['2026-07-28'],
          capabilities: {tools: {}, events: {}}}; break;
        case 'initialize':
          throw new Refusal('initialize is unsupported; use server/discover (MCP 2026-07-28)', -32601);
        case 'notifications/initialized': traceMcp({}); return new Response(null, {status: 202});
        case 'ping': result = {}; break;
        case 'tools/list': result = {ttlMs: 0, cacheScope: 'private',
          tools: []}; break;
        case 'events/list': result = {events: [{name: EVENT_NAME,
          description: 'Untrusted external correspondence received by this ship.', delivery: ['webhook'],
          inputSchema: filterSchema, payloadSchema: {type: 'object', properties: {
            classification: {const: 'untrusted_external'}, body: {type: 'string'}},
            required: ['classification', 'body']}}, ...(mailEnabled ? [{name: MAIL_EVENT_NAME,
          description: 'Untrusted ship-level hint to collect pending radio work; not a receipt.',
          delivery: ['webhook'], inputSchema: {type: 'object',
            properties: {local_ship: {const: ship}}, required: ['local_ship'],
            additionalProperties: false}, payloadSchema: {type: 'object', properties: {
              contract: {const: MAIL_CONTRACT}, local_ship: {const: ship},
              classification: {const: 'untrusted_external'}},
            required: ['contract', 'local_ship', 'classification'], additionalProperties: false}}] : [])]};
          break;
        case 'events/subscribe':
        case 'events/unsubscribe': {
          if (!principal) return json({error: 'authenticated_user_required'}, 401);
          if (state.owner && state.owner !== principal) return json({error: 'owner_required'}, 403);
          const mail = mailEnabled && params.name === MAIL_EVENT_NAME;
          valid((mail || params.name === EVENT_NAME) && params.delivery?.mode === 'webhook');
          const attention = params.arguments?.attention_label;
          if (mail) valid(params.arguments?.local_ship === ship &&
            Object.keys(params.arguments).length === 1);
          else valid(typeof attention === 'string' && (attention === '' || namePattern.test(attention)) &&
            Object.keys(params.arguments).length === 1);
          const matches = value => mail ? value.event === MAIL_EVENT_NAME :
            !value.event && value.attention === attention;
          const url = callbackURL(params.delivery.url);
          const digest = await crypto.subtle.digest('SHA-256',
            encoder.encode(JSON.stringify(mail ? [ship, principal, url, MAIL_EVENT_NAME, ship] :
              [ship, principal, url, attention])));
          const id = 'sub_' + Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
          if (message.method === 'events/unsubscribe') {
            valid(await save(active.filter(sub => sub.id !== id)), 'subscription_changed');
            result = {}; break;
          }
          valid(params.cursor == null, 'replay_not_supported');
          secretBytes(params.delivery.secret);
          const requested = params.ttlMs ?? ttl;
          valid(Number.isSafeInteger(requested) && requested > 0);
          const previous = active.find(matches);
          valid(!previous || previous.id === id,
            mail ? 'ship_already_subscribed' : 'attention_already_subscribed');
          const sub = {id, ...(mail ? {event: MAIL_EVENT_NAME} : {attention}),
            url, secret: params.delivery.secret};
          const challenge = crypto.randomUUID();
          let reason = 'timeout_or_transport';
          try {
            const response = await callback(sub, `verification_${crypto.randomUUID()}`,
              JSON.stringify({type: 'verification', challenge}));
            reason = 'challenge_failed';
            if (!response.ok) {await response.body?.cancel(); throw Error('challenge');}
            if ((await readJSON(response.body, 1024)).challenge !== challenge) throw Error('challenge');
          } catch {throw new Refusal('Callback verification failed', -32015, reason);}
          const expires = clock() + Math.min(requested, ttl);
          const changed = previous && previous.secret !== sub.secret;
          Object.assign(sub, {expires,
            old_secret: changed ? previous.secret : previous?.old_secret ?? null,
            old_until: changed ? clock() + 60_000 : previous?.old_until ?? null});
          valid(await save([...active.filter(value => !matches(value)), sub]),
            'subscription_changed');
          result = {id, refreshBefore: new Date(expires).toISOString(), cursor: null, truncated: false};
          break;
        }
        default: throw new Refusal('method_not_found', -32601);
      }
      result = {resultType: 'complete', ...result};
      traceMcp(result);
      return json({jsonrpc: '2.0', id: message.id ?? null, result});
    } catch (error) {
      const known = error instanceof Refusal;
      if (path === '/mcp') {
        traceMcp(undefined, known ? error.code : -32603);
        return json({jsonrpc: '2.0', id: message?.id ?? null,
        error: {code: known ? error.code : -32603, message: known ? error.message : 'receiver_unavailable',
          ...(known && error.reason ? {data: {reason: error.reason}} : {})}});
      }
      return json({error: known ? error.message : 'receiver_unavailable'}, known ? 400 : 503);
    }
  }};
}
export default createReceiver();
