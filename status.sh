#!/usr/bin/env bash
# git-ai-cb 状态查询：查看是否已安装、版本号、python 依赖等。
# 用法：
#   bash status.sh
#   curl -fsSL <raw>/status.sh | bash
set -o nounset

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${0}}")" 2>/dev/null && pwd)"
INSTALL_DIR="$HOME/.git-ai-cb"
CB_DIR="$HOME/.codebuddy"
SETTINGS_FILE="$CB_DIR/settings.json"

# 定位本地版本来源：克隆目录优先，其次安装目录
VER_FILE=""
for d in "$SCRIPT_DIR" "$INSTALL_DIR"; do
  if [ -f "$d/VERSION" ]; then
    VER_FILE="$d/VERSION"
    break
  fi
done

echo "== git-ai-cb 状态 =="

# 1) 版本
if [ -n "$VER_FILE" ]; then
  echo "版本     : $(tr -d '[:space:]' < "$VER_FILE")  (来自 $VER_FILE)"
else
  echo "版本     : 未检测到 VERSION 文件"
fi

# 2) python 解释器
PY=""
if command -v python >/dev/null 2>&1; then
  PY="python"
elif command -v python3 >/dev/null 2>&1; then
  PY="python3"
elif command -v python3.12 >/dev/null 2>&1; then
  PY="python3.12"
fi
if [ -n "$PY" ]; then
  echo "python   : $PY -> $(command -v "$PY")"
else
  echo "python   : 未找到（hook 运行时将静默失效）"
fi

# 3) hook 脚本落盘情况
if [ -f "$INSTALL_DIR/hook.py" ]; then
  echo "hook.py  : $INSTALL_DIR/hook.py"
elif [ -f "$SCRIPT_DIR/hook.py" ]; then
  echo "hook.py  : $SCRIPT_DIR/hook.py"
else
  echo "hook.py  : 未落盘"
fi

# 4) 是否已注册到 settings.json
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "注册状态 : 未配置（$SETTINGS_FILE 不存在）"
  exit 0
fi

if [ -n "$PY" ]; then
  "$PY" - "$SETTINGS_FILE" <<'PYEOF'
import json, sys

settings_file = sys.argv[1]
try:
    with open(settings_file, "r", encoding="utf-8") as f:
        data = json.loads(f.read())
except Exception as e:
    print("注册状态 : 无法解析 settings.json：%s" % e)
    sys.exit(0)

hooks = data.get("hooks", {}) if isinstance(data, dict) else {}

def is_ours(cmd):
    if not cmd:
        return False
    norm = cmd.replace("\\", "/")
    return ("git-ai-cb" in norm) and ("hook" in norm)

found = []
for evt, entries in hooks.items():
    if not isinstance(entries, list):
        continue
    for e in entries:
        if not isinstance(e, dict):
            continue
        if is_ours(e.get("command") or ""):
            found.append(evt)
            continue
        sub = e.get("hooks")
        if isinstance(sub, list):
            for s in sub:
                if isinstance(s, dict) and is_ours(s.get("command") or ""):
                    found.append(evt)
                    break

if found:
    print("注册状态 : 已安装")
    print("注册事件 : %s" % ", ".join(sorted(set(found))))
else:
    print("注册状态 : 未安装")
PYEOF
else
  echo "注册状态 : 无法检测（缺少 python）"
fi

echo "说明     : 后台运行是否生效，可查看 ~/.git-ai-cb-debug.log（需 GIT_AI_CB_DEBUG=1）"
