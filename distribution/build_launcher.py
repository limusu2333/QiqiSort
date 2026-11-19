#!/usr/bin/env python3
"""Build the native macOS research launcher. Requires Swift on the build machine only.
Usage: python3 distribution/build_launcher.py RELEASE_MANIFEST OUTPUT_DIR
"""
from pathlib import Path
import sys,shutil,subprocess,plistlib
source=Path(__file__).resolve().parent;repo=source.parent
manifest=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve();app=out/'七七理片研究版.app'
contents=app/'Contents';binary=contents/'MacOS/QiqiSortLauncher';assets=contents/'Resources'
binary.parent.mkdir(parents=True,exist_ok=True);assets.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-target','arm64-apple-macos14.0',str(source/'ResearchLauncher.swift'),'-o',str(binary)],check=True)
shutil.copy2(manifest,assets/'release-manifest.json');shutil.copy2(repo/'resources/branding/Qiqi.icns',assets/'Qiqi.icns')
info={'CFBundleIdentifier':'com.qiqisort.research.launcher','CFBundleName':'七七理片研究版','CFBundleDisplayName':'七七理片研究版','CFBundleExecutable':'QiqiSortLauncher','CFBundleIconFile':'Qiqi.icns','CFBundlePackageType':'APPL','CFBundleVersion':'2026.11.19','CFBundleShortVersionString':'2026.11.19','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSHumanReadableCopyright':'摄影师七七与李A联合构建，仅供学习研究与技术讨论。'}
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
(out/'先读我.txt').write_text('摄影师七七与李A联合构建 · 七七理片研究版\n\n双击“七七理片研究版.app”，点击“下载并安装研究版”。程序会自动下载、校验和安装完整模型及运行资源，显示进度并支持断点续传。安装完成后可离线运行。无需安装 Python、Xcode 或配置密钥。\n\n需要 Apple 芯片 Mac、macOS 14 及以上，首装约下载 3 GB，建议预留 12 GB 磁盘空间。\n\n如首次被 macOS 拦截：尝试打开后，到“系统设置 → 隐私与安全性”选择“仍要打开”。研究版为本地签名，未做 Apple 公证；无需关闭系统安全检查。\n\n仅供学习研究与技术讨论，禁止商业软件开发及商业产品／服务使用。MobileCLIP2 官方许可仅限非商业科学研究与学术开发，明确排除商业经营、产品开发及商业产品／服务中的使用。\n\n项目与完整说明：https://github.com/limusu2333/QiqiSort\n')
zipfile=out/'QiqiSort-Research-macOS.zip'
# Include a clearly labelled folder so the .app and text stay together after extraction.
folder=out/'七七理片研究版启动器';folder.mkdir(exist_ok=True)
shutil.copytree(app,folder/app.name,dirs_exist_ok=True);shutil.copy2(out/'先读我.txt',folder/'先读我.txt')
subprocess.run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(folder),str(zipfile)],check=True)
print(zipfile)
