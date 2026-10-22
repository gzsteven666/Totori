#!/usr/bin/env python3
"""检查搬移后的分发 App：完整签名、arm64、部署版本及所有 Mach-O 的动态依赖。"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess


def output(args):
    """执行只读命令；命令失败时终止验证。"""
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT)


def main():
    """扫描包内真正的 Mach-O 文件，拒绝外部 Homebrew、用户目录或非系统绝对依赖。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--report', type=Path)
    opts = parser.parse_args()
    app = opts.app.resolve()
    output(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    records, seen, issues = [], set(), []
    for p in app.rglob('*'):
        if p.is_symlink() or not p.is_file(): continue
        with p.open('rb') as f: magic = f.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'): continue
        if magic in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca') and 'Mach-O' not in output(['/usr/bin/file', '-b', p]): continue
        if p.resolve() in seen: continue
        seen.add(p.resolve())
        arch = output(['/usr/bin/lipo', '-archs', p]).strip()
        if 'arm64' not in arch.split(): issues.append(f'{p.relative_to(app)}: missing arm64 ({arch})')
        commands = output(['/usr/bin/otool', '-arch', 'arm64', '-l', p])
        install_ids = re.findall(r'cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset', commands)
        loads = output(['/usr/bin/otool', '-arch', 'arm64', '-L', p]).splitlines()[1:]
        dependencies = [line.strip().split(' (compatibility')[0] for line in loads if line.startswith('\t')]
        # otool -L 第一项可能是 dylib 自身的安装标识，不是实际加载的依赖。
        for identity in install_ids:
            if identity in dependencies: dependencies.remove(identity)
        for dep in dependencies:
            if dep.startswith('/') and not dep.startswith(('/System/Library/', '/usr/lib/')):
                issues.append(f'{p.relative_to(app)}: external dependency {dep}')
        versions = re.findall(r'\bminos (\d+(?:\.\d+)*)', commands)
        versions += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)*)', commands)
        for version in versions:
            if tuple(map(int, version.split('.'))) > (13, 0, 0):
                issues.append(f'{p.relative_to(app)}: requires macOS {version}')
        records.append({'path': str(p.relative_to(app)), 'architectures': arch,
                        'minimumOS': versions, 'installIDs': install_ids, 'dependencies': dependencies})
    for name in ['Helpers/ffmpeg', 'Helpers/ffprobe', 'Helpers/cwebp', 'Frameworks/LibreOffice.app/Contents/MacOS/soffice', 'Resources/fonts.conf']:
        if not (app / 'Contents' / name).is_file(): issues.append(f'Missing {name}')
    report = {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
              'signature': 'verified', 'machOCount': len(records), 'issues': issues, 'binaries': records}
    if opts.report: opts.report.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'binaries'}, indent=2))
    if issues: raise SystemExit(1)


if __name__ == '__main__':
    main()
