#!/bin/bash
# 构建完成并验证后再替换 Totori.app；失败时保留可用版本。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${TOTORI_OUTPUT_APP:-$ROOT/Totori.app}"
RUNTIME="${TOTORI_RUNTIME_DIR:-}"
LIBREOFFICE="${TOTORI_LIBREOFFICE_APP:-}"
if { [ -n "$RUNTIME" ] && [ -z "$LIBREOFFICE" ]; } || { [ -z "$RUNTIME" ] && [ -n "$LIBREOFFICE" ]; }; then
  echo "分发构建需要同时提供 TOTORI_RUNTIME_DIR 与 TOTORI_LIBREOFFICE_APP" >&2
  exit 1
fi
LOCK="$ROOT/.totori-build.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "已有构建正在运行：$LOCK" >&2
  echo "确认没有构建进程后，才可移除遗留的锁目录。" >&2
  exit 1
fi

STAGE=""
PREVIOUS=""
cleanup() {
  local result=$?
  trap - EXIT
  if [ -n "$PREVIOUS" ] && [ -d "$PREVIOUS" ] && [ ! -e "$APP" ]; then
    mv "$PREVIOUS" "$APP" || echo "请从此路径恢复应用：$PREVIOUS" >&2
  fi
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
  rmdir "$LOCK" 2>/dev/null || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGE="$(mktemp -d "$ROOT/.totori-build.XXXXXX")"
NEW_APP="$STAGE/Totori.app"
BIN="$NEW_APP/Contents/MacOS/XiaoJuConvert"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$NEW_APP/Contents/MacOS" "$NEW_APP/Contents/Resources"

echo "==> 编译到临时目录；现有 App 保持可用"
SOURCES=("$ROOT"/Sources/*.swift)
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -sdk "$SDK" -o "$BIN" "${SOURCES[@]}"

cp "$ROOT/Resources/Info.plist" "$NEW_APP/Contents/Info.plist"
for resource in AppIcon.icns menubar.png menubar@2x.png totori-paw-open.png totori-paw-grasp.png; do
  cp "$ROOT/Resources/$resource" "$NEW_APP/Contents/Resources/$resource"
done
if [ -n "$RUNTIME" ]; then
  echo "==> 加入可搬移的 arm64 运行时与 LibreOffice"
  mkdir -p "$NEW_APP/Contents/Helpers" "$NEW_APP/Contents/Frameworks"
  for tool in ffmpeg ffprobe cwebp; do
    test -x "$RUNTIME/bin/$tool"
    cp "$RUNTIME/bin/$tool" "$NEW_APP/Contents/Helpers/$tool"
  done
  ditto "$LIBREOFFICE" "$NEW_APP/Contents/Frameworks/LibreOffice.app"
  ditto "$RUNTIME/Licenses" "$NEW_APP/Contents/Resources/ThirdPartyLicenses"
  cp "$ROOT/scripts/runtime-lock.json" "$NEW_APP/Contents/Resources/runtime-lock.json"
  cp "$ROOT/THIRD_PARTY_NOTICES.md" "$NEW_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
  cp "$ROOT/scripts/libreoffice-lock.json" "$NEW_APP/Contents/Resources/libreoffice-lock.json"
  /usr/bin/plutil -convert json -o "$NEW_APP/Contents/Resources/RuntimeManifest.json" \
    "$ROOT/scripts/distribution.plist"
fi
printf 'APPL????'  > "$NEW_APP/Contents/PkgInfo"
plutil -lint "$NEW_APP/Contents/Info.plist"
test -x "$BIN"

echo "==> 签名并验证"
IDENTITY="XiaoJu Local Signer"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  SIGNER="$IDENTITY"
else
  echo "未找到 $IDENTITY，使用 ad-hoc 签名"
  SIGNER="-"
fi
if [ -n "$RUNTIME" ]; then
  for tool in ffmpeg ffprobe cwebp; do
    codesign --force --sign "$SIGNER" --timestamp=none "$NEW_APP/Contents/Helpers/$tool"
  done
  codesign --verify --deep --strict "$NEW_APP/Contents/Frameworks/LibreOffice.app"
fi
codesign --force --sign "$SIGNER" --timestamp=none "$NEW_APP"
codesign --verify --deep --strict "$NEW_APP"

echo "==> 发布已验证的 App"
if [ -e "$APP" ]; then
  mkdir -p "$ROOT/backups"
  BACKUP_DIR="$(mktemp -d "$ROOT/backups/build-$(date +%Y%m%d-%H%M%S).XXXXXX")"
  PREVIOUS="$BACKUP_DIR/Totori.app"
  mv "$APP" "$PREVIOUS"
fi
mv "$NEW_APP" "$APP"
echo "==> 完成：$APP"
if [ -n "$PREVIOUS" ]; then echo "    上一版本：$PREVIOUS"; fi
echo "    自检：\"$APP/Contents/MacOS/XiaoJuConvert\" --selftest"
