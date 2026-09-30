export const PREVIEW_URI = 'ui://tinrelay/synthetic-preview-v2.html';
export const preview = {
  uri: PREVIEW_URI,
  mimeType: 'text/html;profile=mcp-app',
  text: `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{margin:0;padding:20px;font:16px system-ui,sans-serif;color:#18302b;background:#f3f8f5}
article{border:1px solid #b7cec1;border-radius:12px;padding:20px;max-width:560px}
h1{font-size:20px;margin:0 0 12px}small{color:#426858}p{line-height:1.5;margin:12px 0 0}</style></head>
<body><article><small>TINRELAY · SYNTHETIC DISPLAY CHECK</small><h1>A message from another ship</h1>
<p>Copper lantern visible. This is fixed preview data, not radio correspondence.</p>
<p>If this card appears, this client can display the receiver's MCP UI resource.</p>
<small id="bridge-state">Waiting for host bridge</small></article>
<script>
(() => {
  const parent = window.parent;
  const state = document.getElementById('bridge-state');
  let initialized = false;
  function receive(event) {
    if (event.source !== parent || event.data?.jsonrpc !== '2.0') return;
    const message = event.data;
    if (message.id === 'tinrelay-ui-init' && !initialized) {
      if (message.error) {state.textContent = 'Host bridge unavailable'; return;}
      if (!message.result || typeof message.result.protocolVersion !== 'string') return;
      initialized = true;
      parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized'}, '*');
      state.textContent = 'MCP Apps bridge connected';
    }
    if (message.method === 'ui/resource-teardown' && message.id !== undefined) {
      parent.postMessage({jsonrpc:'2.0',id:message.id,result:{}}, '*');
      window.removeEventListener('message', receive);
    }
  }
  window.addEventListener('message', receive);
  window.addEventListener('pagehide', () => window.removeEventListener('message', receive), {once:true});
  parent.postMessage({jsonrpc:'2.0',id:'tinrelay-ui-init',method:'ui/initialize',params:{
    protocolVersion:'2026-01-26',appInfo:{name:'TinRelay preview',version:'0.1.0'},
    appCapabilities:{availableDisplayModes:['inline']}}}, '*');
})();
</script></body></html>`,
  _meta: {ui: {prefersBorder: true, csp: {connectDomains: [], resourceDomains: []}}},
};
