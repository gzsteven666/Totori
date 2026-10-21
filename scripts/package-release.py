#!/usr/bin/env python3
"""下载已锁定的文档引擎，组装独立 App，并生成安装包、对应源码包及 SHA256。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import urllib.request


def run(args, **kwargs):
    """执行可追踪的打包命令；失败时停止发布，不触碰已有安装包。"""
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def main():
    """只在指定输出目录组装，不替换开发机的 App 或 LibreOffice。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime-work-dir', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--archive-only', action='store_true', help='校验并归档输出目录内已组装的 App，不重新编译')
    opts = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    work, out = opts.runtime_work_dir.resolve(), opts.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    version = plistlib.loads((repo / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    name = f'Totori-{version}-macOS-arm64'
    folder = out / name
    if (folder.exists() and not opts.archive_only) or (out / f'{name}.zip').exists():
        raise RuntimeError('Output already exists; use a new output directory')
    if not opts.archive_only:
        lock = json.loads((repo / 'scripts/libreoffice-lock.json').read_text())
        image = work / 'downloads' / lock['url'].rsplit('/', 1)[1]
        image.parent.mkdir(parents=True, exist_ok=True)
        if not image.exists(): urllib.request.urlretrieve(lock['url'], image)
        if hashlib.sha256(image.read_bytes()).hexdigest() != lock['sha256']:
            raise RuntimeError('LibreOffice checksum mismatch')
        mount = work / 'release-lo-mount'
        folder.mkdir()
        mounted = False
        try:
            run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, image])
            mounted = True
            run(['codesign', '--verify', '--deep', '--strict', mount / 'LibreOffice.app'])
            env = dict(os.environ, TOTORI_RUNTIME_DIR=str(work / 'runtime'),
                       TOTORI_LIBREOFFICE_APP=str(mount / 'LibreOffice.app'),
                       TOTORI_OUTPUT_APP=str(folder / 'Totori.app'))
            run(['bash', repo / 'build.sh'], cwd=repo, env=env)
        finally:
            if mounted: run(['hdiutil', 'detach', mount])
    run(['python3', repo / 'scripts/verify-release.py', folder / 'Totori.app',
         '--report', out / 'binary-audit.json'])
    shutil.copy2(repo / 'docs/INSTALL.zh.md', folder / '安装说明.md')
    shutil.copy2(repo / 'THIRD_PARTY_NOTICES.md', folder / 'THIRD_PARTY_NOTICES.md')
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', folder, out / f'{name}.zip'])
    source = out / 'Totori-third-party-sources.tar.gz'
    runtime_lock = json.loads((repo / 'scripts/runtime-lock.json').read_text())
    with tarfile.open(source, 'w:gz') as tf:
        for spec in runtime_lock.values():
            p = work / 'downloads' / spec['filename']
            if hashlib.sha256(p.read_bytes()).hexdigest() != spec['sha256']:
                raise RuntimeError(f'Corresponding source checksum mismatch: {p.name}')
            tf.add(p, arcname=f'Totori-third-party-sources/downloads/{p.name}')
        for relative in ['scripts/build-runtime.py', 'scripts/runtime-lock.json', 'THIRD_PARTY_NOTICES.md']:
            tf.add(repo / relative, arcname=f'Totori-third-party-sources/{relative}')
    sums = []
    for p in [out / f'{name}.zip', source]:
        sums.append(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}')
    (out / 'SHA256SUMS.txt').write_text('\n'.join(sums)+'\n')
    shutil.copy2(repo / 'docs/INSTALL.zh.md', out / 'INSTALL.zh.md')
    print(f'Release files ready in {out}', flush=True)


if __name__ == '__main__':
    main()
