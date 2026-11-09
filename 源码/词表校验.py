#!/usr/bin/env python3
# 词表完整性校验（以后 AI 维护词表的门禁）
# 校验对象：源码里所有显式查表点 L("…") 的 key —— 这是语言包驱动的显式依赖，
# 每一个都必须在 Localizable.strings 里有词条，否则该处界面回退英文。
# （SwiftUI 字面量/字面量插值的自动查表覆盖，以上一轮的 1574 条全量词表为准，不在此重复提取。）
# 用法：python3 源码/词表校验.py
import re, pathlib, subprocess, json, sys

KIT = pathlib.Path(__file__).resolve().parent.parent
SRC = KIT / "源码/Compositor"
STRINGS = KIT / "zh-Hans.lproj/Localizable.strings"

l_keys = {}   # key -> [(file, line)]
L_re = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"\s*\)')
for f in sorted(SRC.rglob("*.swift")):
    rel = str(f.relative_to(SRC))
    for i, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
        s = line.strip()
        if s.startswith("//"): continue
        for m in L_re.finditer(line):
            l_keys.setdefault(m.group(1), []).append(f"{rel}:{i}")

raw = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(STRINGS)])
table = json.loads(raw)

missing = {k: v for k, v in l_keys.items() if k not in table}
print(f"L() 显式 key 总数: {len(l_keys)}（去重后 {len(set(l_keys))} 个），词表 key: {len(table)}")
print(f"词表缺失: {len(missing)}")
for k, where in sorted(missing.items()):
    print(f"  ✗ [{k}]  ← {', '.join(where[:3])}")
if not missing:
    print("✅ 全部 L() key 都有词条")
sys.exit(1 if missing else 0)
