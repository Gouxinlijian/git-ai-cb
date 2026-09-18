#!/usr/bin/env bash
# git-ai-cb 安装脚本：把 hook 注册进 ~/.codebuddy/settings.json。
#
# 特性：
#   - 仅「追加」我们的 hook，绝不删除/修改已有的 hook（如 vibeinsight）。
#   - 幂等：重复执行不会重复添加。
#   - 无 python 也能执行（注册本身不依赖 python，hook 运行时才需要）。
set -o nounset

# 定位本仓库目录（install.sh 就在仓库根目录）
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CodeBuddy 全局配置
CB_DIR="$HOME/.codebuddy"
SETTINGS_FILE="$CB_DIR/settings.json"

# 唯一标识：用 hook 脚本路径作为我们条目的指纹（防止重复注册）
# 这里用 hook.py 作为指纹（安装/卸载都用它识别本工具的条目）
HOOK_SCRIPT="$REPO_DIR/hook.py"

# 解析 python 解释器（Windows 下 python3 可能是 Store stub，优先 python）。
# 同时拿到它的绝对路径，写入 hook command，避免运行时 PATH 差异。
PY=""
if command -v python >/dev/null 2>&1; then
  PY="$(command -v python)"
elif command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3)"
elif command -v python3.12 >/dev/null 2>&1; then
  PY="$(command -v python3.12)"
else
  echo "错误：未找到 python 解释器，无法安装。" >&2
  exit 1
fi

# 转成 Windows 绝对路径（cygpath -w 在 Git Bash 下可用），确保 CodeBuddy 在任意 shell 下都能调用。
# 若 cygpath 不可用（纯 Linux/macOS），原样使用。
if command -v cygpath >/dev/null 2>&1; then
  PY_WIN="$(cygpath -w "$PY")"
  HOOK_PY_WIN="$(cygpath -w "$HOOK_SCRIPT")"
else
  PY_WIN="$PY"
  HOOK_PY_WIN="$HOOK_SCRIPT"
fi

# hook command：用 python 绝对路径直接调用 hook.py。
# Python 脚本内部已用 sys.stdin.buffer.read() + utf-8-sig 处理 stdin，无编码问题。
HOOK_COMMAND="\"$PY_WIN\" \"$HOOK_PY_WIN\""

# matcher：文件编辑类工具（CodeBuddy 工具名）
MATCHER="^(Edit|Write|NotebookEdit|MultiEdit)$"

echo "== git-ai-cb 安装 =="
echo "仓库目录 : $REPO_DIR"
echo "配置文件 : $SETTINGS_FILE"

if [ ! -d "$CB_DIR" ]; then
  echo "创建目录 $CB_DIR"
  mkdir -p "$CB_DIR"
fi

# 用 python 做 JSON 的安全读写（避免 shell 拼 JSON 出错）
"$PY" - "$SETTINGS_FILE" "$HOOK_SCRIPT" "$HOOK_COMMAND" "$MATCHER" <<'PYEOF'
import json, os, sys

settings_file = sys.argv[1]
hook_script = sys.argv[2]
hook_command = sys.argv[3]
matcher = sys.argv[4]

data = {}
if os.path.isfile(settings_file):
    with open(settings_file, "r", encoding="utf-8") as f:
        content = f.read()
    if content.strip():
        try:
            data = json.loads(content)
        except Exception as e:
            print("错误：无法解析现有 settings.json：%s" % e)
            sys.exit(1)

if not isinstance(data, dict):
    data = {}

# 确保 hooks 结构存在
hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    hooks = {}
    data["hooks"] = hooks

# 事件列表：PostToolUse 用于「写完后」补录（也注册 PreToolUse 以提前判定位）。
events = ["PreToolUse", "PostToolUse"]
registered = []

# 判定某条 command 是否属于本工具。
# 指纹：command 中同时包含 "git-ai-cb" 和 "hook"（与具体绝对路径/正反斜杠无关，兼容幂等）。
def is_ours(cmd):
    if not cmd:
        return False
    # 统一分隔符后判断，兼容 Windows 反斜杠与 Git Bash 正斜杠
    norm = cmd.replace("\\", "/")
    return ("git-ai-cb" in norm) and ("hook" in norm)

# 先检查是否已注册（通过指纹识别我们的条目）
def already_registered(evt):
    entries = hooks.get(evt)
    if entries is None:
        return False
    if isinstance(entries, list):
        for e in entries:
            if not isinstance(e, dict):
                continue
            cmd = e.get("command")
            if cmd and is_ours(cmd):
                return True
            # 也检查嵌套 hooks 结构（有些版本的 settings 结构不同）
            sub = e.get("hooks")
            if isinstance(sub, list):
                for s in sub:
                    if isinstance(s, dict) and is_ours(s.get("command") or ""):
                        return True
    elif isinstance(entries, dict):
        sub = entries.get("hooks")
        if isinstance(sub, list):
            for s in sub:
                if isinstance(s, dict) and is_ours(s.get("command") or ""):
                    return True
    return False

# 追加条目：兼容两种结构
#  结构A（新版）：hooks.PreToolUse = [ { "matcher": "...", "hooks": [ {"type":"command","command":"..."} ] } ]
#  结构B（旧版/简版）：hooks.PreToolUse = [ { "matcher":"...", "command":"..." } ]
def add_entry(evt):
    if already_registered(evt):
        return False
    entries = hooks.get(evt)
    if entries is None:
        entries = []
        hooks[evt] = entries

    new_entry = {
        "matcher": matcher,
        "hooks": [
            {"type": "command", "command": hook_command}
        ],
    }
    # 判断现有条目用的结构，保持一致
    use_flat = True
    if isinstance(entries, list):
        for e in entries:
            if isinstance(e, dict) and "hooks" in e:
                use_flat = False
                break
    if use_flat:
        new_entry = {"matcher": matcher, "command": hook_command}

    if isinstance(entries, list):
        entries.append(new_entry)
    return True

for evt in events:
    if add_entry(evt):
        registered.append(evt)

# 写回（保留原缩进风格，使用 2 空格）
with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

if registered:
    print("已注册 hook 事件: %s" % ", ".join(registered))
else:
    print("hook 已存在，无需重复注册（幂等）")

print("安装完成。重启 CodeBuddy 后生效。")
PYEOF
