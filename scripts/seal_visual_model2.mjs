// Developer-only: seal the compiled model with pinned source provenance and file digests.
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import { createHash } from 'node:crypto';
const root = resolve(import.meta.dirname, '..');
const directory = resolve(root, 'resources/models/visual-memory');
const model = 'MobileCLIP2.mlmodelc';
function walk(path) {
  return readdirSync(path, { withFileTypes: true }).flatMap(entry => {
    const file = resolve(path, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`Model symlink: ${file}`);
    return entry.isDirectory() ? walk(file) : [file];
  });
}
const acquisition = JSON.parse(readFileSync(resolve(root, '.build/visual-model2/acquisition.json')));
const parity = JSON.parse(readFileSync(resolve(root, '.build/visual-model2/export-receipt.json')));
const files = walk(resolve(directory, model)).sort().map(file => ({
  path: relative(directory, file), size: statSync(file).size,
  sha256: createHash('sha256').update(readFileSync(file)).digest('hex'),
}));
writeFileSync(resolve(directory, 'mobileclip2-manifest.json'), JSON.stringify({
  version: 1, encoder: 'mobileclip2-s2-72424e70-center256-v1', model,
  source: acquisition, parity, files,
}, null, 2) + '\n');
console.log(`Sealed ${files.length} model files`);
