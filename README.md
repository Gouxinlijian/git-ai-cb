# git-ai-cb

独立、可下载安装的 **CodeBuddy AI 编码补录钩子**。

它不改造 [git-ai](https://github.com/git-ai-project/git-ai) 原版代码，与其**完全隔离**。作用只有一个：
**当 CodeBuddy 产生文件编辑时，把编辑事件转成 git-ai 能识别的 checkpoint，喂给 git-ai，
使 `git-ai stats` 能把这些编辑统计为 AI 行数。**

## 核心思路

git-ai 自带多个「agent preset」（`claude`、`cursor`、`codex` 等），但没有 CodeBuddy preset。
本工具借用一个现成 preset 的入口，把 CodeBuddy 的编辑事件翻译成该 preset 的 hook 输入，
再调用 `git-ai checkpoint <preset> --hook-input stdin`，让 git-ai 自己写 working_log。

选用的 preset 是 **`claude`**，模型名取自 CodeBuddy hook 输入的 `model` 字段
（如 `custom-local:deepseek-v4-pro` → `deepseek-v4-pro`），最终在 `git-ai stats` 中显示为
`claude::deepseek-v4-pro`。

> 为什么是 `claude`：git-ai 所有 preset 的工具名都硬编码（无 `codebuddy`），
> 不改源码的前提下，`claude` 是接口最贴合 CodeBuddy 结构的一个。tool 名用的是
> `claude`，但**模型名是真实的**，不会误报。

## 数据流

```
CodeBuddy 工具（Edit / Write / MultiEdit / NotebookEdit）
    │  PostToolUse hook（hook.py）
    ▼
hook.py 解析 stdin，生成临时 Claude JSONL（含真实模型名）
    │
    ▼
git-ai checkpoint claude --hook-input stdin
    │  （写入 git-ai 自己的 working_logs/<base_commit>/checkpoints.jsonl）
    ▼
git 提交 → git-ai 的 post-commit hook 把 working_log 转成 git note（refs/notes/ai）
    │
    ▼
git-ai stats / git-ai log / git-ai blame 显示 AI 行数
```

## 目录结构

```
git-ai-cb/
├── git-ai-cb        # 主命令（安装后为 ~/.local/bin/git-ai-cb）
├── hook.py          # 核心逻辑（解析 stdin、转换并调用 git-ai checkpoint）——install 后 CodeBuddy 直接调用它
├── hook.sh          # Git Bash 薄封装入口（可选：手动调用时用）
├── install.sh       # 安装（Unix / Linux / macOS / Git Bash）
├── install.ps1      # 安装（Windows PowerShell，自动定位 bash）
├── uninstall.sh     # 卸载：移除本工具的 hook 条目
├── update.sh        # 更新：拉最新后重新安装
├── status.sh        # 状态：查看版本、是否已安装、python 依赖
├── VERSION          # 版本号（如 0.2.0）
└── README.md
```

## 版本

版本号定义在仓库根目录的 `VERSION` 文件（当前 `0.2.0`）。
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

> 前置依赖：git-ai 已安装且 `git-ai` 命令在 PATH 中。若 git-ai 未安装，
> hook 会静默不生效（不阻塞 CodeBuddy）。

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
   hook 收到 stdin JSON（含 `cwd`、`session_id`、`tool_name`、`tool_input.file_path`、`model` 等）。
2. `hook.py` 解析后：
   - 只处理**文件编辑类**工具，忽略 `Bash`/`Read`/`Grep`/`Glob` 等；
   - 定位 `.git` 目录（优先用被编辑文件路径），若不在 git 仓库则忽略；
   - 从 `model` 字段提取真实模型名（`custom-local:deepseek-v4-pro` → `deepseek-v4-pro`）；
   - 生成一个临时 Claude JSONL（`{"message":{"model":"<模型>"}}`），
     因为 git-ai 的 `claude` preset 只从 `transcript_path` 指向的 JSONL 解析模型；
   - 用 `git-ai checkpoint claude --hook-input stdin` 提交 checkpoint。
3. git-ai 把 checkpoint 写进自己的 working_log，提交时由它自带的 post-commit hook
   转成 git note，`git-ai stats` 即可看到 `claude::deepseek-v4-pro` 的 AI 行数。

## 验证

安装并完成一次 CodeBuddy 编辑、`git commit` 后：

```bash
git-ai stats            # 应看到 AI 占比（tool_model_breakdown 里有 claude::<模型>）
git-ai stats --json     # 查看结构化结果，确认 tool_model_breakdown
git-ai log              # 查看各提交的 AI 行数占比
```

## 前置依赖

- `bash`（Windows 用 Git Bash）
- `python`（或 `python3`），用于 JSON 解析与记录写入
- `git-ai`（已安装、`git-ai` 命令在 PATH 中）

## 调试

设置环境变量后，hook 会输出调试日志到 `~/.git-ai-cb-debug.log`：

```bash
export GIT_AI_CB_DEBUG=1
```

## 说明

- 本工具只对 **CodeBuddy** 有效（通过 CodeBuddy 的 `settings.json` hook 机制注入），
  其他 AI 工具继续使用 git-ai 原版，不受任何影响。
- 本工具**不写 git-ai 的任何私有文件**，只调用 git-ai 公开的 `checkpoint` 命令，
  由 git-ai 自己负责 working_log 与 git note 的写入与归档，互不干扰、可随 git-ai 升级平滑兼容。
