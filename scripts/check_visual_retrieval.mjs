import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

const [input, output] = process.argv.slice(2);
assert.ok(input && output, 'Usage: node scripts/check_visual_retrieval.mjs features.json new-receipt.json');
const bytes = await readFile(input);
const data = JSON.parse(bytes);
const train = data.rows.filter(row => row.sample.split === 'train');
const dot = (a, b) => a.reduce((sum, value, index) => sum + value * b[index], 0);
assert.ok(train.length > 0);
const rows = data.rows.filter(row => row.sample.split !== 'train' && row.sample.category).map(row => {
  const scores = train.map(reference => ({ id: reference.sample.id, category: reference.sample.category,
    similarity: dot(row.embedding, reference.embedding) })).sort((a, b) => b.similarity - a.similarity);
  return { id: row.sample.id, split: row.sample.split, expected: row.sample.category,
    nearest: scores[0], correct: scores[0].category === row.sample.category };
});
const splits = [...new Set(rows.map(row => row.split))].map(split => {
  const selected = rows.filter(row => row.split === split);
  const retrieved = selected.filter(row => row.nearest.similarity >= 0.8);
  return { split, total: selected.length, nearestCorrect: selected.filter(row => row.correct).length,
    threshold: 0.8, retrieved: retrieved.length, retrievedCorrect: retrieved.filter(row => row.correct).length };
});
const receipt = { encoder: data.encoder, inputSHA256: createHash('sha256').update(bytes).digest('hex'),
  trainingReferences: train.length, splits, rows,
  note: 'Feature retrieval diagnostic only, not full classification accuracy. Validation and cross samples have already informed development; this is not a fresh blind evaluation.' };
await writeFile(output, JSON.stringify(receipt, null, 2), { flag: 'wx' });
console.log(JSON.stringify(splits, null, 2));
