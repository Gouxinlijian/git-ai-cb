#!/usr/bin/env bash
# git-ai-cb 更新脚本：拉取/下载最新代码后重新执行安装。
#
# 用法（通常通过主命令 git-ai-cb update 调用）：
#   bash update.sh                 # 克隆目录本地执行（git pull）或已安装目录
#   bash update.sh <ref>           # 可选：切换到指定 tag/branch 后安装（仅克隆目录有效）
set -o nounset

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${0}}")" 2>/dev/null && pwd)"
INSTALL_DIR="$HOME/.git-ai-cb"
GIT_REMOTE="https://raw.githubusercontent.com/Gouxinlijian/git-ai-cb/main"
FILES="hook.py hook.sh install.sh install.ps1 uninstall.sh update.sh status.sh VERSION git-ai-cb git-ai-cb.cmd"

echo "== git-ai-cb 更新 =="

# 判断运行上下文
if [ -d "$SCRIPT_DIR/.git" ]; then
  # 克隆目录：git pull + 可选切换 ref
  echo "拉取最新代码..."
  git -C "$SCRIPT_DIR" pull --ff-only 2>/dev/null || {
    echo "警告：git pull 失败（可能无网络或非 git 环境），跳过拉取，使用当前代码。"
  }
  if [ $# -ge 1 ]; then
    ref="$1"
    echo "切换到: $ref"
    git -C "$SCRIPT_DIR" checkout "$ref" 2>/dev/null || echo "警告：无法切换到 $ref"
  fi
  # 同步本地 clone 内容到安装目录
  if [ -f "$SCRIPT_DIR/hook.py" ]; then
    mkdir -p "$INSTALL_DIR"
    for f in $FILES; do
      if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
      fi
    done
    echo "已同步文件到 $INSTALL_DIR"
  fi
else
  # 远程/已安装目录：直接下载整套最新文件到 INSTALL_DIR
  echo "下载最新文件到 $INSTALL_DIR ..."
  if ! command -v curl >/dev/null 2>&1; then
    echo "错误：远程更新需要 curl。" >&2
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
    echo "错误：hook.py 下载失败。" >&2
    exit 1
  fi
fi

# 重新安装（install.sh 幂等，且会把主命令同步到 ~/.local/bin）
echo "重新执行安装..."
bash "$INSTALL_DIR/install.sh"

echo "更新完成。当前版本：$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION" 2>/dev/null || echo unknown)"
