#!/usr/bin/env python3
"""构建可搬移的 arm64 编码工具；只链接 macOS 系统库，并保存对应源码与许可证。"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request


def run(args, cwd, env):
    """运行一个构建阶段，失败时终止，完整日志交给调用方保存。"""
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def main():
    """按锁定的 URL 和 SHA256 下载、编译，并产出可重建的运行时目录。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--jobs', type=int, default=min(os.cpu_count() or 4, 8))
    opts = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    root = opts.work_dir.resolve()
    downloads, sources, prefix = [root / n for n in ('downloads', 'sources', 'prefix')]
    for p in (downloads, sources, prefix):
        p.mkdir(parents=True, exist_ok=True)
    lock = json.loads((repo / 'scripts/runtime-lock.json').read_text())
    env = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin',
               MACOSX_DEPLOYMENT_TARGET='13.0',
               CFLAGS='-O2 -arch arm64 -mmacosx-version-min=13.0',
               CXXFLAGS='-O2 -arch arm64 -mmacosx-version-min=13.0',
               LDFLAGS='-arch arm64 -mmacosx-version-min=13.0')
    trees = {}
    for name, spec in lock.items():
        archive = downloads / spec['filename']
        if not archive.exists():
            urllib.request.urlretrieve(spec['url'], archive)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != spec['sha256']:
            raise RuntimeError(f'{name}: checksum mismatch')
        unpack = sources / name
        if not unpack.exists():
            unpack.mkdir()
            with tarfile.open(archive) as tf:
                # 锁定上游归档；仍拒绝绝对路径或 .. 越界写入。
                for member in tf.getmembers():
                    if member.name.startswith('/') or '..' in Path(member.name).parts:
                        raise RuntimeError('Unsafe archive path')
                tf.extractall(unpack, filter='data')
        dirs = [p for p in unpack.iterdir() if p.is_dir()]
        trees[name] = dirs[0] if len(dirs) == 1 else unpack
    def build(name, flags):
        """顺序构建一个静态库或构建工具，安装到专用前缀，不修改 Homebrew。"""
        tree = trees[name]
        run(['./configure', f'--prefix={prefix}', *flags], tree, env)
        run(['make', f'-j{opts.jobs}'], tree, env)
        run(['make', 'install'], tree, env)
    build('pkgconf', ['--disable-shared', '--enable-static'])
    env['PATH'] = f'{prefix}/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    env['PKG_CONFIG'] = str(prefix / 'bin/pkgconf')
    env['PKG_CONFIG_LIBDIR'] = str(prefix / 'lib/pkgconfig')
    env['PKG_CONFIG_PATH'] = ''
    build('lame', ['--disable-shared', '--enable-static', '--disable-frontend', '--disable-decoder', '--disable-dependency-tracking'])
    build('opus', ['--disable-shared', '--enable-static', '--disable-doc', '--disable-extra-programs'])
    build('libvpx', ['--target=arm64-darwin20-gcc', '--disable-examples', '--disable-tools',
                     '--disable-docs', '--disable-unit-tests', '--disable-shared', '--enable-pic'])
    build('x264', ['--host=aarch64-apple-darwin', '--enable-static', '--disable-cli', '--disable-opencl'])
    build('ffmpeg', ['--arch=arm64', '--target-os=darwin', '--disable-autodetect',
                     '--disable-shared', '--enable-static', '--disable-debug', '--disable-doc',
                     '--disable-ffplay', '--disable-network', '--enable-gpl', '--enable-version3',
                     '--enable-libx264', '--enable-libmp3lame', '--enable-libvpx', '--enable-libopus',
                     '--enable-videotoolbox', '--enable-audiotoolbox', '--enable-neon',
                     f'--pkg-config={prefix}/bin/pkgconf', '--pkg-config-flags=--static',
                     f'--extra-cflags=-I{prefix}/include -mmacosx-version-min=13.0',
                     f'--extra-ldflags=-L{prefix}/lib -mmacosx-version-min=13.0'])
    runtime = root / 'runtime'
    (runtime / 'bin').mkdir(parents=True, exist_ok=True)
    for name in ('ffmpeg', 'ffprobe'):
        shutil.copy2(prefix / 'bin' / name, runtime / 'bin' / name)
    build('libpng', ['--disable-shared', '--enable-static'])
    # 静态 libpng 的 zlib 依赖需显式加入，否则 configure 会无声关闭 PNG 读取。
    env['LIBS'] = '-lz'
    build('webp', ['--disable-shared', '--enable-static', '--disable-gl', '--disable-sdl',
                   '--disable-jpeg', '--disable-tiff', '--disable-gif',
                   f'--with-pngincludedir={prefix}/include', f'--with-pnglibdir={prefix}/lib'])
    shutil.copy2(prefix / 'bin/cwebp', runtime / 'bin/cwebp')
    licenses = runtime / 'Licenses'
    licenses.mkdir(exist_ok=True)
    for name, tree in trees.items():
        target = licenses / name
        target.mkdir(exist_ok=True)
        for pattern in ('COPYING*', 'LICENSE*', 'PATENTS*', 'AUTHORS*', 'NOTICE*'):
            for p in tree.glob(pattern):
                if p.is_file(): shutil.copy2(p, target / p.name)
    shutil.copy2(repo / 'scripts/runtime-lock.json', runtime / 'runtime-lock.json')
    for name in ('ffmpeg', 'ffprobe', 'cwebp'):
        run(['/usr/bin/strip', '-x', runtime / 'bin' / name], root, env)
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', runtime / 'bin' / name], root, env)
    # 实际读取 PNG，防止可选解码器缺失仍被误判为构建成功。
    smoke = root / 'webp-build-smoke.webp'
    sample = root / 'webp-build-smoke.png'
    sample.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNwaHD4DwAEBAIAo9tyYQAAAABJRU5ErkJggg=='))
    run([runtime / 'bin/cwebp', '-quiet', '-o', smoke, sample], root, env)
    sample.unlink()
    if smoke.stat().st_size == 0: raise RuntimeError('Empty WebP smoke output')
    smoke.unlink()
    print(f'Runtime ready: {runtime}', flush=True)


if __name__ == '__main__':
    main()
