#!/usr/bin/env bash
# git-ai-cb 安装脚本：把 hook 注册进 ~/.codebuddy/settings.json。
#
# 支持两种调用方式：
#   1) 克隆后本地执行：  bash install.sh
#   2) 远程一键安装：    curl -fsSL <raw>/install.sh | bash
#      （自动下载 hook.py 等文件到固定目录 ~/.git-ai-cb/）
#
# 特性：
#   - 仅「追加」我们的 hook，绝不删除/修改已有的 hook（如 vibeinsight）。
#   - 幂等：重复执行不会重复添加。
#   - 无 python 也能执行注册（注册本身不依赖 python，hook 运行时才需要）。
set -o nounset

# 固定安装目录（远程安装时 hook 等文件落盘于此，与克隆路径解耦）
INSTALL_DIR="$HOME/.git-ai-cb"

# 远程仓库 raw 基础地址（远程安装下载用；仓库内脚本用 SCRIPT_DIR 即可）
GIT_REMOTE="https://raw.githubusercontent.com/Gouxinlijian/git-ai-cb/main"

# 需要落盘的文件清单（远程下载用）
FILES="hook.py hook.sh install.sh install.ps1 uninstall.sh update.sh status.sh VERSION git-ai-cb"

# 定位「真正的仓库目录」与「运行时 hook 目录」：
#   - 本地 clone：SCRIPT_DIR 即仓库根，hook.py 就在旁边；
#   - 远程安装：脚本通过管道执行，SCRIPT_DIR 无意义，改用 INSTALL_DIR。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${0}}")" 2>/dev/null && pwd)"

# 判断旁边是否已有 hook.py（本地 clone 场景）
if [ -f "$SCRIPT_DIR/hook.py" ]; then
  RUNTIME_DIR="$SCRIPT_DIR"
elif [ -f "$INSTALL_DIR/hook.py" ]; then
  RUNTIME_DIR="$INSTALL_DIR"
else
  RUNTIME_DIR="$INSTALL_DIR"
fi

# CodeBuddy 全局配置
CB_DIR="$HOME/.codebuddy"
SETTINGS_FILE="$CB_DIR/settings.json"

# 唯一标识：用 hook 脚本路径作为我们条目的指纹（防止重复注册）
HOOK_SCRIPT="$RUNTIME_DIR/hook.py"

# 解析 python 解释器（Windows 下 python3 可能是 Store stub，优先 python）。
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

echo "== git-ai-cb 安装 =="

# 远程自举：若旁边没有 hook.py（非 clone 场景），则从远程下载整套文件到 INSTALL_DIR
if [ ! -f "$HOOK_SCRIPT" ]; then
  echo "下载脚本到 $INSTALL_DIR ..."
  if ! command -v curl >/dev/null 2>&1; then
    echo "错误：远程安装需要 curl，但未找到。" >&2
    exit 1
  fi
  mkdir -p "$INSTALL_DIR"
  for f in $FILES; do
    if curl -fsSL "$GIT_REMOTE/$f" -o "$INSTALL_DIR/$f"; then
      :
    else
      echo "  下载失败(忽略): $f"
    fi
  done
  if [ ! -f "$INSTALL_DIR/hook.py" ]; then
    echo "错误：hook.py 下载失败，无法安装。" >&2
    exit 1
  fi
  RUNTIME_DIR="$INSTALL_DIR"
  HOOK_SCRIPT="$RUNTIME_DIR/hook.py"
fi

# 同步核心文件到 INSTALL_DIR（clone 场景也同步，保证主命令可用）
if [ "$RUNTIME_DIR" != "$INSTALL_DIR" ]; then
  mkdir -p "$INSTALL_DIR"
  for f in $FILES; do
    if [ -f "$RUNTIME_DIR/$f" ]; then
      cp "$RUNTIME_DIR/$f" "$INSTALL_DIR/$f"
    fi
  done
fi

# 安装主命令到 ~/.local/bin
LOCAL_BIN="$HOME/.local/bin"
MAIN_CMD="$INSTALL_DIR/git-ai-cb"
if [ -f "$MAIN_CMD" ]; then
  mkdir -p "$LOCAL_BIN"
  cp "$MAIN_CMD" "$LOCAL_BIN/git-ai-cb"
  chmod +x "$LOCAL_BIN/git-ai-cb" 2>/dev/null || true
  echo "主命令   : $LOCAL_BIN/git-ai-cb"
  # 提示 PATH（若未包含 ~/.local/bin）
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *) echo "提示     : 请确保 $LOCAL_BIN 在 PATH 中（可 echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc）" ;;
  esac
else
  echo "警告     : 未找到主命令 git-ai-cb，跳过命令安装"
fi

# 读取版本号（优先 INSTALL_DIR/VERSION）
VERSION=""
if [ -f "$INSTALL_DIR/VERSION" ]; then
  VERSION="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION")"
fi
[ -z "$VERSION" ] && VERSION="unknown"

echo "版本     : $VERSION"
echo "配置文件 : $SETTINGS_FILE"

if [ ! -d "$CB_DIR" ]; then
  echo "创建目录 $CB_DIR"
  mkdir -p "$CB_DIR"
fi

# 转成 Windows 绝对路径（cygpath -w 在 Git Bash 下可用），确保 CodeBuddy 在任意 shell 下都能调用。
if command -v cygpath >/dev/null 2>&1; then
  PY_WIN="$(cygpath -w "$PY")"
  HOOK_PY_WIN="$(cygpath -w "$HOOK_SCRIPT")"
else
  PY_WIN="$PY"
  HOOK_PY_WIN="$HOOK_SCRIPT"
fi

# hook command：用 python 绝对路径直接调用 hook.py。
HOOK_COMMAND="\"$PY_WIN\" \"$HOOK_PY_WIN\""

# matcher：文件编辑类工具（CodeBuddy 工具名）
MATCHER="^(Edit|Write|NotebookEdit|MultiEdit)$"

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
