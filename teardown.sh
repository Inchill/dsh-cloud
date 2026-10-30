#!/usr/bin/env bash
#
# dsh-cloud teardown
#
# 撤销 bootstrap.sh 在主机上做的改动。默认不动你的数据和仓库。
#
# 用法：
#   bash teardown.sh            交互确认后执行
#   bash teardown.sh --yes      不确认（给自动化用）
#   bash teardown.sh --purge    额外删除工作区目录（仓库会没，谨慎）
#
set -euo pipefail

SERVICE=dsh-web
WORKDIR=/srv/agent-workspace
YES=0
PURGE=0

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=''; C_G=''; C_Y=''; C_R=''; C_0=''
fi

step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
skip() { printf '  %s-%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%s错误:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

usage() {
  if [ -f "$0" ]; then
    sed -n '2,/^set -euo/{/^set -euo/d;p;}' "$0" | sed -e 's/^# \{0,1\}//'
  else
    printf '参数: --yes --purge\n'
  fi
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)  YES=1; shift ;;
    --purge)   PURGE=1; shift ;;
    -h|--help) usage ;;
    *)         die "未知参数: $1" ;;
  esac
done

[ "$(id -u)" -ne 0 ] || die "不要用 root 运行。"

step "将要执行"

printf '  停止并删除 systemd 服务 %s\n' "$SERVICE"
printf '  关闭 tailscale serve\n'
printf '  卸载全局 npm 包 @deepseek-ai/dsh\n'
printf '  删除 ~/.dsh/skills/github-repos\n'
if [ "$PURGE" -eq 1 ]; then
  printf '  %s删除工作区 %s（含已 clone 的仓库）%s\n' "$C_R" "$WORKDIR" "$C_0"
fi
printf '\n  保留：~/.dsh/.env（API key）、~/.dsh/sessions（会话历史）、Tailscale 本体\n'

if [ "$YES" -ne 1 ]; then
  # 没有控制终端时 /dev/tty 存在但打开返回 ENXIO，用真正的 open 判断
  if (exec 3<>/dev/tty) 2>/dev/null; then
    exec 3<>/dev/tty
    printf '\n  确认执行？[y/N] ' >&3
    IFS= read -r ans <&3 || ans=""
    exec 3>&- 2>/dev/null || true
    case "$ans" in
      y|Y|yes|YES) ;;
      *) printf '\n  已取消，什么都没改。\n\n'; exit 0 ;;
    esac
  else
    die "非交互环境请加 --yes"
  fi
fi

step "systemd"

if [ -f "/etc/systemd/system/${SERVICE}.service" ]; then
  sudo systemctl disable --now "$SERVICE" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/${SERVICE}.service"
  sudo systemctl daemon-reload
  ok "服务已移除"
else
  skip "服务不存在"
fi

step "Tailscale"

if command -v tailscale >/dev/null; then
  if sudo tailscale serve --bg off >/dev/null 2>&1; then
    ok "serve 已关闭"
  else
    skip "serve 未在运行"
  fi
else
  skip "未安装 tailscale"
fi

step "dsh"

if command -v dsh >/dev/null; then
  if sudo npm uninstall -g @deepseek-ai/dsh >/dev/null 2>&1; then
    ok "已卸载"
  else
    skip "卸载失败，可手动执行"
  fi
else
  skip "未安装"
fi

step "skill"

if [ -d "$HOME/.dsh/skills/github-repos" ]; then
  rm -rf "$HOME/.dsh/skills/github-repos"
  ok "已删除"
else
  skip "不存在"
fi

if [ "$PURGE" -eq 1 ]; then
  step "工作区"
  if [ -d "$WORKDIR" ]; then
    if [ -n "$(find "$WORKDIR" -maxdepth 3 -name .git -type d 2>/dev/null | head -1)" ]; then
      printf '  %s注意：%s 里有 git 仓库，删除前请确认没有未推送的提交\n' "$C_Y" "$WORKDIR"
    fi
    sudo rm -rf "$WORKDIR"
    ok "已删除 $WORKDIR"
  else
    skip "不存在"
  fi
fi

step "完成"

printf '  仍然保留的内容：\n'
printf '    ~/.dsh/.env          里面还有你的 API key，要清就 rm\n'
printf '    ~/.dsh/sessions      会话历史\n'
printf '    Tailscale            如需退出：sudo tailscale down && sudo tailscale logout\n'
printf '    Tailscale 的 DNS 记录（后台管理页删除设备）\n\n'
