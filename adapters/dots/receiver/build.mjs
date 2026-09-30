import {cp, mkdir, readFile} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const manifestPath = process.argv[2] ?? resolve(here, '.openai/hosting.json');
const output = process.argv[3] ?? resolve(here, 'dist');
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
if (!manifest.project_id || manifest.r2 !== 'SUBSCRIPTIONS' || manifest.d1 ||
    !manifest.capabilities?.includes('mcp')) {
  throw Error('registered private MCP manifest required');
}
await mkdir(output, {recursive: true});
await mkdir(resolve(output, 'server'), {recursive: true});
await mkdir(resolve(output, '.openai'), {recursive: true});
await cp(resolve(here, 'worker.mjs'), resolve(output, 'server/index.js'));
await cp(resolve(here, 'event.mjs'), resolve(output, 'server/event.mjs'));
await cp(manifestPath, resolve(output, '.openai/hosting.json'));
console.log('Built Dots receiver');
