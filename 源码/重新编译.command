#!/bin/bash
# Compositor 简体中文版 · 可复现编译（v3：纯语言包驱动）
#
# 用法： 源码/重新编译.command [输出二进制路径]
# 默认输出到 重编译二进制/Compositor-zh-v7（与 安装汉化.command 的 BIN 指向保持一致）
#
# 前提：CommandLineTools 提供 MacOSX26.5.sdk 与 swift/host/plugins（macOS 27.2 实测）。
# 源码/ 目录自包含：184 个 Swift + 10 个 C + Bridging Header + Sparkle.framework（Header/Modules）。
# 编译产物为 ad-hoc 签名的可执行文件；装进 App 包后仍需跑 安装汉化.command 重签主 bundle。
set -euo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$KIT/源码/Compositor"
FWDIR="$KIT/源码"
OUT="${1:-$KIT/重编译二进制/Compositor-zh-v7}"
BUILD="$(mktemp -d /tmp/compositor-build.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
CLT="/Library/Developer/CommandLineTools"
TARGET="arm64-apple-macos26.5"

if [ ! -d "$SDK" ]; then echo "✗ 缺 SDK: $SDK"; echo "  需要本机 CommandLineTools 提供对应 SDK：ls /Library/Developer/CommandLineTools/SDKs/ 查看，"; echo "  并按本机 SDK 版本修改本脚本顶部的 SDK / TARGET 两个变量。"; exit 1; fi
if [ ! -d "$FWDIR/Sparkle.framework/Headers" ]; then echo "✗ 缺 Sparkle 头文件"; exit 1; fi

echo "① 编译 10 个 C 目标文件 …"
for f in "$SRC"/Rendering/*.c; do
  name="$(basename "$f" .c)"
  xcrun clang -c -O2 -fblocks -target "$TARGET" -isysroot "$SDK" \
    -I "$SRC/Rendering" "$f" -o "$BUILD/$name.o"
done

echo "② 编译 Swift（184 个文件，-O 优化）…"
SWIFTS=()
while IFS= read -r f; do SWIFTS+=("$f"); done < <(find "$SRC" -name "*.swift" | sort)
echo "   Swift 文件数: ${#SWIFTS[@]}"

xcrun swiftc -swift-version 5 -parse-as-library -strict-concurrency=minimal \
  -default-isolation MainActor -O -target "$TARGET" -sdk "$SDK" \
  -plugin-path "$CLT/usr/lib/swift/host/plugins" \
  -import-objc-header "$SRC/Compositor-Bridging-Header.h" \
  -I "$SRC" -F "$FWDIR" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${SWIFTS[@]}" "$BUILD"/*.o -o "$OUT" 2> "$BUILD/swift_err.txt" || {
    echo "✗ 编译失败，错误输出："; cat "$BUILD/swift_err.txt"; exit 1
  }

echo "  编译警告/提示行数: $(wc -l < "$BUILD/swift_err.txt")"
grep -c "error:" "$BUILD/swift_err.txt" | xargs -I{} echo "  error 数: {}"
echo ""
echo "✅ 产物：$OUT ($(du -h "$OUT" | cut -f1))"
echo "   下一步：装进 App 包并跑 安装汉化.command 重签名（脚本会备份 + 注入词表 + 验签）。"
