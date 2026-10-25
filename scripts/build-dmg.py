#!/usr/bin/env python3
"""把一个已签名的 Totori.app 包装为拖入 Applications 的 DMG，不重编译或重签 App。"""
import argparse
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
import dmgbuild


def run(args):
    """执行文件构建与签名校验；失败时阻止生成可分发镜像。"""
    subprocess.run(list(map(str, args)), check=True)


def configure_volume(mount, settings):
    """校验镜像中的 App；Finder 窗口布局由镜像内的 .DS_Store 保存。"""
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', Path(mount) / 'Totori.app'])


def main():
    """读取已发布 App 的版本，生成双图标布局与校验文件；拒绝覆盖已有 DMG。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    opts = parser.parse_args()
    app, out = opts.app.resolve(), opts.output_dir.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleName'] != 'Totori': raise RuntimeError('Expected Totori.app')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).split()
    if 'arm64' not in architectures: raise RuntimeError('Expected an Apple Silicon App')
    before = hashlib.sha256(executable.read_bytes()).hexdigest()
    version = info['CFBundleShortVersionString']
    out.mkdir(parents=True, exist_ok=True)
    image = out / f'Totori-{version}-macOS-arm64.dmg'
    if image.exists(): raise RuntimeError(f'Output already exists: {image}')
    with tempfile.TemporaryDirectory(prefix='totori-dmg-') as tmp:
        temp = Path(tmp)
        renderer = temp / 'background-renderer'
        run(['/usr/bin/swiftc', Path(__file__).parent / 'dmg/Background.swift', '-o', renderer])
        for name, scale in [('background.png', '1'), ('background@2x.png', '2')]:
            run([renderer, temp / name, scale])
        settings = {
            'format': 'UDZO', 'filesystem': 'HFS+', 'files': [str(app)],
            'symlinks': {'Applications': '/Applications'},
            'icon': str(app / 'Contents/Resources/AppIcon.icns'),
            'background': str(temp / 'background.png'),
            'window_rect': ((240, 200), (680, 520)),
            'grid_spacing': 80,
            'icon_locations': {'Totori.app': (170, 200), 'Applications': (510, 200)},
            'icon_size': 112, 'text_size': 14, 'label_pos': 'bottom',
            'default_view': 'icon-view', 'arrange_by': None,
            'show_toolbar': False, 'show_sidebar': False, 'show_pathbar': False,
            'show_status_bar': False, 'show_tab_view': False,
            'create_hook': configure_volume,
        }
        dmgbuild.build_dmg(str(image), 'Totori', settings=settings)
    run(['/usr/bin/hdiutil', 'verify', image])
    if hashlib.sha256(executable.read_bytes()).hexdigest() != before:
        raise RuntimeError('Source App changed during packaging')
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    (out / (image.name + '.sha256')).write_text(f'{digest}  {image.name}\n')
    print(f'DMG ready: {image}\nSHA256: {digest}', flush=True)


if __name__ == '__main__':
    main()
