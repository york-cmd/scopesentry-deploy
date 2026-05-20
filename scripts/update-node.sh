#!/usr/bin/env bash
# scripts/update-node.sh
#
# 向后兼容 wrapper：已发布的 raw URL 仍可工作。
# 等价于 `manage-node.sh --upgrade`。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/update-node.sh | bash
set -euo pipefail

DEPLOY_REPO_OWNER="${DEPLOY_REPO_OWNER:-york-cmd}"
DEPLOY_REPO_NAME="${DEPLOY_REPO_NAME:-scopesentry-deploy}"
DEPLOY_REPO_BRANCH="${DEPLOY_REPO_BRANCH:-main}"

exec bash -c "$(curl -fsSL "https://raw.githubusercontent.com/${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}/${DEPLOY_REPO_BRANCH}/scripts/manage-node.sh")" -- --upgrade
