# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- `--dsh-version`：安装版本不再写死在脚本里
- `--no-tailscale`：完全不碰 Tailscale，配合 `--public-url` / `--trusted-host`
  可接入已有的 tailnet、公司内网或自建反代
- `--no-service`：只装 dsh，不装 systemd 服务，交给 supervisor/pm2 管理
- `--dry-run`：只打印计划和渲染出的 systemd unit，不做任何修改
- `tests/e2e/`：在真实 `ubuntu:24.04` / `debian:12` 容器里装一遍，
  覆盖 apt/npm 这些单元测试碰不到的外部依赖，并验证幂等
- CI 增加 e2e job（main 分支与手动触发）

## [0.1.0] - 2026-10-30

### 新增

- `bootstrap.sh`：在 Debian/Ubuntu 上一键部署云端 DSH
  - Node 22、`gh`、`jq`、`dsh`（版本锁定）安装
  - API key 写入 `~/.dsh/.env`，权限 600
  - `github-repos` skill 随包预置
  - Tailscale 组网 + `tailscale serve` 自动 HTTPS
  - systemd 常驻、开机自启
  - 全流程幂等，可重复执行
- `teardown.sh`：撤销部署，默认保留会话与仓库数据
- `tests/cli.sh`：参数解析与预检的行为测试，macOS/Linux 双平台可跑
- CI：shellcheck + 双平台行为测试

### 修复

- `--no-service` 时摘要仍宣称「服务已在运行」，改为如实说明服务未安装
- `--trusted-host` 从 `--public-url` 推导时丢掉端口，导致非默认端口下 Host 栅栏
  拒绝所有请求；改为保留端口
- 变量名后紧跟中文标点会被 bash 算进变量名，在 `set -u` 下导致 `unbound variable`
  崩溃（`$NODE_MIN，`、`$installed，`、`$ENV_FILE（` 三处），统一改为 `${VAR}`
- 无控制终端时 `/dev/tty` 打开失败只打印一行 bash 噪音并静默取消，
  现在改为明确报错「非交互环境请加 --yes」
- `os-release` 缺字段时被 `set -u` 打断，改为先置空再 source
