export const sourceIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export const EVENT_NAME = 'tinrelay.transmission.received';
export const MAIL_EVENT_NAME = 'tinrelay.mail.pending';
export const MAIL_CONTRACT = 'tinrelay-mail-hint-v1';
export const namePattern = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
export class Refusal extends Error {
  constructor(message, code = -32602, reason) {super(message); this.code = code; this.reason = reason;}
}
export const valid = (condition, message = 'invalid_request') => {
  if (!condition) throw new Refusal(message);
};

export async function readJSON(stream, limit = 96 * 1024) {
  const reader = stream?.getReader();
  valid(reader);
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      size += value.length;
      valid(size <= limit, 'request_too_large');
      chunks.push(value);
    }
    return JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(new Uint8Array(chunks.flatMap(chunk => Array.from(chunk)))));
  } finally { await reader.cancel(); }
}

export function validateEvent(event, ship) {
  const data = event?.data;
  valid(event?.name === EVENT_NAME && event.cursor === null && data?.kind === 'transmission');
  valid(data.contract === 'tinrelay-message-delivery-v2' && data.local_ship === ship);
  valid(typeof data.transmission_id === 'string' &&
    sourceIdPattern.test(data.transmission_id));
  valid(event.eventId === `tinrelay:${ship}:transmission:${data.transmission_id}`);
  valid(typeof data.sender_ship === 'string' && namePattern.test(data.sender_ship) && typeof data.attention_label === 'string' &&
    (data.attention_label === '' || namePattern.test(data.attention_label)));
  valid(data.author_label === null || (typeof data.author_label === 'string' &&
    (data.author_label === '' || namePattern.test(data.author_label))));
  valid(data.classification === 'untrusted_external' && typeof data.body === 'string' &&
    new TextEncoder().encode(data.body).byteLength <= 16 * 1024);
  valid(Number.isSafeInteger(data.received_at) && data.received_at > 0 &&
    event.timestamp === new Date(data.received_at * 1000).toISOString());
  valid(Object.keys(event).sort().join() === 'cursor,data,eventId,name,timestamp');
  valid(Object.keys(data).sort().join() ===
    'attention_label,author_label,body,classification,contract,kind,local_ship,received_at,sender_ship,transmission_id');
  return event;
}

// A hint is only a ship-bound request to collect, never a transmission receipt.
export function mailEvent(hint, ship, now) {
  valid(hint?.contract === MAIL_CONTRACT && hint.local_ship === ship &&
    Object.keys(hint).sort().join() === 'contract,local_ship');
  return {name: MAIL_EVENT_NAME, eventId: `tinrelay:${ship}:hint:${crypto.randomUUID()}`,
    timestamp: new Date(now).toISOString(), cursor: null,
    data: {contract: MAIL_CONTRACT, local_ship: ship, classification: 'untrusted_external'}};
}
