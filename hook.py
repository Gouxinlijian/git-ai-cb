#!/usr/bin/env python3
"""git-ai-cb: 独立的 CodeBuddy AI 编码记录补录钩子。

设计目标（与 git-ai 完全隔离，互不影响）：
  1. 只在 git-ai 未捕获到编码工具时才介入，补写一条 codebuddy 记录；
  2. 绝不修改/写入 git-ai 自己的 .git/ai 目录下的任何既有产物；
  3. 记录写到独立文件 .git/ai/codebuddy-ai.log（git-ai 原版不读写该文件）。

输入：stdin 传入 CodeBuddy hook 的 JSON。
输出：无（失败时静默，保证不阻塞 CodeBuddy 工具调用）。
"""
import json
import os
import sys
import time
import hashlib
from datetime import datetime, timezone

# 版本号：优先读取同目录的 VERSION 文件，缺失时回退到内置默认值。
__version__ = "0.1.0"
try:
    _version_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "VERSION")
    if os.path.isfile(_version_file):
        with open(_version_file, "r", encoding="utf-8") as _f:
            _v = _f.read().strip()
            if _v:
                __version__ = _v
except Exception:
    pass

# CodeBuddy 中「文件编辑类」工具名（大小写不敏感）。
# 其余工具（Bash/Read/Grep/Glob/task 等）一律不记录，避免噪声。
FILE_EDIT_TOOLS = {
    "write",
    "edit",
    "multiedit",
    "notebookedit",
    "replace_in_file",
    "write_to_file",
}

# 我们自己的记录文件名，放在 .git/ai/ 下，但前缀为 codebuddy，与 git-ai 原版文件名
# （working_logs / authorship_log 等）互不冲突，git-ai 不会去读它。
RECORD_FILENAME = "codebuddy-ai.log"

# 每个 session 记录附带的最大文件数（防止 tool_input 里文件列表过长）。
MAX_FILES = 200


def _log(msg: str) -> None:
    """调试日志，默认关闭（写文件可能拖慢 hook）。可用环境变量 GIT_AI_CB_DEBUG=1 打开。"""
    if os.environ.get("GIT_AI_CB_DEBUG") == "1":
        try:
            path = os.path.join(os.path.expanduser("~"), ".git-ai-cb-debug.log")
            with open(path, "a", encoding="utf-8") as f:
                f.write("[%s] %s\n" % (datetime.now().isoformat(), msg))
        except Exception:
            pass


def read_stdin() -> dict:
    raw = sys.stdin.buffer.read()
    if not raw:
        return {}
    # 优先按 UTF-8 解码（容忍 BOM）；失败时回退 latin-1 以保证不抛异常。
    try:
        raw = raw.decode("utf-8-sig")
    except Exception:
        raw = raw.decode("latin-1", errors="ignore")
    raw = raw.strip()
    # 去掉可能包裹在 ```json ... ``` 或 ``` ... ``` 里的内容（部分工具会这样传）。
    if raw.startswith("```"):
        raw = raw.strip("`")
        if raw.startswith("json"):
            raw = raw[4:]
        raw = raw.strip()
    try:
        return json.loads(raw)
    except Exception as e:
        _log("stdin JSON 解析失败: %s, raw=%r" % (e, raw[:200]))
        return {}


def get_first(data: dict, *keys, default=None):
    for k in keys:
        v = data.get(k)
        if v is not None and v != "":
            return v
    return default


def extract_model(transcript_path: str) -> str:
    """从 Claude JSONL transcript 里解析 model，与 git-ai 的 extract_model 逻辑等价。

    优先：
      1) {"type":"session.model_change","data":{"newModel":"..."}}
      2) {"message":{"model":"..."}} 或 {"model":"..."}
    """
    if not transcript_path or not os.path.isfile(transcript_path):
        return "unknown"
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="ignore") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            # 只扫尾部 50KB（与 git-ai 的 MAX_JSONL_SCAN_BYTES 一致）
            scan = min(size, 50 * 1024)
            f.seek(max(0, size - scan))
            tail = f.read()
    except Exception:
        return "unknown"

    # 逆序逐行，找最近的 model 信息
    for line in reversed(tail.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        # 1) session.model_change
        if obj.get("type") == "session.model_change":
            m = obj.get("data", {}).get("newModel")
            if m:
                return str(m)
        # 2) message.model / model
        m = obj.get("message", {}).get("model")
        if m:
            return str(m)
        m = obj.get("model")
        if m:
            return str(m)
    return "unknown"


def collect_files(data: dict, cwd: str) -> list:
    """从 tool_input 里提取文件路径，转为绝对路径；无则返回 []。"""
    ti = data.get("tool_input") or {}
    paths = []
    if isinstance(ti, dict):
        for key in ("file_path", "filePath", "path", "old_file", "new_file"):
            v = ti.get(key)
            if isinstance(v, str) and v:
                paths.append(v)
        # notebookedit 等可能带 notebook_path
        for key in ("notebook_path",):
            v = ti.get(key)
            if isinstance(v, str) and v:
                paths.append(v)
    out = []
    seen = set()
    for p in paths:
        if not os.path.isabs(p):
            p = os.path.join(cwd or "", p)
        p = os.path.normpath(p)
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out[:MAX_FILES]


def find_git_dir(cwd: str) -> str:
    """向上查找 .git 目录（支持普通仓库与 worktree 的 .git 文件）。"""
    cur = os.path.abspath(cwd or ".")
    for _ in range(50):
        p = os.path.join(cur, ".git")
        if os.path.isdir(p):
            return p
        if os.path.isfile(p):
            # worktree：.git 是文件，内容形如 "gitdir: /path/.git/worktrees/x"
            try:
                with open(p, "r", encoding="utf-8") as f:
                    line = f.readline().strip()
                if line.startswith("gitdir:"):
                    gd = line[len("gitdir:"):].strip()
                    if os.path.isdir(gd):
                        return gd
            except Exception:
                pass
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return ""


def _dir_has_content(path: str) -> bool:
    """判断某目录是否存在『实质内容』（递归），排除空的骨架目录。

    git 环境可能在 init 时预创建 .git/ai/working_logs、.git/ai/logs 等空目录，
    这些空目录不代表 git-ai 已捕获任何代码，必须忽略。
    """
    if not os.path.isdir(path):
        return False
    try:
        for root, dirs, files in os.walk(path):
            for f in files:
                return True
    except Exception:
        pass
    return False


def git_ai_has_record(git_dir: str, session_id: str) -> bool:
    """判断 git-ai 是否已『实际捕获』编码工具，而非仅存在空骨架目录。

    判定标准（任一命中即视为 git-ai 已介入，本工具跳过）：
      1. .git/ai/working_logs 下存在实质文件（git-ai 的工作日志记录）；
      2. .git/ai/authorship_log 或 .git/ai/notes 等原生产物存在且非空；
      3. .git/ai 下存在非空的 *.log / *.json（git-ai 其它记录）。

    反过来：只有空的 working_logs/logs 骨架目录时，视为『未捕获』，本工具介入。
    """
    ai_dir = os.path.join(git_dir, "ai")
    if not os.path.isdir(ai_dir):
        return False

    # 1) working_logs 有实质内容 → 已捕获
    wl = os.path.join(ai_dir, "working_logs")
    if _dir_has_content(wl):
        return True

    # 2) 其它 git-ai 原生产物目录非空
    for marker in ("notes", "internal", "sessions", "authorship_log"):
        p = os.path.join(ai_dir, marker)
        if os.path.isdir(p) and _dir_has_content(p):
            return True
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            return True

    # 3) 非空 .log / .json 文件（git-ai 其它记录，排除我们自己的）
    try:
        entries = os.listdir(ai_dir)
    except Exception:
        return False
    for name in entries:
        if name == RECORD_FILENAME:
            continue
        p = os.path.join(ai_dir, name)
        if (name.endswith(".log") or name.endswith(".json")) and os.path.isfile(p):
            if os.path.getsize(p) > 0:
                return True
    return False


def append_record(git_dir: str, rec: dict) -> None:
    ai_dir = os.path.join(git_dir, "ai")
    try:
        os.makedirs(ai_dir, exist_ok=True)
    except Exception as e:
        _log("创建 .git/ai 失败: %s" % e)
        return
    path = os.path.join(ai_dir, RECORD_FILENAME)
    line = json.dumps(rec, ensure_ascii=False)
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception as e:
        _log("写入记录失败: %s" % e)


def main() -> None:
    data = read_stdin()
    if not data:
        return

    cwd = get_first(data, "cwd", "workingDirectory") or os.getcwd()
    transcript = get_first(data, "transcript_path", "transcriptPath")
    session_id = get_first(data, "session_id", "sessionId", default="")
    event = get_first(data, "hook_event_name", "hookEventName", default="")
    tool = get_first(data, "tool_name", "toolName", default="")

    if not isinstance(tool, str) or tool == "":
        return
    if tool.lower() not in FILE_EDIT_TOOLS:
        return

    # 定位 git 目录；不在 git 仓库里就不记录
    git_dir = find_git_dir(cwd)
    if not git_dir:
        _log("未找到 .git 目录: cwd=%s" % cwd)
        return

    # 核心判定：git-ai 已捕获则退出，不影响其任何东西
    if git_ai_has_record(git_dir, session_id):
        _log("git-ai 已捕获，跳过: git_dir=%s" % git_dir)
        return

    model = extract_model(transcript or "")
    files = collect_files(data, cwd)

    rec = {
        "agent": "codebuddy",
        "model": model,
        "tool": tool,
        "event": event,
        "session_id": session_id or "",
        "cwd": os.path.abspath(cwd),
        "files": files,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    append_record(git_dir, rec)
    _log("已补录 codebuddy 记录: %s" % json.dumps(rec, ensure_ascii=False)[:300])


if __name__ == "__main__":
    main()
