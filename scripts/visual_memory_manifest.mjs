import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
const root = resolve(import.meta.dirname,'..');
const dataset = JSON.parse(readFileSync(resolve(root,'training/wedding-20261113/dataset.json')));
const experiment = JSON.parse(readFileSync(resolve(root,'training/wedding-20261113/experiment.json')));
const splits = new Map(experiment.entries.map(item => [item.sourceSHA256,item]));
const rows = dataset.samples.map(item => ({id:'prepared-'+item.sourceSHA256,
  image:resolve(root,'training/wedding-20261113',item.image),category:item.category,
  split:splits.get(item.sourceSHA256).split,album:splits.get(item.sourceSHA256).group}));
const fixture = resolve(root,'.build/wangcheng-20261115');
const sources = JSON.parse(readFileSync(resolve(fixture,'sources.json')));
const labels = JSON.parse(readFileSync(resolve(root,'validation/wangcheng_labels.json')));
for (const [i,item] of sources.entries()) rows.push({id:'wangcheng-'+item.sha256,
  image:resolve(fixture,'input',item.name),category:labels.categories[i],split:'cross-wedding',album:item.album});
writeFileSync(resolve(root,'.build/visual-model2/features-manifest.json'),JSON.stringify(rows,null,2));
console.log(rows.length+' images; prepared train/validation/test splits preserved');
