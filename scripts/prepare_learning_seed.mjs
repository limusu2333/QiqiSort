import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
const source = JSON.parse(await readFile('.build/visual-model2/features.json', 'utf8'));
const samples = source.rows.filter(row => row.sample.split === 'train').map(row => ({
  id: row.sample.id, category: row.sample.category, embedding: row.embedding,
}));
assert.equal(samples.length, 162);
assert.equal(new Set(samples.map(row => row.id)).size, 162);
const bytes = JSON.stringify({version: 1, encoder: source.encoder, samples});
await writeFile('resources/models/visual-memory/learning-seed.json', bytes, {flag: 'wx'});
console.log(createHash('sha256').update(bytes).digest('hex'));
