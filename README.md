# dsh-cloud

在一台干净的 Debian/Ubuntu 云主机上，一条命令装好「手机可用的云端 DeepSeek Harness」：

- Node 22 + `gh` + `dsh`（版本锁定）
- Tailscale 内网访问 + 自动 HTTPS 证书
- systemd 常驻，开机自启
- 一份 `github-repos` skill，教 agent 怎么列仓库、拉代码、开 PR、合并

装完之后，手机浏览器打开一个链接，就能在对话里让它读你的 GitHub 仓库、改代码、提 PR。

## 安装

```sh
curl -fsSL https://raw.githubusercontent.com/Inchill/dsh-cloud/937ce5e042b722db6bb653f5f5dc6b7173fd4387/bootstrap.sh \
  | bash -s -- --port 3080
```

> 上面钉的是具体 commit。想跟最新代码可以把那段哈希换成 `main`，但生产环境别这么干 ——
> 上游一改，你下次重装跑的就是另一份代码。

建议的做法是先看再跑，毕竟它会 `sudo` 并写 systemd：

```sh
curl -fsSLO https://raw.githubusercontent.com/Inchill/dsh-cloud/937ce5e042b722db6bb653f5f5dc6b7173fd4387/bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

## 前置条件

- Debian 12 或 Ubuntu 24.04，x86_64 或 arm64（CI 测过的就是这两个；更老的版本未验证）
- 一个 DeepSeek API Key（headless/SDK 不使用托管凭据，必须有 key）
- **默认路线额外需要**：一个 Tailscale 账号，且 tailnet 已开启 **HTTPS Certificates**（后台 DNS 页面）

## 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--port N` | `3080` | dsh web 监听端口，仅绑定 loopback |
| `--dir PATH` | `/srv/agent-workspace` | 工作区根目录，仓库 clone 到这里 |
| `--dsh-version V` | `0.2.1-rc.2` | 要安装的 dsh 版本 |
| `--no-tailscale` | 关 | 完全不碰 Tailscale |
| `--public-url URL` | 无 | 对外公告的根地址，如 `https://dsh.example.com/` |
| `--trusted-host HOST` | 从 URL 推导 | 额外信任的 Host |
| `--no-serve` | 关 | 只跳过 `tailscale serve`（仍用 Tailscale 组网） |
| `--no-service` | 关 | 不装 systemd 服务，自己用 supervisor/pm2 管理 |
| `--dry-run` | 关 | 只打印计划和 systemd unit，不做任何修改 |
| `--non-interactive` | 关 | 不询问任何输入，缺密钥直接退出 |

也可以用环境变量跳过交互：`DEEPSEEK_API_KEY=sk-... bash bootstrap.sh`。

`--help` 会打印完整说明。**第一次用建议先跑 `--dry-run`**，它会打印出完整的 systemd unit，你可以看清它到底要以什么参数启动。

### 不用 Tailscale

已经有 tailnet、或者用公司内网 / 自己的隧道：

```sh
bash bootstrap.sh --no-tailscale --public-url https://dsh.example.com/
```

`--trusted-host` 会从 URL 里自动取，需要额外域名时再显式给。

完全不配对外地址（只本机访问，入口自己解决）：

```sh
bash bootstrap.sh --no-tailscale --no-service
```

这时脚本只负责装好 dsh、写好密钥和 skill，并把启动命令打印给你，进程由你自己管。

## 装完还需要两步

**1. 认证 gh**（脚本不代跑，因为那是你的账号，需要你在手机上确认）：

```sh
gh auth login --web --git-protocol https
```

它会打印一个设备码，手机打开 `github.com/login/device` 输入即可。

**2. 手机端**（可选，但强烈建议）：

```sh
dsh plugin --profile web add dsh-mobile-ui
```

然后在手机上把那个地址「添加到主屏幕」，就有了接近原生 App 的体验。

脚本跑完会打印**带 token 的完整链接**，从 journal 里自动抓的。token 只用一次，之后靠签名 cookie。

## 它做了什么

1. 预检（拒绝 root、拒绝非 Debian 系）
2. 装 Node 22（版本不够才装）
3. 装 `gh` 和 `jq`
4. 装 `dsh`，锁死在固定版本
5. 交互式读 API key，写进 `~/.dsh/.env`（权限 600）
6. 写 `~/.dsh/skills/github-repos/SKILL.md`
7. 装 Tailscale、登录、取 tailnet 域名
8. 写 systemd unit、启动、`tailscale serve` 做 HTTPS 入口

整个过程幂等，可以重复跑。

## 卸载

```sh
bash teardown.sh
```

会删掉 systemd 服务、关闭 `tailscale serve`、卸载 `dsh`、移除 skill。
默认**保留** `~/.dsh/.env`（里面有 API key）、会话历史和 `/srv/agent-workspace` 里的仓库。

要连工作区一起删（仓库会没）：

```sh
bash teardown.sh --purge
```

自动化里用 `--yes` 跳过确认。

## 开发

```sh
bash tests/cli.sh                 # 21 项：参数解析、预检、dry-run 渲染、变量边界
bash tests/e2e/run.sh             # 真装一遍（需要 docker，约 3-5 分钟）
bash tests/e2e/run.sh debian:12   # 换发行版
```

`tests/cli.sh` 还会顺带核对文档：README 里记的项数要对得上，脚本和 teardown 的每个开关都得在文档里出现过。
数字、开关名这类东西不会报错，只会慢慢变错，让 CI 盯着比自己记着可靠。

三层测试覆盖的东西不一样：

| 层 | 覆盖什么 | 需要什么 |
|---|---|---|
| `shellcheck` + `bash -n` | 语法、常见 shell 陷阱 | 无 |
| `tests/cli.sh` | 参数解析、dry-run 渲染出的 unit、变量边界 | 无（macOS 也能跑） |
| `tests/e2e/run.sh` | apt/npm 这些外部命令今天还能不能用 | docker + 网络 |

CI 跑全部三层，`cli.sh` 在 Ubuntu 和 macOS 各跑一遍。双平台是必要的：本地开发机多是 macOS，
BSD 和 GNU 的差异（比如变量名后紧跟多字节字符）只有两边都跑才暴露得出来。

e2e 只在 push 到 `main` 和手动触发时跑，不占 PR 的额度。

## 安全说明

- 服务只监听 `127.0.0.1`，外部访问一律走 Tailscale（WireGuard 加密 + 身份验证），公网不可达
- `gh` 的 token 是**你账号的完整权限**，没有任何按仓库的白名单。这台机器被注入，就能推你所有仓库
- skill 里写死「默认不自动合并」，需要你明确说「合并」才执行。用顺了再考虑放开
- 脚本不打印、不上传任何密钥

## 已知限制

- 只支持 Debian/Ubuntu，macOS 和 Alpine 不适用
- `tailscale serve` 依赖 tailnet 开启 HTTPS 证书，否则会降级并提示
- `gh auth login` 必须手动完成（交互式 device flow）
- 用的是 dsh 的 rc 版本，升级前先读 changelog
