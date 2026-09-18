#!/usr/bin/env python3
"""git-ai-cb: 把 CodeBuddy 的编辑事件「喂」给 git-ai，使 `git-ai stats` 能统计到。

设计目标：
  1. 不修改 git-ai 任何代码；
  2. CodeBuddy 产生文件编辑时，把事件转换成 git-ai `claude` preset 能识别的
     hook 输入，并调用 `git-ai checkpoint claude --hook-input stdin`；
  3. git-ai 会把 checkpoint 写进它自己的 working_log，提交时由它自带的
     post-commit 钩子转成 git note，`git-ai stats` 即可统计到 AI 行数。

模型采集：
  CodeBuddy 的 hook 输入带有 `model` 字段（如 "custom-local:deepseek-v4-pro"），
  而 git-ai 的 claude preset 只从 `transcript_path` 指向的 Claude JSONL 解析模型。
  因此这里生成一个临时 Claude JSONL（含 {"message":{"model":"<真实模型>"}}），
  把 `transcript_path` 指向它，让 git-ai 的 extract_model 正确解析出模型名。

输入：stdin 传入 CodeBuddy hook 的 JSON。
输出：无（失败时静默，保证不阻塞 CodeBuddy 工具调用）。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

# 版本号：优先读取同目录的 VERSION 文件，缺失时回退到内置默认值。
__version__ = "0.2.0"
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

# 临时 transcript 目录：用来存放给 git-ai 解析模型的 Claude JSONL。
TMP_TRANSCRIPT_DIR = os.path.join(tempfile.gettempdir(), "git-ai-cb-transcripts")


def _log(msg: str) -> None:
    """调试日志，默认关闭。可用环境变量 GIT_AI_CB_DEBUG=1 打开。"""
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
    try:
        raw = raw.decode("utf-8-sig")
    except Exception:
        raw = raw.decode("latin-1", errors="ignore")
    # 兼容部分渠道额外包裹的 BOM 字符。
    raw = raw.lstrip("\ufeff")
    raw = raw.strip()
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


def locate_git_binary():
    """定位 git 可执行文件：优先 PATH，其次常见的 Program Files 路径。"""
    git = shutil.which("git")
    if git:
        return git
    candidates = [
        r"C:\Program Files\Git\cmd\git.exe",
        r"C:\Program Files\Git\bin\git.exe",
        r"C:\Program Files (x86)\Git\cmd\git.exe",
        "/usr/bin/git",
        "/usr/local/bin/git",
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return "git"


def cmd_git_ai():
    """返回调用 git-ai 的命令行形式。

    注意：必须用不带 `.EXE` 后缀的小写命令名 `git-ai`，而不是完整路径
    （如 `C:\\...\\git-ai.EXE`）。git-ai 是个 git proxy，当 argv[0] 以大写
    `.EXE` 结尾时，它会误判为 git 转发，导致 `checkpoint` 被当作 git 子命令
    报 `git: 'checkpoint' is not a git command`。用裸命令名让 shell 解析即可。
    """
    if shutil.which("git-ai"):
        return "git-ai"
    return None


def find_git_dir(start: str) -> str:
    """向上查找 .git 目录（支持普通仓库与 worktree 的 .git 文件）。"""
    cur = os.path.abspath(start or ".")
    if os.path.isfile(cur):
        cur = os.path.dirname(cur)
    for _ in range(50):
        p = os.path.join(cur, ".git")
        if os.path.isdir(p):
            return p
        if os.path.isfile(p):
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


def normalize_model(model: str) -> str:
    """从 CodeBuddy 的 model 字段提取真实模型名。

    CodeBuddy 形如 "custom-local:deepseek-v4-pro"，git-ai 只关心冒号后的真实模型。
    若没有冒号则原样返回。
    """
    if not model:
        return "unknown"
    model = str(model).strip()
    if model == "":
        return "unknown"
    # "custom-local:deepseek-v4-pro" -> "deepseek-v4-pro"
    if ":" in model:
        return model.rsplit(":", 1)[-1].strip() or "unknown"
    return model


def write_temp_transcript(model: str, session_id: str) -> str:
    """生成一个临时 Claude JSONL，写入模型信息供 git-ai 的 extract_model 解析。

    git-ai 的 extract_model_from_jsonl_line 识别两种行：
      1) {"type":"session.model_change","data":{"newModel":"..."}}
      2) {"message":{"model":"..."}} 或 {"model":"..."}
    返回临时文件路径。
    """
    try:
        os.makedirs(TMP_TRANSCRIPT_DIR, exist_ok=True)
    except Exception as e:
        _log("创建临时 transcript 目录失败: %s" % e)
        return ""
    sid = (session_id or "session").replace(os.sep, "_").replace(":", "_")
    path = os.path.join(TMP_TRANSCRIPT_DIR, "%s.jsonl" % sid)
    line = json.dumps({"message": {"model": model}}, ensure_ascii=False)
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception as e:
        _log("写临时 transcript 失败: %s" % e)
        return ""
    return path


def build_claude_hook_input(data: dict) -> dict:
    """把 CodeBuddy hook 数据转成 git-ai claude preset 可识别的结构。

    claude preset 需要的字段：
      - transcript_path（必须）：用于 extract_model 解析模型 + 原样记录
      - cwd（必须）
      - tool_name / hook_event_name（可选，决定 FileEdit vs Bash）
      - session_id（可选）
      - tool_input.file_path（提取文件路径；file_paths_from_tool_input 认 file_path）
    """
    cwd = get_first(data, "cwd", "workingDirectory") or os.getcwd()
    session_id = get_first(data, "session_id", "sessionId", default="")
    event = get_first(data, "hook_event_name", "hookEventName", default="PostToolUse")
    tool = get_first(data, "tool_name", "toolName", default="")
    raw_model = get_first(data, "model", default="")
    model = normalize_model(raw_model)

    # 生成指向临时 Claude JSONL 的 transcript_path，让 git-ai 解析出正确模型。
    transcript_path = write_temp_transcript(model, session_id)

    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        ti = {}
    # CodeBuddy 用 filePath（大写驼峰），git-ai 认 file_path。转成 file_path。
    out_tool_input = {}
    for key in ("file_path", "filePath", "path"):
        v = ti.get(key)
        if isinstance(v, str) and v:
            out_tool_input["file_path"] = v
            break

    out = {
        "transcript_path": transcript_path or "",
        "cwd": os.path.abspath(cwd),
        "hook_event_name": event,
        "tool_name": tool,
        "session_id": session_id,
        "tool_input": out_tool_input,
    }
    return out


def main() -> None:
    data = read_stdin()
    if not data:
        return

    tool = get_first(data, "tool_name", "toolName", default="")
    if not isinstance(tool, str) or tool == "":
        return
    if tool.lower() not in FILE_EDIT_TOOLS:
        return

    # 定位 git 目录：CodeBuddy IDE 传的 cwd 可能是 IDE 安装目录，
    # 优先用「被编辑文件」的路径定位 .git，找不到再回退到 cwd。
    cwd = get_first(data, "cwd", "workingDirectory") or os.getcwd()
    ti = data.get("tool_input") or {}
    file_path = ""
    if isinstance(ti, dict):
        file_path = ti.get("file_path") or ti.get("filePath") or ti.get("path") or ""

    git_dir = ""
    for base in ([file_path] if file_path else []) + [cwd]:
        gd = find_git_dir(base)
        if gd:
            git_dir = gd
            break
    if not git_dir:
        _log("未找到 .git 目录: cwd=%s file=%s" % (cwd, file_path))
        return

    # 调用 git-ai checkpoint claude，让它自己写 working_log。
    git_ai = cmd_git_ai()
    if not git_ai:
        _log("未找到 git-ai 可执行文件")
        return

    claude_input = build_claude_hook_input(data)
    payload = json.dumps(claude_input, ensure_ascii=False)

    workdir = os.path.dirname(git_dir) or cwd
    try:
        proc = subprocess.run(
            [git_ai, "checkpoint", "claude", "--hook-input", "stdin"],
            input=payload.encode("utf-8"),
            cwd=workdir,
            capture_output=True,
            timeout=15,
        )
    except FileNotFoundError:
        _log("git-ai 执行失败（找不到文件）: %s" % git_ai)
        return
    except subprocess.TimeoutExpired:
        _log("git-ai checkpoint 超时")
        return
    except Exception as e:
        _log("git-ai checkpoint 异常: %s" % e)
        return

    if proc.returncode != 0:
        _log(
            "git-ai checkpoint 返回 %s\n  stdout=%s\n  stderr=%s"
            % (proc.returncode, proc.stdout.decode("utf-8", "ignore")[:500],
               proc.stderr.decode("utf-8", "ignore")[:500])
        )
        return

    _log("已提交 checkpoint: model=%s files=%s" % (normalize_model(get_first(data, "model", default="")), file_path))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        try:
            with open(os.path.join(os.path.expanduser("~"), ".git-ai-cb-debug.log"), "a", encoding="utf-8") as _ef:
                _ef.write("[%s] hook 异常: %s\n" % (datetime.now().isoformat(), e))
        except Exception:
            pass
