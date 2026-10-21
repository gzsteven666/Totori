# Third-party software in the Apple Silicon release

Totori launches the following independent command-line programs. It does not link its Swift executable against FFmpeg or LibreOffice libraries. Their licenses and copyrights remain with their respective authors.

| Component | Version | License / use |
| --- | --- | --- |
| FFmpeg / ffprobe | 9.0.2 | GPL-3.0-or-later; media conversion and metadata |
| x264 | b35605ace3ddf7c1a5d67a2eb553f034aef41d55 | GPL-2.0-or-later; FFmpeg H.264 software encoder |
| LAME | 4.0 | LGPL-2.0-or-later; MP3 encoder |
| libvpx | 1.17.0 | BSD-3-Clause; WebM encoder |
| Opus | 1.6.1 | BSD-3-Clause; audio encoder |
| libwebp / cwebp | 1.6.0 | BSD-3-Clause; WebP encoder |
| libpng | 1.6.59 | libpng-2.0; PNG input for cwebp |
| LibreOffice | 26.8.1 | MPL-2.0 and bundled third-party licenses; document conversion |

The release includes the original license texts under `Totori.app/Contents/Resources/ThirdPartyLicenses`. LibreOffice retains its full `LICENSE`, `LICENSE.html`, `NOTICE`, and other attribution files inside `Contents/Frameworks/LibreOffice.app/Contents/Resources`. Its original vendor-signed bundle is retained without changes.

## Corresponding source and rebuilding

The same GitHub Release includes **Totori-third-party-sources.tar.gz**, containing the exact source archives, checksums, and build scripts for FFmpeg, x264, LAME, libvpx, Opus, libwebp, libpng, and the build-only pkgconf tool. No source patches are applied. The scripts configure static arm64 command-line programs with a macOS 13 deployment target. FFmpeg is built with GPL and version-3 components enabled; it is not an LGPL-only build.

`python3 scripts/build-runtime.py --work-dir <new-build-directory>` rebuilds these programs with Apple Command Line Tools and Python 3.12 or later. The `runtime-lock.json` records exact upstream URLs, SHA-256 values, versions and licenses. The source archive includes a copy of that file and this notice.

LibreOffice 26.8.1 is the unmodified Apple Silicon distribution from The Document Foundation. Its executable distribution is pinned in `scripts/libreoffice-lock.json`. Source code is available at:

- [LibreOffice 26.8.1 source directory](https://download.documentfoundation.org/libreoffice/src/26.8.1/)
- [Exact LibreOffice 26.8.1.1 source archive](https://download.documentfoundation.org/libreoffice/src/26.8.1/libreoffice-26.8.1.1.tar.xz)
- [LibreOffice source repository](https://git.libreoffice.org/core)
- [LibreOffice licensing information](https://www.libreoffice.org/licenses/)

System frameworks and `/usr/bin` tools are supplied by macOS and are not redistributed. Conversion engines run locally. FFmpeg network protocols are disabled in this build.

These notices do not grant rights to Totori branding or change any third-party license. No warranty is offered beyond the applicable license terms.
