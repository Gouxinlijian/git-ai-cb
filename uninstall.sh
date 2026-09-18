#!/usr/bin/env bash
# git-ai-cb 卸载脚本：只移除本工具注册的 hook 条目，绝不改动其他 hook（如 vibeinsight）。
set -o nounset

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB_DIR="$HOME/.codebuddy"
SETTINGS_FILE="$CB_DIR/settings.json"

PY=""
if command -v python >/dev/null 2>&1; then
  PY="python"
elif command -v python3 >/dev/null 2>&1; then
  PY="python3"
elif command -v python3.12 >/dev/null 2>&1; then
  PY="python3.12"
else
  echo "错误：未找到 python 解释器，无法卸载。" >&2
  exit 1
fi

echo "== git-ai-cb 卸载 =="

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "未找到 $SETTINGS_FILE，无需卸载。"
  exit 0
fi

"$PY" - "$SETTINGS_FILE" <<'PYEOF'
import json, os, sys

settings_file = sys.argv[1]

with open(settings_file, "r", encoding="utf-8") as f:
    data = json.loads(f.read())

hooks = data.get("hooks", {})
removed = []

# 与 install.sh 一致的指纹：同时含 "git-ai-cb" 和 "hook"（路径/斜杠无关）
def is_ours(cmd):
    if not cmd:
        return False
    norm = cmd.replace("\\", "/")
    return ("git-ai-cb" in norm) and ("hook" in norm)

for evt in list(hooks.keys()):
    entries = hooks.get(evt)
    if not isinstance(entries, list):
        continue
    kept = []
    changed = False
    for e in entries:
        if not isinstance(e, dict):
            kept.append(e)
            continue
        cmd = e.get("command") or ""
        sub = e.get("hooks")
        # 顶层 command 命中，或嵌套 hooks 里的 command 命中
        top_is_ours = is_ours(cmd)
        if isinstance(sub, list):
            sub_kept = [s for s in sub if not (isinstance(s, dict) and is_ours(s.get("command") or ""))]
            if len(sub_kept) != len(sub):
                e["hooks"] = sub_kept
                changed = True
                # 子项全被删除，且顶层无自己的 command → 整条丢弃
                if len(sub_kept) == 0 and not top_is_ours:
                    continue
        if top_is_ours and (not sub or len(sub) == 0):
            # 本条是全匹配本工具 → 丢弃
            changed = True
            continue
        kept.append(e)
    if len(kept) != len(entries):
        hooks[evt] = kept
        removed.append(evt)
    elif changed:
        hooks[evt] = kept

# 清理空的事件键
for evt in list(hooks.keys()):
    if isinstance(hooks[evt], list) and len(hooks[evt]) == 0:
        del hooks[evt]

with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

if removed:
    print("已移除 hook 事件: %s" % ", ".join(removed))
else:
    print("未找到本工具注册的 hook，可能已卸载。")

print("卸载完成。重启 CodeBuddy 后生效。")
PYEOF
