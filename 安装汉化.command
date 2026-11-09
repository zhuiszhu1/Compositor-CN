#!/bin/bash
# Compositor 简体中文汉化 · 安装（v3：纯语言包驱动，可重复运行）
# 恢复内容：中文字符串表（zh-Hans + en 双份） + 重编译中文二进制（v3，全部文案走语言包查表）
#          + 关闭 Sparkle 自动检查更新（本地维护，避免被动覆盖）
# 版本守卫：仅当 App 版本为 1.6.4 (63) 时替换二进制；其他版本只注入语言包。
# 预演：COMPOSITOR_APP=/tmp/副本.app 本脚本可在副本上先跑通再落地正式包。
set -euo pipefail

APP="${COMPOSITOR_APP:-/Applications/Compositor.app}"
KIT="$(cd "$(dirname "$0")" && pwd)"
SRC="$KIT/zh-Hans.lproj/Localizable.strings"
BIN="$KIT/重编译二进制/Compositor-zh-v7"
BACKUP_DIR="$KIT/备份"
BACKUP="$BACKUP_DIR/Compositor-原版.app"

if [ ! -d "$APP" ]; then echo "✗ 找不到 $APP"; exit 1; fi
if [ ! -f "$SRC" ]; then echo "✗ 找不到语言包 $SRC"; exit 1; fi
if [ ! -f "$BIN" ]; then echo "✗ 找不到重编译二进制 $BIN"; exit 1; fi

mkdir -p "$BACKUP_DIR"
if [ ! -d "$BACKUP" ]; then
  echo "① 备份原版 App …"
  cp -R "$APP" "$BACKUP"
else
  echo "① 已存在原版备份，跳过"
fi

echo "② 写入中文字符串表（zh-Hans + en 双份，兼容两种查找路径）…"
RES="$APP/Contents/Resources"
mkdir -p "$RES/zh-Hans.lproj" "$RES/en.lproj"
cp "$SRC" "$RES/zh-Hans.lproj/Localizable.strings"
cp "$SRC" "$RES/en.lproj/Localizable.strings"

echo "②b 恢复重编译中文二进制（仅当版本匹配 1.6.4 / 63）…"
VER="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || true)"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$VER" = "1.6.4" ] && [ "$BUILD" = "63" ]; then
  cp "$BIN" "$APP/Contents/MacOS/Compositor"
  chmod +x "$APP/Contents/MacOS/Compositor"
  echo "  已恢复中文重编译二进制（语言包驱动：混合模式/底部菜单/右键菜单/面板标题全走词表）"
else
  echo "  ⚠ App 版本 $VER ($BUILD) ≠ 1.6.4 (63)，跳过二进制替换，仅注入语言包"
fi

echo "②c 关闭 Sparkle 自动检查更新（本地维护，避免被动覆盖汉化）…"
PLIST="$APP/Contents/Info.plist"
python3 - "$PLIST" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f:
    d = plistlib.load(f)
d["CFBundleDevelopmentRegion"] = "zh-Hans"
d["CFBundleLocalizations"] = ["zh-Hans", "en"]
d["SUEnableAutomaticChecks"] = False
with open(p, "wb") as f:
    plistlib.dump(d, f, fmt=plistlib.FMT_XML, sort_keys=True)
PY
plutil -lint "$PLIST"

echo "③ 重新签名（只签主程序，Sparkle 保持官方签名）…"
# ⚠️ 启动崩溃的关键点（macOS 27 实测）：
# 改包后主程序只能 ad-hoc 本地签名，TeamIdentifier 为空。
# 若主程序带 hardened runtime，library validation 会要求被加载的
# framework 有相同 Team ID，于是 dyld 拒绝 Sparkle.framework → 启动即 SIGABRT。
# 修法：① Sparkle 及内部 XPC/Updater 一律不重签，从原版备份还原；
#       ② 主程序补 com.apple.security.cs.disable-library-validation 授权。
ENT="$(mktemp /tmp/compositor-ent.XXXXXX)"
python3 - "$BACKUP" "$ENT" <<'PY'
import plistlib, subprocess, sys
backup, out = sys.argv[1], sys.argv[2]
# codesign 的 ":-" 表示把授权 plist 写到 stdout；写成 "-" 会输出到名为 "-" 的文件
try:
    raw = subprocess.check_output(
        ["codesign", "-d", "--entitlements", ":-", backup],
        stderr=subprocess.DEVNULL)
    ent = plistlib.loads(raw)
except Exception:
    print("⚠ 未能读取原版授权，改用已知的 1.6.4 授权", file=sys.stderr)
    ent = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.files.user-selected.read-write": True,
        "com.apple.security.network.client": True,
        "com.apple.security.temporary-exception.mach-lookup.global-name": [
            "com.wonderassembly.compositor-spks",
            "com.wonderassembly.compositor-spki"],
    }
ent["com.apple.security.cs.disable-library-validation"] = True
with open(out, "wb") as f:
    plistlib.dump(ent, f, fmt=plistlib.FMT_XML, sort_keys=True)
PY
plutil -lint "$ENT" > /dev/null

if [ -d "$BACKUP/Contents/Frameworks/Sparkle.framework" ]; then
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  cp -R "$BACKUP/Contents/Frameworks/Sparkle.framework" "$APP/Contents/Frameworks/"
fi
codesign --force --sign - --options runtime --entitlements "$ENT" "$APP" 2>/dev/null
rm -f "$ENT"
xattr -cr "$APP" 2>/dev/null || true

echo "④ 校验 …"
plutil -lint "$RES/zh-Hans.lproj/Localizable.strings" > /dev/null
plutil -lint "$RES/en.lproj/Localizable.strings" > /dev/null
ENTCHK="$(mktemp /tmp/compositor-entchk.XXXXXX)"
codesign -d --entitlements :- "$APP" 2>/dev/null > "$ENTCHK"
if ! grep -q "disable-library-validation" "$ENTCHK"; then
  echo "  ✗ 缺少跨签名加载授权，启动会崩溃（签名步骤失败）"; exit 1
fi
rm -f "$ENTCHK"
echo "  跨签名加载授权：已就绪"
echo "  Sparkle 自动检查：$(plutil -extract SUEnableAutomaticChecks raw "$PLIST" 2>/dev/null || echo 未设置)（false=已关闭）"
if codesign --verify --verbose=2 "$APP" > /tmp/compositor-codesign.log 2>&1; then
  echo "  签名有效（ad-hoc 本地签名）"
else
  echo "  ✗ 签名校验未通过："
  cat /tmp/compositor-codesign.log
  exit 1
fi

echo
echo "✅ 汉化已写入。请完全退出 Compositor 再重新打开（⌘Q 后重开）即可看到中文界面。"
echo "   原版备份：$BACKUP"
echo "   v3 为语言包驱动：改文案/换语言只需替换 App 包内 Localizable.strings，无需重编译。"
echo "   Sparkle 自动更新已关闭；如需还原官方原版运行 卸载还原.command。"
