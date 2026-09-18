#!/usr/bin/env bash
# git-ai-cb 更新脚本：拉取最新代码（git pull）后重新执行安装。
# 用法：
#   bash update.sh            # 在当前仓库目录执行
#   bash update.sh <ref>      # 可选：切换到指定 tag/branch 后安装
set -o nounset

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR" || exit 1

echo "== git-ai-cb 更新 =="

# 若目录是 git 仓库且能访问远程，执行 pull
if [ -d ".git" ]; then
  echo "拉取最新代码..."
  git pull --ff-only 2>/dev/null || {
    echo "警告：git pull 失败（可能无网络或非 git 环境），跳过拉取，使用当前代码。"
  }
else
  echo "提示：当前目录非 git 仓库，跳过 pull。"
fi

# 如果传了 ref 参数，尝试切换
if [ $# -ge 1 ]; then
  ref="$1"
  echo "切换到: $ref"
  git checkout "$ref" 2>/dev/null || echo "警告：无法切换到 $ref"
fi

# 重新安装（install.sh 幂等）
echo "重新执行安装..."
bash "$REPO_DIR/install.sh"

echo "更新完成。"
