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
├── hook.py          # 核心逻辑（解析 stdin、判定、写记录）——install 后 CodeBuddy 直接调用它
├── hook.sh          # Git Bash 薄封装入口（可选：手动调用时用）
├── install.sh       # 安装：追加 hook 到 ~/.codebuddy/settings.json（幂等）
├── uninstall.sh     # 卸载：移除本工具的 hook 条目
├── update.sh        # 更新：git pull 后重新安装
└── README.md
```

## 安装

```bash
# 1. 克隆（使用你自己的 SSH 配置）
git clone git@github.com:Gouxinlijian/git-ai-cb.git
cd git-ai-cb

# 2. 安装（会写入 ~/.codebuddy/settings.json）
bash install.sh
```

重启 CodeBuddy 后生效。

## 更新

```bash
cd git-ai-cb
bash update.sh          # 拉最新 + 重新安装
# 或指定版本
bash update.sh v1.2.0
```

## 卸载

```bash
cd git-ai-cb
bash uninstall.sh
```

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
