import test from 'node:test';
import assert from 'node:assert/strict';
import {runInNewContext} from 'node:vm';
import {preview} from '../receiver/viewer.mjs';

test('viewer initializes only with its parent and tears down cleanly', () => {
  const calls = [];
  const listeners = new Map();
  const state = {textContent: ''};
  const parent = {postMessage: (message, target) => calls.push({message, target})};
  const window = {parent, addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name, fn) => {if (listeners.get(name) === fn) listeners.delete(name);}};
  const document = {getElementById: () => state};
  const script = preview.text.match(/<script>([\s\S]+)<\/script>/)[1];
  runInNewContext(script, {window, document});
  assert.equal(calls[0].message.method, 'ui/initialize');
  assert.equal(calls[0].message.params.protocolVersion, '2026-01-26');
  const response = {jsonrpc:'2.0',id:'tinrelay-ui-init',result:{protocolVersion:'2026-01-26'}};
  listeners.get('message')({source:{},data:response});
  assert.equal(calls.length, 1);
  listeners.get('message')({source:parent,data:response});
  assert.equal(calls[1].message.method, 'ui/notifications/initialized');
  listeners.get('message')({source:parent,data:response});
  assert.equal(calls.length, 2);
  listeners.get('message')({source:parent,data:{jsonrpc:'2.0',id:2,method:'ui/resource-teardown'}});
  assert.equal(calls.at(-1).message.id, 2);
  assert.equal(listeners.has('message'), false);
});
