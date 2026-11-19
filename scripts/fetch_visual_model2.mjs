// Developer-only acquisition. No network or Python dependency in the delivered runtime.
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, existsSync, writeFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {createHash} from 'node:crypto';

const root = resolve(import.meta.dirname, '..');
const revision = '72424e7025436db18f15c3eff6ee8c7c15ad4481';
const codeRevision = '48faa0fea4b08d74188b3841771aca6ff2c92852';
const workspace = resolve(root, '.build/visual-model2');
const download = (url, path) => {
  mkdirSync(dirname(path), {recursive:true});
  if (!existsSync(path)) execFileSync('curl', ['-x','http://127.0.0.1:7890',
    '--retry','2','--connect-timeout','20','--max-time','600','--fail','-L','-sS',url,'-o',path + '.part'],
    {stdio:'inherit'});
  if (!existsSync(path)) execFileSync('mv', [path + '.part', path]);
  const bytes = readFileSync(path);
  return {file:path.slice(root.length + 1),sha256:createHash('sha256').update(bytes).digest('hex'),size:bytes.length};
};
const files = [];
for (const name of ['mobileclip2_s2.pt','config.json','README.md','LICENSE']) {
  files.push(download(`https://huggingface.co/apple/MobileCLIP2-S2/resolve/${revision}/${name}`,
    resolve(workspace,name)));
}
const weights = files.find(item => item.file.endsWith('/mobileclip2_s2.pt'));
if (weights.size !== 398071149 || weights.sha256 !== '37c2d839a856491f2fcc82c40dc28672dbd0907235b4cd4c38dfff6457f0c09f') {
  throw Error('Official MobileCLIP2 weights checksum mismatch');
}
files.push(download(`https://codeload.github.com/apple-aiml-research/ml-mobileclip/tar.gz/${codeRevision}`,
  resolve(workspace,'source.tar.gz')));
const source = resolve(workspace,'source');
mkdirSync(source,{recursive:true});
execFileSync('tar',['-xzf',resolve(workspace,'source.tar.gz'),'--strip-components','1','-C',source]);
for (const name of ['LICENSE','LICENSE_MODELS','ACKNOWLEDGEMENTS']) {
  download(`https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/${codeRevision}/${name}`,
    resolve(root,'resources/licenses/mobileclip2',name));
}
writeFileSync(resolve(workspace,'acquisition.json'),JSON.stringify({
  model:'apple/MobileCLIP2-S2',revision,codeRevision,files
},null,2));
console.log('Pinned MobileCLIP2-S2 source and weights ready');
