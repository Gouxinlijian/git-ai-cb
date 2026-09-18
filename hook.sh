#!/usr/bin/env bash
# git-ai-cb hook 薄封装入口（由 CodeBuddy hook 调用）。
# 负责把 stdin 转交给 hook.py 处理。需要 python3（或 python）可用。
set -o nounset

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 选择 python 解释器。
# 注意：Windows 下 `python3` 可能是 Microsoft Store 的占位 stub（无输出），
# 所以优先用 `python`，再回退到 `python3` / `python3.12`。
PY=""
if command -v python >/dev/null 2>&1; then
  PY=python
elif command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python3.12 >/dev/null 2>&1; then
  PY=python3.12
else
  # 无 python，静默退出，不阻塞 CodeBuddy
  exit 0
fi

# 把 stdin 原样交给 python 脚本。hook 的 JSON 通过 stdin 传入。
"$PY" "$SCRIPT_DIR/hook.py"
