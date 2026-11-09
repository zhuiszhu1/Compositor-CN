#!/bin/bash
# 编译「撕边」插件 → TornEdge.compositorplugin → 装入 Compositor App 包内置插件目录
#
# 用法： 编译撕边插件.command [Compositor.app 路径]
#   默认 /Applications/Compositor.app；测试时可指向 /tmp 副本。
#
# 插件加载位置（主程序按序扫描，先到先得）：
#   1. 沙盒容器内 Application Support/Compositor/Plugins/  （App 自己管理；外部进程无权写入）
#   2. App 包内 Contents/Plugins/                            （本脚本安装的位置，随包分发）
#
# 要点：
#   - 同主程序一致的环境：CommandLineTools + MacOSX26.5.sdk + arm64-apple-macos26.5
#   - Swift runtime 随 macOS 系统内置，且宿主进程本身已加载，插件直接复用
#   - 无 Foundation 依赖（插件内手写参数解析），产物只有 libc + libSystem
#   - 装入 App 包后需重签主 bundle（ad-hoc，沿用安装脚本的授权）
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
TARGET="arm64-apple-macos26.5"
APP="${1:-/Applications/Compositor.app}"

if [ ! -d "$APP" ]; then echo "✗ 缺 App: $APP"; exit 1; fi
if [ ! -d "$SDK" ]; then echo "✗ 缺 SDK: $SDK"; exit 1; fi

BUILD="$(mktemp -d /tmp/tornedge-build.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

echo "① 编译插件动态库（-O）…"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target "$TARGET" -sdk "$SDK" \
  "$KIT/TornEdgePlugin.swift" \
  -emit-library -o "$BUILD/TornEdgePlugin" \
  -Xlinker -install_name -Xlinker @rpath/TornEdgePlugin \
  2> "$BUILD/err.txt" || { echo "✗ 编译失败："; cat "$BUILD/err.txt"; exit 1; }
echo "   $(grep -c . "$BUILD/err.txt" || true) 行提示"

echo "② 组装 bundle …"
mkdir -p "$BUILD/TornEdge.compositorplugin/Contents/MacOS"
cp "$BUILD/TornEdgePlugin" "$BUILD/TornEdge.compositorplugin/Contents/MacOS/"
cp "$KIT/Info.plist" "$BUILD/TornEdge.compositorplugin/Contents/"
codesign --force --sign - "$BUILD/TornEdge.compositorplugin" 2>/dev/null || true

echo "③ 安装到 $APP/Contents/Plugins/ …"
mkdir -p "$APP/Contents/Plugins"
rm -rf "$APP/Contents/Plugins/TornEdge.compositorplugin"
cp -R "$BUILD/TornEdge.compositorplugin" "$APP/Contents/Plugins/"

echo "④ 重签主 bundle（插件在包内，主程序签名须覆盖它）…"
if codesign -d --entitlements :"$BUILD/ent.plist" "$APP" >/dev/null 2>&1 && [ -s "$BUILD/ent.plist" ]; then
  codesign --force --sign - --entitlements "$BUILD/ent.plist" "$APP"
else
  codesign --force --sign - "$APP"
fi

codesign --verify "$APP" && echo "   验签有效"
echo ""
echo "✅ 插件已就绪：$APP/Contents/Plugins/TornEdge.compositorplugin"
echo "   （重)启动 Compositor 后，左侧工具栏底部出现「撕边」按钮。"
