#!/usr/bin/env bash
#
# dsh-cloud bootstrap
#
# 在一台干净的 Debian/Ubuntu 云主机上装好「手机可用的云端 DSH」：
#   Node 22 + gh + dsh(pinned) + Tailscale + systemd 常驻 + GitHub 工作流 skill
#
# 用法（在云主机上）：
#   curl -fsSL <url>/bootstrap.sh | bash -s -- --port 3080
#
# 或用环境变量跳过交互：
#   DEEPSEEK_API_KEY=sk-... bash bootstrap.sh --non-interactive
#
# 参数：
#   --port N             dsh web 监听端口（默认 3080，仅 loopback）
#   --dir PATH           工作区根目录（默认 /srv/agent-workspace，仓库 clone 到这里）
#   --dsh-version V      要安装的 dsh 版本（默认 0.2.1-rc.2）
#   --no-tailscale       完全不碰 Tailscale（已有组网/自建反代时用）
#   --public-url URL     对外公告的根地址，如 https://dsh.example.com/
#   --trusted-host HOST  额外信任的 Host，省略时从 --public-url 推导
#   --no-serve           只跳过 tailscale serve（仍用 Tailscale 组网）
#   --no-service         不安装 systemd 服务（自己用 supervisor/pm2 管理）
#   --dry-run            只打印将要执行的动作和 systemd unit，不做任何修改
#   --non-interactive    不询问任何输入，缺失的密钥直接报错退出
#   -h | --help          显示帮助
#
set -euo pipefail

PORT=3080
WORKDIR=/srv/agent-workspace
DSH_VERSION="${DSH_VERSION:-0.2.1-rc.2}"
DO_TAILSCALE=1
DO_SERVE=1
DO_SERVICE=1
DRY_RUN=0
INTERACTIVE=1
SERVICE=dsh-web
NODE_MIN="22.19.0"
PUBLIC_URL_OPT=""
TRUSTED_HOST_OPT=""
TS_NAME=""
PUBLIC_URL=""
TRUSTED_HOST=""

# ---------------------------------------------------------------- 输出

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=''; C_G=''; C_Y=''; C_R=''; C_0=''
fi

step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%s错误:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

trap 'die "第 $LINENO 行失败，已中止。"' ERR

usage() {
  if [ -f "$0" ]; then
    # 打印文件头注释块（到 set -euo 之前），去掉行首 "# "
    sed -n '2,/^set -euo/{/^set -euo/d;p;}' "$0" | sed -e 's/^# \{0,1\}//'
  else
    # curl | bash 时 $0 是 bash，读不到自己的正文
    cat <<'USAGE_EOF'
参数：
  --port N             监听端口（默认 3080，仅 loopback）
  --dir PATH           工作区根目录（默认 /srv/agent-workspace）
  --no-serve           不配置 tailscale serve
  --non-interactive    不问任何输入，缺密钥直接退出

完整说明请先下载再查看：bash bootstrap.sh --help
USAGE_EOF
  fi
  exit 0
}

# ---------------------------------------------------------------- 参数

while [ $# -gt 0 ]; do
  case "$1" in
    --port)            PORT="${2:?--port 需要数值}"; shift 2 ;;
    --dir)             WORKDIR="${2:?--dir 需要路径}"; shift 2 ;;
    --dsh-version)     DSH_VERSION="${2:?--dsh-version 需要版本号}"; shift 2 ;;
    --no-tailscale)    DO_TAILSCALE=0; shift ;;
    --no-serve)        DO_SERVE=0; shift ;;
    --no-service)      DO_SERVICE=0; shift ;;
    --public-url)      PUBLIC_URL_OPT="${2:?--public-url 需要 URL}"; shift 2 ;;
    --trusted-host)    TRUSTED_HOST_OPT="${2:?--trusted-host 需要主机名}"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --non-interactive) INTERACTIVE=0; shift ;;
    -h|--help)         usage ;;
    *)                 die "未知参数: $1（--help 查看用法）" ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port 必须是数字"
[[ "$WORKDIR" = /* ]] || die "--dir 必须是绝对路径"
[[ "$DSH_VERSION" =~ ^[0-9A-Za-z.+-]+$ ]] || die "--dsh-version 格式不合法: $DSH_VERSION"
if [ -n "$PUBLIC_URL_OPT" ]; then
  [[ "$PUBLIC_URL_OPT" =~ ^https?://[^/]+ ]] || die "--public-url 必须是 http(s)://host 形式: $PUBLIC_URL_OPT"
fi
if [ "$DO_TAILSCALE" -eq 0 ] && [ -n "$TRUSTED_HOST_OPT" ] && [ -z "$PUBLIC_URL_OPT" ]; then
  die "--trusted-host 需要配合 --public-url 使用"
fi

# 从 tty 读取，避免 curl | bash 时把脚本正文当输入吃掉。
# 用真正的 open 判断 tty 是否可用：没有控制终端时 /dev/tty 存在但打开会 ENXIO。
tty_read() {
  local prompt="$1" target="$2" silent="${3:-0}"
  if [ "$INTERACTIVE" -eq 0 ]; then
    return 1
  fi
  if ! (exec 3<>/dev/tty) 2>/dev/null; then
    return 1
  fi
  exec 3<>/dev/tty
  printf '%s' "$prompt" >&3
  if [ "$silent" -eq 1 ]; then
    IFS= read -rs "$target" <&3 || { exec 3>&- 2>/dev/null || true; return 1; }
    printf '\n' >&3
  else
    IFS= read -r "$target" <&3 || { exec 3>&- 2>/dev/null || true; return 1; }
  fi
  exec 3>&- 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------- 预检

step "环境预检"

[ "$(id -u)" -ne 0 ] || die "不要用 root 运行。用普通用户执行，脚本会按需 sudo。"

[ -r /etc/os-release ] || die "读不到 /etc/os-release，无法识别发行版。"
# 先置空，避免 os-release 缺字段时被 set -u 打断
ID=""
PRETTY_NAME=""
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "只支持 Debian/Ubuntu，当前是 ${ID:-unknown}。" ;;
esac
ok "$PRETTY_NAME"

command -v sudo >/dev/null || die "缺少 sudo。"
sudo -n true 2>/dev/null || warn "sudo 需要输入密码，过程中可能会提示"

case "$(uname -m)" in
  x86_64|aarch64|arm64) ok "架构 $(uname -m)" ;;
  *) die "不支持的架构 $(uname -m)" ;;
esac

export DEBIAN_FRONTEND=noninteractive

apt_install() {
  sudo apt-get update -qq
  sudo apt-get install -y -qq "$@" >/dev/null
}

# ---------------------------------------------------------------- 入口地址

# 从 URL 里取出 host 部分（去掉协议和路径）
# 保留端口：非默认端口时浏览器的 Host 头会带上端口，去掉就会对不上栅栏
url_host() {
  printf '%s' "$1" | sed -e 's|^[a-zA-Z]*://||' -e 's|/.*$||'
}

# 解析对外公告的地址与可信 Host。
# 两条来源：Tailscale（自动取 tailnet 域名），或 --public-url（用户自建反代/隧道）。
resolve_ingress() {
  # 显式给的地址优先于自动推导：用户明确写了就按用户的来
  if [ -n "$PUBLIC_URL_OPT" ]; then
    PUBLIC_URL="$PUBLIC_URL_OPT"
    if [ -n "$TRUSTED_HOST_OPT" ]; then
      TRUSTED_HOST="$TRUSTED_HOST_OPT"
    else
      TRUSTED_HOST="$(url_host "$PUBLIC_URL_OPT")"
    fi
    return 0
  fi
  if [ "$DO_TAILSCALE" -eq 1 ]; then
    PUBLIC_URL="https://${TS_NAME}/"
    TRUSTED_HOST="$TS_NAME"
  fi
}

# 仅读取 tailnet 域名，不安装、不登录
tailnet_name() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale status >/dev/null 2>&1 || return 1
  local n
  n="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')" || return 1
  [ -n "$n" ] || return 1
  case "$n" in
    *[!A-Za-z0-9.-]*) return 1 ;;
  esac
  printf '%s' "$n"
}

# 渲染 systemd unit（不含写盘），供 --dry-run 与正式安装共用
render_unit() {
  local after="network-online.target"
  if [ "$DO_TAILSCALE" -eq 1 ]; then
    after="$after tailscaled.service"
  fi
  cat <<UNIT_EOF
[Unit]
Description=DeepSeek Harness Web ($1)
After=$after
Wants=network-online.target

[Service]
Type=simple
User=$2
Group=$3
Environment=HOME=$HOME
EnvironmentFile=$ENV_FILE
WorkingDirectory=$WORKDIR
ExecStart=$(command -v dsh || echo /usr/bin/dsh) $4
Restart=always
RestartSec=3
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
}

build_exec_args() {
  local args="--profile web --no-open --port $PORT"
  if [ -n "$PUBLIC_URL" ]; then
    args="$args --public-url \"$PUBLIC_URL\""
  fi
  if [ -n "$TRUSTED_HOST" ]; then
    args="$args --trusted-host \"$TRUSTED_HOST\""
  fi
  printf '%s' "$args"
}

ENV_FILE="$HOME/.dsh/.env"

# ---------------------------------------------------------------- dry-run

if [ "$DRY_RUN" -eq 1 ]; then
  step "dry-run：只打印，不修改任何东西"

  if [ "$DO_TAILSCALE" -eq 1 ]; then
    if TS_NAME="$(tailnet_name)"; then
      ok "检测到 tailnet 域名 $TS_NAME"
    else
      TS_NAME="<tailnet-域名>"
      warn "本机还没接入 Tailscale，装完后才能确定域名"
    fi
  fi
  resolve_ingress

  printf '\n  将要执行：\n'
  printf '    安装/确认 Node >= %s\n' "$NODE_MIN"
  printf '    安装/确认 gh、jq\n'
  printf '    安装 dsh %s（全局）\n' "$DSH_VERSION"
  printf '    创建 %s\n' "$WORKDIR"
  printf '    写入 %s（权限 600）\n' "$ENV_FILE"
  printf '    写入 %s/.dsh/skills/github-repos/SKILL.md\n' "$HOME"
  if [ "$DO_TAILSCALE" -eq 1 ]; then
    printf '    安装/登录 Tailscale\n'
  else
    printf '    跳过 Tailscale（--no-tailscale）\n'
  fi
  if [ "$DO_SERVICE" -eq 1 ]; then
    printf '    写入 /etc/systemd/system/%s.service 并启动\n' "$SERVICE"
  else
    printf '    跳过 systemd（--no-service）\n'
  fi
  if [ "$DO_SERVE" -eq 1 ] && [ "$DO_TAILSCALE" -eq 1 ]; then
    printf '    执行 tailscale serve --bg %s\n' "$PORT"
  fi

  if [ "$DO_SERVICE" -eq 1 ]; then
    printf '\n  systemd unit 会是这样：\n\n'
    render_unit "${PUBLIC_URL:-http://127.0.0.1:$PORT/}" "$(id -un)" "$(id -gn)" "$(build_exec_args)" | sed 's/^/    /'
  else
    printf '\n  手动启动命令会是这样：\n\n'
    printf '    cd %s && %s %s\n' "$WORKDIR" "$(command -v dsh || echo dsh)" "$(build_exec_args)"
  fi
  printf '\n  什么也没改。去掉 --dry-run 才会真正执行。\n\n'
  exit 0
fi

# ---------------------------------------------------------------- Node

step "Node.js"

need_node=1
if command -v node >/dev/null; then
  cur="$(node -v | sed 's/^v//')"
  # dpkg 比较版本，免得依赖 coreutils 的 sort -V
  if dpkg --compare-versions "$cur" ge "$NODE_MIN" 2>/dev/null; then
    ok "已安装 node v$cur"
    need_node=0
  else
    warn "node v$cur 低于要求 ${NODE_MIN}，升级中"
  fi
fi

if [ "$need_node" -eq 1 ]; then
  sudo apt-get install -y -qq curl ca-certificates >/dev/null
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
  sudo apt-get install -y -qq nodejs >/dev/null
  ok "node $(node -v) / npm $(npm -v)"
fi

# ---------------------------------------------------------------- gh / jq

step "GitHub CLI 与基础工具"

command -v jq >/dev/null || apt_install jq
ok "jq $(jq --version)"

if ! command -v gh >/dev/null; then
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  apt_install gh
fi
ok "gh $(gh --version | head -1 | awk '{print $3}')"

# ---------------------------------------------------------------- dsh

step "DeepSeek Harness $DSH_VERSION"

installed=""
if command -v dsh >/dev/null; then
  installed="$(dsh --version 2>/dev/null | head -1 || true)"
fi
if [ "$installed" = "$DSH_VERSION" ]; then
  ok "已安装 $installed"
else
  if [ -n "$installed" ]; then
    warn "当前 ${installed}，覆盖为 $DSH_VERSION"
  fi
  sudo npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" >/dev/null
  ok "dsh $(dsh --version | head -1)"
fi

# 首次运行时从随附模板初始化 profile（不监听端口，安全）
dsh --profile web --help >/dev/null 2>&1 || warn "web profile 初始化时返回非零，继续"
ok "web profile 已就绪（~/.dsh/profiles/web）"

# ---------------------------------------------------------------- 目录与密钥

step "工作区与密钥"

sudo mkdir -p "$WORKDIR"
sudo chown "$(id -u):$(id -g)" "$WORKDIR"
ok "工作区 $WORKDIR"

ENV_FILE="$HOME/.dsh/.env"
mkdir -p "$HOME/.dsh"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

if grep -q '^DEEPSEEK_API_KEY=.\+' "$ENV_FILE" 2>/dev/null; then
  ok "DEEPSEEK_API_KEY 已存在，保持不变"
else
  key="${DEEPSEEK_API_KEY:-}"
  if [ -z "$key" ]; then
    if ! tty_read "  粘贴 DeepSeek API Key（输入不回显）: " key 1; then
      die "缺少 DEEPSEEK_API_KEY。请先 export DEEPSEEK_API_KEY=sk-... 再运行。"
    fi
  fi
  [ -n "$key" ] || die "API Key 为空。"
  printf 'DEEPSEEK_API_KEY=%s\n' "$key" >> "$ENV_FILE"
  ok "已写入 ${ENV_FILE}（权限 600）"
fi

# ---------------------------------------------------------------- skill

step "GitHub 工作流 skill"

SKILL_DIR="$HOME/.dsh/skills/github-repos"
mkdir -p "$SKILL_DIR"
cat > "$SKILL_DIR/SKILL.md" <<'SKILL_EOF'
---
name: github-repos
description: 在云端主机上列出、拉取、切换、修改并提交 GitHub 仓库，开 PR 或合并。当用户提到自己的仓库、要拉代码、要改某个项目、要提 PR 或合并时使用。
whenToUse: 用户说“看看我的仓库”“用 xxx 仓库”“拉一下 xxx”“提个 PR”“合并”这类涉及 GitHub 仓库操作的话时。
---

# GitHub 仓库工作流

在这台主机上代替用户操作 GitHub。用户通常不在电脑前（手机对话），所以每一步要说得简短、可核对，不要刷大段日志。

## 前提检查

开始前先确认一次：

```sh
gh auth status
```

失败就**停下来告诉用户**“这台机器上的 gh 未认证”，不要自己跑 `gh auth login`（那是交互式流程，手机端没法完成）。

仓库根目录统一用 `${REPOS_ROOT:-~/repos}`，不存在则创建 `mkdir -p`。

## 1. 列出并选择仓库

按最近推送排序，输出紧凑表格：

```sh
gh repo list --limit 200 --json nameWithOwner,description,pushedAt \
  --jq 'sort_by(.pushedAt) | reverse | .[] | "\(.nameWithOwner)\t\(.pushedAt[:10])\t\(.description // "")"'
```

结果超过 15 行时，只展示前 15 个并说明“还有 N 个，说关键词我再筛”。让用户用名字或序号指认，**不要替用户猜**。

## 2. 拉取

```sh
REPOS_ROOT="${REPOS_ROOT:-$HOME/repos}"
mkdir -p "$REPOS_ROOT"
[ -d "$REPOS_ROOT/<name>" ] || gh repo clone <owner/name> "$REPOS_ROOT/<name>"
cd "$REPOS_ROOT/<name>" && git fetch --prune && git status -sb
```

已存在就走 `fetch + pull --ff-only`。如果本地有未提交改动，**先报告再问**，不要 stash 或重置。

## 3. 开始工作

永远不直接在默认分支上改：

```sh
git switch -c <type>/<short-slug>   # type: feat|fix|chore|docs
```

分支名用英文短横线，别用中文和空格。

改完代码，**先跑仓库自己的验证命令**（看 `package.json` scripts、`Makefile`、`pyproject.toml` 决定），把结果如实汇报。测试挂了不要谎报通过，也不要反复重跑掩盖。

## 4. 提交

小步提交，message 用 Conventional Commits：

```sh
git add -A && git commit -m "feat: 一句话说明"
```

提交前用 `git diff --stat` 给用户看一眼改了什么。

## 5. 开 PR

```sh
git push -u origin HEAD
gh pr create --fill --body "## 改了什么
...

## 怎么验证的
..."
```

把 PR 链接原样给用户。

## 6. 合并

**默认不自动合并。** 先汇报 PR 状态，等用户明确说“合并”才执行：

```sh
gh pr merge --squash --delete-branch
```

合并前确认：CI 通过（`gh pr checks`）、没有冲突、用户在对话里明确同意。

## 硬性禁止

- 不 force push（`--force`、`--force-with-lease` 都不行）
- 不直接 push 默认分支
- 不改写已有 commit 历史
- 不 `gh repo delete`、不改仓库可见性
- 不把 token 打印到对话里
- 遇到权限错误，报告原始错误信息，不要绕过
SKILL_EOF
ok "$SKILL_DIR/SKILL.md"

# ---------------------------------------------------------------- Tailscale

step "Tailscale"

if [ "$DO_TAILSCALE" -eq 0 ]; then
  warn "已按 --no-tailscale 跳过"
else
  if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || die "tailscale 安装失败"
  fi
  ok "tailscale $(tailscale version 2>/dev/null | head -1)"

  if tailscale status >/dev/null 2>&1; then
    ok "已登录 tailnet"
  else
    warn "需要登录 Tailscale（会在终端打印一个 URL，可用手机打开）"
    sudo tailscale up || die "tailscale up 失败"
  fi

  TS_NAME="$(tailnet_name)" || die "拿不到 tailnet 域名，检查 MagicDNS 是否开启。"
  ok "tailnet 域名 $TS_NAME"
fi

resolve_ingress
if [ -n "$PUBLIC_URL" ]; then
  ok "对外地址 ${PUBLIC_URL}（可信 Host: ${TRUSTED_HOST}）"
else
  warn "没有配置对外地址，服务只能本机访问（用 --public-url 自行指定）"
fi

# ---------------------------------------------------------------- systemd

step "systemd 服务"

if [ "$DO_SERVICE" -eq 0 ]; then
  warn "已按 --no-service 跳过，下面是你要手动跑的命令："
  printf '\n    cd %s && %s %s\n\n' "$WORKDIR" "$(command -v dsh || echo dsh)" "$(build_exec_args)"
else

render_unit "${PUBLIC_URL:-http://127.0.0.1:$PORT/}" "$(id -un)" "$(id -gn)" "$(build_exec_args)" \
  | sudo tee "/etc/systemd/system/${SERVICE}.service" >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE" >/dev/null 2>&1 || true
sudo systemctl restart "$SERVICE"
ok "服务已启动"

# 等端口就绪
ready=0
for _ in $(seq 1 30); do
  # 只探端口，不探 HTTP 状态：未带 cookie 的请求可能是 401，不代表没起来
  if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" -eq 1 ] || {
  warn "30 秒内没监听上，最近日志："
  sudo journalctl -u "$SERVICE" --no-pager -n 30 || true
  die "服务未能就绪"
}
ok "127.0.0.1:$PORT 已响应"

fi

# ---------------------------------------------------------------- serve

if [ "$DO_SERVE" -eq 1 ] && [ "$DO_TAILSCALE" -eq 1 ] && [ "$DO_SERVICE" -eq 1 ]; then
  step "Tailscale Serve（HTTPS 入口）"
  # 新版接受纯端口，老版要显式 URL；两种都试
  if sudo tailscale serve --bg "$PORT" >/dev/null 2>&1 \
     || sudo tailscale serve --bg "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
    ok "已代理 https://$TS_NAME/ → 127.0.0.1:$PORT"
  else
    warn "tailscale serve 失败。通常是 tailnet 未开启 HTTPS 证书："
    warn "  管理后台 → DNS → 启用 HTTPS Certificates，然后重跑："
    warn "  sudo tailscale serve --bg $PORT"
  fi
fi

# ---------------------------------------------------------------- 结果

step "完成"

TOKEN_URL=""
if [ "$DO_SERVICE" -eq 1 ]; then
  TOKEN_URL="$(sudo journalctl -u "$SERVICE" --no-pager -n 300 2>/dev/null \
    | grep -a 'dsh web:' | tail -1 \
    | grep -o 'https\?://[^[:space:]]*' | tail -1 || true)"
fi

if [ -n "$PUBLIC_URL" ]; then
  printf '\n  手机浏览器打开（首次带 token，之后靠 cookie）：\n'
  if [ -n "$TOKEN_URL" ]; then
    printf '    %s\n' "$TOKEN_URL"
    printf '    其中域名部分可换成：%s\n' "$PUBLIC_URL"
  else
    printf '    %s\n' "$PUBLIC_URL"
    printf '    取带 token 的完整链接：sudo journalctl -u %s -n 100 | grep "dsh web:"\n' "$SERVICE"
  fi
else
  if [ "$DO_SERVICE" -eq 1 ]; then
    printf '\n  服务已在 127.0.0.1:%s 上运行，但没有配置对外地址。\n' "$PORT"
  else
    printf '\n  没有配置对外地址，也没有安装服务（--no-service）。\n'
  fi
  printf '  要从别的设备访问，选一种：\n'
  printf '    a) 用 Tailscale：重跑时不加 --no-tailscale\n'
  printf '    b) 自建反代后重跑，加 --public-url https://your.host/\n'
  printf '    c) 先在本机取带 token 的链接：\n'
  if [ -n "$TOKEN_URL" ]; then
    printf '         %s\n' "$TOKEN_URL"
  elif [ "$DO_SERVICE" -eq 1 ]; then
    printf '         sudo journalctl -u %s -n 100 | grep "dsh web:"\n' "$SERVICE"
  else
    printf '         按上面打印的命令手动启动，链接会直接打在它的 stdout 上\n'
  fi
fi

printf '\n  还没做的一步：\n'
if gh auth status >/dev/null 2>&1; then
  printf '    gh 已认证 ✓\n'
else
  printf '    gh 未认证 —— 执行下面这条，它会在手机上完成授权：\n'
  printf '      gh auth login --web --git-protocol https\n'
fi

if [ "$DO_SERVICE" -eq 1 ]; then
  printf '\n  常用命令：\n'
  printf '    sudo systemctl status %s\n' "$SERVICE"
  printf '    sudo journalctl -u %s -f\n' "$SERVICE"
  printf '    sudo systemctl restart %s\n' "$SERVICE"
else
  printf '\n  服务未安装（--no-service）。启动后带 token 的链接直接打在它的 stdout 上。\n'
fi

printf '\n  建议：装个手机端样式插件，把它做成 PWA 添加到主屏幕：\n'
printf '    dsh plugin --profile web add dsh-mobile-ui\n'

printf '\n  工作区：%s（agent 在这里 clone 仓库）\n' "$WORKDIR"
printf '  skill：%s\n\n' "$HOME/.dsh/skills/github-repos/SKILL.md"
