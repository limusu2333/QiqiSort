from pathlib import Path
import zipfile,json,hashlib,subprocess,os,fcntl,shutil,sys,tempfile
# Synthetic payloads test installation safety; they do not measure photo classification.
# Usage: python3 distribution/test_installer.py PATH_TO_NATIVE_LAUNCHER
context=tempfile.TemporaryDirectory(prefix='qiqisort-installer-check-')
root=Path(context.name)
exe=Path(sys.argv[1]).resolve()
payload=b'#!/bin/sh\nexit 0\n';archive=root/'fixture.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED)as z:
 item=zipfile.ZipInfo('七七理片研究版/原项目/runtime/七七整理台');item.external_attr=0o100755<<16;z.writestr(item,payload)
 z.writestr('七七理片研究版/test-data.bin',os.urandom(160000))
data=archive.read_bytes();parts=[]
for i,start in enumerate(range(0,len(data),90000),1):
 blob=data[start:start+90000];name=f'QiqiSort-Research-data.zip.{i:03}';(root/name).write_bytes(blob);parts.append({'name':name,'size':len(blob),'sha256':hashlib.sha256(blob).hexdigest()})
manifest={'version':1,'tag':'installer-fixture','repository':'limusu2333/QiqiSort','rootFolder':'七七理片研究版','executable':'原项目/runtime/七七整理台','executableSHA256':hashlib.sha256(payload).hexdigest(),'archiveSize':len(data),'archiveSHA256':hashlib.sha256(data).hexdigest(),'unpackedSize':len(payload)+160000,'parts':parts}
mp=root/'manifest.json';mp.write_text(json.dumps(manifest));results=[]
def run(name,dest,cache,ok,needle=None,manifest=mp):
 p=subprocess.run([str(exe),'--install-only','--manifest',str(manifest),'--assets-dir',str(root),'--destination',str(dest),'--cache',str(cache)],capture_output=True,text=True)
 assert(p.returncode==0)==ok,(name,p.stdout,p.stderr)
 if needle:assert needle in p.stdout+p.stderr,(name,p.stderr)
 results.append({'check':name,'passed':True})
# A broken local part must never create a runnable destination.
part=root/parts[0]['name'];original=part.read_bytes();part.write_bytes(b'x'+original[1:])
run('损坏分包被拒绝',root/'bad-target',root/'bad-cache',False,'校验不通过');assert not(root/'bad-target').exists();part.write_bytes(original)
# Existing folders are not replaced, even if not a valid application.
existing=root/'existing';existing.mkdir(exist_ok=True);(existing/'keep.txt').write_text('keep')
run('已有目录不会被覆盖',existing,root/'existing-cache',False,'已');assert(existing/'keep.txt').read_text()=='keep'
cache=root/'locked-cache';cache.mkdir(exist_ok=True)
with(cache/'install.lock').open('w')as f:
 fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);run('同版安装互斥锁',root/'locked-target',cache,False,'另一个窗口')
run('合并校验解压与可执行权限',root/'good-target',root/'good-cache',True)
assert(root/'good-target/原项目/runtime/七七整理台').read_bytes()==payload
assert os.access(root/'good-target/原项目/runtime/七七整理台',os.X_OK)
assert not(root/'good-cache/complete.zip').exists()
results.append({'check':'安装成功后清理自有临时包','passed':True})
run('重复启动复用已安装程序',root/'good-target',root/'good-cache',True)
invalid=dict(manifest);invalid['executable']='../wrong';invalidPath=root/'invalid.json';invalidPath.write_text(json.dumps(invalid))
run('无效清单被拒绝',root/'invalid-target',root/'invalid-cache',False,'无效',manifest=invalidPath)
print(json.dumps(results,ensure_ascii=False))
