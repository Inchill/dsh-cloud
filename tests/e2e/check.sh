#!/usr/bin/env bash
#
# 在容器内部执行的 e2e 检查。由 run.sh 调用，不要直接跑。
#
set -uo pipefail

PORT="${1:-3080}"
fail=0

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

bootstrap() {
  bash /home/agent/bootstrap.sh \
    --no-tailscale --no-service --non-interactive --port "$PORT"
}

# 断言写成函数，而不是 bash -c '...'：单引号里的 $HOME 会被 shellcheck 判为
# 永远不会展开（SC2016），而这些变量本来就该由当前 shell 展开。
env_exists()      { test -f "$HOME/.dsh/.env"; }
env_has_key()     { grep -q '^DEEPSEEK_API_KEY=sk-e2e-dummy$' "$HOME/.dsh/.env"; }
env_is_600()      { [ "$(stat -c %a "$HOME/.dsh/.env")" = "600" ]; }
env_single_key()  { [ "$(grep -c '^DEEPSEEK_API_KEY=' "$HOME/.dsh/.env")" -eq 1 ]; }
skill_exists()    { test -f "$HOME/.dsh/skills/github-repos/SKILL.md"; }
skill_ok()        { head -1 "$HOME/.dsh/skills/github-repos/SKILL.md" | grep -qx -- '---'; }
dsh_runs()        { command -v dsh >/dev/null && dsh --version; }
gh_runs()         { command -v gh >/dev/null && gh --version; }
node_new_enough() { dpkg --compare-versions "$(node -v | sed 's/^v//')" ge 22.19.0; }
workdir_exists()  { test -d /srv/agent-workspace; }
no_unit_written() { ! test -f /etc/systemd/system/dsh-web.service; }
dry_run_runs() {
  bash /home/agent/bootstrap.sh --dry-run --no-tailscale --non-interactive
}

step "第一次安装"
if bootstrap; then ok "退出码 0"; else bad "退出码非 0"; fi

step "断言产物"
check ".env 已生成"             env_exists
check ".env 内容正确"           env_has_key
check ".env 权限为 600"         env_is_600
check "skill 已写入"            skill_exists
check "skill frontmatter 完整"  skill_ok
check "dsh 可执行"              dsh_runs
check "gh 可执行"               gh_runs
check "node 版本达标"           node_new_enough
check "工作区目录存在"          workdir_exists

step "幂等性：原样再跑一遍"
if bootstrap; then ok "第二次退出码 0"; else bad "第二次退出码非 0"; fi
check "第二次没有破坏 .env"      env_has_key
check ".env 里只有一行 API key"  env_single_key

step "dry-run"
# 这里故意不加 --no-service：脚本「本该」写 unit，dry-run 必须什么都不写
check "dry-run 退出码 0"        dry_run_runs
check "dry-run 没写 unit"       no_unit_written

printf '\n'
if [ "$fail" -ne 0 ]; then
  printf '\033[31m有检查项失败\033[0m\n\n'
  exit 1
fi
printf '\033[32m容器内检查全部通过\033[0m\n\n'
