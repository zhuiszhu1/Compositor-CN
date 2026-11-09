#!/bin/bash
# 编译「Web 导出」插件 → WebExport.compositorplugin → 装入 Compositor App 包内置插件目录
#
# 用法： 编译导出插件.command [Compositor.app 路径]
#   默认 /Applications/Compositor.app；测试时可指向 /tmp 副本。
#
# 与撕边插件的差异：
#   - vendored libwebp 1.6.0（WebP 编码；macOS ImageIO 不支持 WebP 编码，探针 2026-11-08 实证）
#     先用 clang 编成 arm64 静态库，再随插件动态库一起链接
#   - 链接系统 zlib（PNG8 的 IDAT deflate + CRC32）
#   - ABI v2（entry @48 = encodeImage），宿主主程序需为 v4.1+（含 ABI v2 支持）
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
cd "$KIT"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
TARGET="arm64-apple-macos26.5"
APP="${1:-/Applications/Compositor.app}"

if [ ! -d "$APP" ]; then echo "✗ 缺 App: $APP"; exit 1; fi
if [ ! -d "$SDK" ]; then echo "✗ 缺 SDK: $SDK"; exit 1; fi
if [ ! -d "$KIT/libwebp-src/src" ]; then echo "✗ 缺 libwebp-src（源码目录）: $KIT/libwebp-src"; exit 1; fi

BUILD="$(mktemp -d /tmp/webexport-build.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

echo "① 编译 libwebp 静态库（-O3 arm64）…"
# 1.6.0 结构：编码器在 src/enc + src/utils + src/dsp，sharpyuv 在仓库根 sharpyuv/
# 统一 $KIT 绝对路径：编译在 ( cd "$BUILD" ) 子 shell 里做，相对路径会失效。
WEBP_SRCS=$(ls "$KIT/libwebp-src/src/enc/"*.c "$KIT/libwebp-src/src/utils/"*.c \
                 "$KIT/libwebp-src/src/dsp/"*.c "$KIT/libwebp-src/sharpyuv/"*.c)
( cd "$BUILD"
  for src in $WEBP_SRCS; do
    xcrun clang -c -O3 -DNDEBUG -arch arm64 -fno-common \
      -I "$KIT/libwebp-src" -I "$KIT/libwebp-src/src" \
      "$src" -o "$(basename "$src" .c).o" 2>> "$BUILD/webp-err.txt" \
      || { echo "✗ libwebp 编译失败：$src"; tail -5 "$BUILD/webp-err.txt"; exit 1; }
  done
  xcrun libtool -static -o libwebpenc.a *.o )
echo "   静态库 $(du -h "$BUILD/libwebpenc.a" | cut -f1)，$(ls "$BUILD"/*.o | wc -l | tr -d ' ') 个目标"

echo "①b 编译 libwebp Swift 包装 shim …"
xcrun clang -c -O3 -DNDEBUG -arch arm64 -fno-common \
  -I "$KIT" -I "$KIT/libwebp-src" -I "$KIT/libwebp-src/src" \
  "$KIT/webp_shim.c" -o "$BUILD/webp_shim.o"

echo "② 编译插件动态库（-O）…"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target "$TARGET" -sdk "$SDK" \
  -import-objc-header "$KIT/webp_bridging.h" \
  "$KIT/WebExportPlugin.swift" \
  "$BUILD/libwebpenc.a" "$BUILD/webp_shim.o" \
  -lz \
  -emit-library -o "$BUILD/WebExportPlugin" \
  -Xlinker -install_name -Xlinker @rpath/WebExportPlugin \
  2> "$BUILD/err.txt" \
  || { echo "✗ 编译失败："; cat "$BUILD/err.txt"; exit 1; }
echo "   $(grep -c . "$BUILD/err.txt" || true) 行提示"

echo "③ 组装 bundle …"
mkdir -p "$BUILD/WebExport.compositorplugin/Contents/MacOS"
cp "$BUILD/WebExportPlugin" "$BUILD/WebExport.compositorplugin/Contents/MacOS/"
cp "$KIT/Info.plist" "$BUILD/WebExport.compositorplugin/Contents/"
codesign --force --sign - "$BUILD/WebExport.compositorplugin" 2>/dev/null || true

echo "④ 安装到 $APP/Contents/Plugins/ …"
mkdir -p "$APP/Contents/Plugins"
rm -rf "$APP/Contents/Plugins/WebExport.compositorplugin"
cp -R "$BUILD/WebExport.compositorplugin" "$APP/Contents/Plugins/"

echo "⑤ 重签主 bundle（插件在包内，主程序签名须覆盖它）…"
if codesign -d --entitlements :"$BUILD/ent.plist" "$APP" >/dev/null 2>&1 && [ -s "$BUILD/ent.plist" ]; then
  codesign --force --sign - --entitlements "$BUILD/ent.plist" "$APP"
else
  codesign --force --sign - "$APP"
fi

codesign --verify "$APP" && echo "   验签有效"
echo ""
echo "✅ 插件已就绪：$APP/Contents/Plugins/WebExport.compositorplugin"
echo "   重启 Compositor 后，文件菜单出现「导出为 Web 格式…」。"
