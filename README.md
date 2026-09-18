# git-ai-cb

独立、可下载安装的 **CodeBuddy AI 编码补录钩子**。

它不改造 [git-ai](https://github.com/git-ai-project/git-ai) 原版，与其**完全隔离**。作用只有一个：
**当 git-ai 没有捕获到编码工具时**（例如你用的是 CodeBuddy，而非 git-ai 支持的 agent），
补写一条记录，标明「这段代码由 `codebuddy` + 某个模型编写」。

## 设计原则

- **只在 git-ai 未捕获时介入**：检查仓库 `.git/ai/` 下是否存在 git-ai 原生产物
  （`working_logs` / `authorship_log` / `notes` 等）。存在 → 本工具什么都不做。
- **绝不写脏 git-ai 的任何文件**：记录写到独立文件 `.git/ai/codebuddy-ai.log`，
  git-ai 原版不读取、不认识该文件，互不干扰。
- **卸载干净**：只移除本工具自己注册的 hook 条目，不动你已有的其他 hook
  （如 `vibeinsight`）。

## 目录结构

```
git-ai-cb/
├── git-ai-cb        # 主命令（安装后为 ~/.local/bin/git-ai-cb）
├── hook.py          # 核心逻辑（解析 stdin、判定、写记录）——install 后 CodeBuddy 直接调用它
├── hook.sh          # Git Bash 薄封装入口（可选：手动调用时用）
├── install.sh       # 安装（Unix / Linux / macOS / Git Bash）
├── install.ps1      # 安装（Windows PowerShell，自动定位 bash）
├── uninstall.sh     # 卸载：移除本工具的 hook 条目
├── update.sh        # 更新：拉最新后重新安装
├── status.sh        # 状态：查看版本、是否已安装、python 依赖
├── VERSION          # 版本号（如 0.1.0）
└── README.md
```

## 版本

版本号定义在仓库根目录的 `VERSION` 文件（当前 `0.1.0`）。
`hook.py` 会读取该文件作为 `__version__`，主命令及各脚本也会读取它用于展示。
升级时只需修改 `VERSION`。

## 安装（唯一一步用命令，跨平台）

### Windows（PowerShell / PowerShell Core）

```powershell
irm https://raw.githubusercontent.com/Gouxinlijian/git-ai-cb/main/install.ps1 | iex
```

`install.ps1` 会自动定位 Git Bash 的 `bash.exe`（多路径 + 从 git 逆向推导 + 注册表兜底），
无需手动把 bash 加进 PATH。

### Linux / macOS / Git Bash

```bash
curl -fsSL https://raw.githubusercontent.com/Gouxinlijian/git-ai-cb/main/install.sh | bash
```

脚本会：
1. 把 `hook.py` 等文件下载到 `~/.git-ai-cb/`；
2. 把主命令 `git-ai-cb` 安装到 `~/.local/bin/`；
3. 将 hook 注册进 `~/.codebuddy/settings.json`。

> 若 `~/.local/bin` 不在 PATH 中，请先执行：
> `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc` 并重开终端。

重启 CodeBuddy 后生效。

## 日常命令（安装后，无需再 curl）

Git Bash、Linux、macOS 与 Windows PowerShell / cmd 下均可直接调用：

```bash
git-ai-cb -v                 # 查看版本
git-ai-cb status            # 查看安装状态（版本 / python / 落盘 / 是否注册）
git-ai-cb install           # 重新安装（幂等）
git-ai-cb update            # 更新到最新
git-ai-cb uninstall         # 卸载
git-ai-cb help              # 帮助
```

> Windows 下：安装会同时写入 `~/.local/bin/git-ai-cb`（bash 脚本，供 Git Bash 用）
> 和 `~/.local/bin/git-ai-cb.cmd`（CMD 包装，供 PowerShell / cmd 用），确保两种 shell 都能识别。

## 卸载

```bash
git-ai-cb uninstall
```

卸载只移除本工具注册的 hook 条目；如想彻底清理，可再删除 `~/.git-ai-cb/` 目录
和 `~/.local/bin/git-ai-cb`。

## 工作原理

1. CodeBuddy 触发文件编辑类工具（`Edit` / `Write` / `NotebookEdit` / `MultiEdit`）时，
   hook 收到 stdin JSON（含 `cwd`、`transcript_path`、`tool_name`、`session_id` 等）。
2. `hook.py` 解析后：
   - 只处理**文件编辑类**工具，忽略 `Bash`/`Read`/`Grep`/`Glob` 等；
   - 定位 `.git` 目录，若不在 git 仓库则忽略；
   - 检查 `.git/ai/` 是否已有 git-ai 记录 → **有则跳过**；
   - 否则从 transcript（Claude JSONL）解析模型名，写入一条记录。

## 记录格式

写入 `.git/ai/codebuddy-ai.log`，每行一条 JSON：

```json
{
  "agent": "codebuddy",
  "model": "deepseek-v4.1-flash",
  "tool": "Edit",
  "event": "PostToolUse",
  "session_id": "76a3b900a5ed4f4cb24ac9de145dcade",
  "cwd": "/path/to/repo",
  "files": ["/path/to/repo/src/foo.ts"],
  "timestamp": "2026-09-18T02:00:00+00:00"
}
```

## 前置依赖

- `bash`（Windows 用 Git Bash）
- `python3`（或 `python`），用于 JSON 解析与记录写入

## 调试

设置环境变量后，hook 会输出调试日志到 `~/.git-ai-cb-debug.log`：

```bash
export GIT_AI_CB_DEBUG=1
```

## 说明

- 本工具只对 **CodeBuddy** 有效（通过 CodeBuddy 的 `settings.json` hook 机制注入），
  其他 AI 工具继续使用 git-ai 原版，不受任何影响。
- 「补录」是**轻量可读记录**，不追求复刻 git-ai 的 hash 归因体系（`authorship/3.0.0`），
  因此 git-ai 自身的 `git-ai` 命令不会读取这些记录——这正是「互不影响」的体现。
