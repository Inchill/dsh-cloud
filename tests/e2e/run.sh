#!/usr/bin/env bash
#
# e2e：在真实容器里把 bootstrap.sh 跑一遍。
#
# 验证的是「apt/npm 这些外部命令今天还能用」——单元测试覆盖不到，
# 上游一改就会静默失效。
#
# --no-tailscale --no-service 用来绕开容器里没有 systemd、没有 tailnet 的环境，
# 这两个开关本身是给「自带组网 / 自带 supervisor」的用户准备的，不是测试后门。
#
# 用法：
#   bash tests/e2e/run.sh                  # ubuntu:24.04
#   bash tests/e2e/run.sh debian:12
#   bash tests/e2e/run.sh ubuntu:24.04 keep   # 保留镜像便于排查
#
set -euo pipefail

BASE="${1:-ubuntu:24.04}"
KEEP="${2:-}"

command -v docker >/dev/null || { printf '需要 docker\n' >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="dsh-cloud-e2e:$(printf '%s' "$BASE" | tr '/:' '--')"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

cleanup() {
  if [ "$KEEP" != "keep" ]; then
    docker rmi -f "$TAG" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "构建 $BASE"
docker build \
  --build-arg "BASE=$BASE" \
  -f "$ROOT/tests/e2e/Dockerfile" \
  -t "$TAG" \
  "$ROOT"

step "在容器里执行检查"
docker run --rm \
  -e DEEPSEEK_API_KEY=sk-e2e-dummy \
  "$TAG" \
  bash /home/agent/tests/e2e/check.sh

step "完成"
printf '  %s 通过\n' "$BASE"
