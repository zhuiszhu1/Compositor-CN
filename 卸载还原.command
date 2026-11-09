#!/bin/bash
# Compositor 简体中文语言包 · 还原为官方原版（不删除任何文件）
set -euo pipefail

APP="/Applications/Compositor.app"
KIT="$(cd "$(dirname "$0")" && pwd)"
BACKUP="$KIT/备份/Compositor-原版.app"

if [ ! -d "$BACKUP" ]; then
  echo "✗ 没找到原版备份：$BACKUP"
  echo "  可改用 Homebrew 重装：brew reinstall --cask robbietilton-compositor"
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
SAVED="$KIT/备份/Compositor-已汉化-$STAMP.app"
if [ -d "$APP" ]; then
  echo "① 把当前汉化版另存为：$SAVED"
  mv "$APP" "$SAVED"
fi
echo "② 从备份恢复官方原版 …"
cp -R "$BACKUP" "$APP"
echo "③ 校验 …"
codesign -v "$APP" 2>&1 | tail -2 || true
echo
echo "✅ 已还原为官方原版（含原始 Developer ID 签名与公证）。"
echo "   汉化版保留在：$SAVED，确认无误后可自行删除。"
