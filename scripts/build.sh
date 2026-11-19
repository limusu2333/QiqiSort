#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUNTIME="${1:-$ROOT/runtime}"
if [ "$#" -gt 1 ] || [ -e "$RUNTIME" ]; then
  echo '用法：bash scripts/build.sh [新的运行目录]；不覆盖已有目录，请为新构建指定新位置。' >&2
  exit 1
fi
# Only developers compile Swift; recipients run the included native executable.
if ! xcrun --find swift >/dev/null 2>&1; then
  echo '开发机缺少 Swift 编译工具；使用者无需安装。' >&2
  exit 1
fi
for PACKAGE in mlx-swift-lm mlx-swift swift-transformers swift-jinja swift-numerics swift-collections GzipSwift; do
  test -f "$ROOT/vendor/$PACKAGE/Package.swift" || { echo "项目缺少依赖源码：$PACKAGE" >&2; exit 1; }
done
test -f "$ROOT/vendor/mlx-swift/Source/Cmlx/mlx/mlx/array.cpp"
test -f "$ROOT/vendor/mlx-swift/Source/Cmlx/mlx-c/mlx/c/array.cpp"
# Verifies bundled bytes, never downloads while building.
xcrun swift "$ROOT/scripts/verify_resources.swift" "$ROOT/resources"
mkdir -p "$ROOT/.build"
BUILD="$(mktemp -d "$ROOT/.build/gather-folder.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
# Some CLT upgrades leave stale private interfaces beside the new public API.
# Use a clean build-local copy without modifying Apple's installed toolchain.
MANIFEST_API="$(dirname "$(xcrun --find swift)")/../lib/swift/pm/ManifestAPI"
if [ -d "$MANIFEST_API" ]; then
  mkdir -p "$BUILD/developer-libs"
  cp -R "$MANIFEST_API" "$BUILD/developer-libs/ManifestAPI"
  find "$BUILD/developer-libs/ManifestAPI" -name '*.private.swiftinterface' -delete
  export SWIFTPM_CUSTOM_LIBS_DIR="$BUILD/developer-libs"
fi
xcrun swift build -c release --arch arm64 --product GroupPicker --jobs 4 --manifest-cache none
BIN="$(xcrun swift build -c release --arch arm64 --show-bin-path --manifest-cache none)"
STAGED="$BUILD/components"
mkdir -p "$STAGED"
cp "$BIN/GroupPicker" "$STAGED/七七整理台"
ln -s 七七整理台 "$STAGED/GroupPicker"
cp "$ROOT/resources/branding/Qiqi.icns" "$STAGED/Qiqi.icns"
cp "$ROOT/resources/runtime/mlx.metallib" "$STAGED/mlx.metallib"
for BUNDLE in "$BIN"/*.bundle; do
  test ! -d "$BUNDLE" || cp -R "$BUNDLE" "$STAGED/"
done
codesign --force --sign - "$STAGED/七七整理台"
codesign --verify --strict "$STAGED/七七整理台"
# The staged executable locates project resources above its build directory.
"$STAGED/七七整理台" --startup-status
mkdir -p "$(dirname "$RUNTIME")"
mv "$STAGED" "$RUNTIME"
printf '文件夹运行组件已生成：%s；不生成 .app，不下载资源。\n' "$RUNTIME"
