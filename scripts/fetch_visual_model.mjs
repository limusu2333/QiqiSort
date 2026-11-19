// Developer-only acquisition. The delivered executable never downloads models.
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, existsSync, writeFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {createHash} from 'node:crypto';
const root = resolve(import.meta.dirname, '..');
const revision = '3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947';
const source = 'fe891c4419ac3576a4d99203d97b1895de7cd205';
const download = (url, path) => {
  mkdirSync(dirname(path), {recursive:true});
  execFileSync('curl', ['-x','http://127.0.0.1:7890','--retry','2','--connect-timeout','20',
    '--max-time','240','--fail','-L','-sS',url,'-o',path], {stdio:'inherit'});
};
const files = [
 ['Manifest.json', null],
 ['Data/com.apple.CoreML/model.mlmodel', '2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b'],
 ['Data/com.apple.CoreML/weights/weight.bin', '6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00']
];
const receipt = [];
for (const [file, expected] of files) {
  const path = resolve(root, '.build/visual-model/mobileclip_s2_image.mlpackage', file);
  if (!existsSync(path)) download(`https://huggingface.co/apple/coreml-mobileclip/resolve/${revision}/mobileclip_s2_image.mlpackage/${file}`,path);
  const bytes = readFileSync(path), sha256 = createHash('sha256').update(bytes).digest('hex');
  if (expected && sha256 !== expected) throw Error('Downloaded checksum mismatch: '+file);
  receipt.push({file,sha256,size:bytes.length});
}
for (const file of ['LICENSE','LICENSE_weights_data','ACKNOWLEDGEMENTS']) {
  download(`https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/${source}/${file}`,
    resolve(root,'resources/licenses/mobileclip-2024',file));
}
mkdirSync(resolve(root,'resources/models/visual-memory'), {recursive:true});
writeFileSync(resolve(root,'resources/models/visual-memory/source.json'),JSON.stringify({
  model:'apple/coreml-mobileclip',variant:'mobileclip_s2_image',revision,licenseSourceRevision:source,
  preprocessing:'official center crop, RGB 256x256; normalization included in exported model',files:receipt
},null,2));
console.log('Verified source model ready');
