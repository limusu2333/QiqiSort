#!/usr/bin/env python3
"""Stream a complete, prepared research runtime into GitHub-sized ZIP pieces.
Usage: python3 distribution/package_release.py PREPARED_BUILD OUTPUT_DIR
PREPARED_BUILD has resources-copy/, runtime-copy/, and root notice/launch files.
"""
from pathlib import Path
import os,stat,sys,hashlib,json,zipfile
build=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True)
ROOT='七七理片研究版'; LIMIT=1800_000_000
class Pieces:
 def __init__(self):self.pos=0;self.items=[];self.file=None;self.count=0;self.hash=None;self.full=hashlib.sha256()
 def tell(self):return self.pos
 def seekable(self):return False
 def seek(self,*a):raise OSError('non-seekable')
 def flush(self):
  if self.file:self.file.flush()
 def finish_piece(self):
  if self.file:
   self.file.close();self.items.append({'name':self.path.name,'size':self.count,'sha256':self.hash.hexdigest()});self.file=None
 def write(self,data):
  length=len(data);self.full.update(data)
  while data:
   if self.file is None:
    self.path=out/f'QiqiSort-Research-data.zip.{len(self.items)+1:03}';self.file=self.path.open('wb');self.count=0;self.hash=hashlib.sha256()
   piece=data[:LIMIT-self.count];self.file.write(piece);self.hash.update(piece);self.count+=len(piece);self.pos+=len(piece);data=data[len(piece):]
   if self.count==LIMIT:self.finish_piece()
  return length
stream=Pieces();unpacked=0;files=0
with zipfile.ZipFile(stream,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=1,allowZip64=True)as z:
 paths=[]
 for name,folder in [('resources','resources-copy'),('runtime','runtime-copy')]:
  for p in sorted((build/folder).rglob('*')):
   rel=p.relative_to(build/folder)
   if '.DS_Store' in p.parts or any(v.startswith('._')for v in p.parts):continue
   if name=='resources'and (str(rel).startswith('models/fusion-seed-perception/')or str(rel).startswith('models/visual-memory/MobileCLIP.mlmodelc/')):continue
   if not(p.is_file()or p.is_symlink()):continue
   paths.append((p,f'{ROOT}/原项目/{name}/{rel.as_posix()}'))
 for name in ['LICENSE','THIRD_PARTY_NOTICES.md','启动.command','启动说明.md']:
  paths.append((build/name,f'{ROOT}/{name}'))
 paths.append((build/'project-launch.command',f'{ROOT}/原项目/启动.command'))
 for p,dest in paths:
  info=zipfile.ZipInfo.from_file(p,arcname=dest);info.create_system=3;info.compress_type=zipfile.ZIP_DEFLATED
  if p.is_symlink():
   value=os.readlink(p).encode();info.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(info,value)
  else:
   unpacked+=p.stat().st_size
   with p.open('rb')as src,z.open(info,'w',force_zip64=True)as target:
    while chunk:=src.read(4*1024*1024):target.write(chunk)
  files+=1
stream.finish_piece()
exe=build/'runtime-copy/七七整理台'
manifest={'version':1,'tag':'research-2026-11-24','repository':'limusu2333/QiqiSort','rootFolder':ROOT,'executable':'原项目/runtime/七七整理台','executableSHA256':hashlib.sha256(exe.read_bytes()).hexdigest(),'archiveSize':stream.pos,'archiveSHA256':stream.full.hexdigest(),'unpackedSize':unpacked,'fileCount':files,'parts':stream.items}
(out/'release-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(manifest,ensure_ascii=False,indent=2))
