#!/usr/bin/env bash
#
# CLI 行为测试：只验证参数解析与预检，不触碰系统。
# 在 macOS 和 Linux 上都能跑，不需要 root、不需要网络。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SCRIPT=./bootstrap.sh
fails=0
total=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; total=$((total + 1)); }
fail() {
  printf '  \033[31m✗\033[0m %s\n' "$1"
  printf '     期望: %s\n' "$2"
  printf '     实际: %s\n' "$3"
  total=$((total + 1)); fails=$((fails + 1))
}

# expect <描述> <期望退出码> <输出应包含> <命令...>
expect() {
  local desc="$1" want_code="$2" want_text="$3"
  shift 3
  local out code
  out="$("$@" 2>&1)"
  code=$?
  if [ "$code" -eq "$want_code" ] && printf '%s' "$out" | grep -qF -- "$want_text"; then
    pass "$desc"
  else
    fail "$desc" "exit=${want_code} 且含「${want_text}」" "exit=${code} / $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  fi
}

printf '\n语法检查\n'
if bash -n "$SCRIPT" 2>/dev/null; then pass "bootstrap.sh 语法"; else fail "bootstrap.sh 语法" "bash -n 通过" "有语法错误"; fi

printf '\n帮助与参数\n'
expect "--help 退出 0 并打印参数表" 0 "参数：" "$SCRIPT" --help
expect "管道模式 --help 可用"        0 "参数：" bash -c "cat $SCRIPT | bash -s -- --help"
expect "拒绝非数字端口"              1 "--port 必须是数字" "$SCRIPT" --port abc
expect "拒绝相对路径"                1 "必须是绝对路径" "$SCRIPT" --dir ../tmp
expect "拒绝未知参数"                1 "未知参数" "$SCRIPT" --bogus
expect "拒绝缺失的端口值"            1 "--port 需要数值" "$SCRIPT" --port

printf '\n预检\n'
if [ "$(id -u)" -eq 0 ]; then
  printf '  \033[33m-\033[0m 以 root 运行，跳过「拒绝 root」检查\n'
else
  expect "非 root 时能进入预检" 1 "环境预检" "$SCRIPT"
fi

printf '\n开关与 dry-run\n'
# dry-run 会走进预检，所以用一份把 os-release 指到临时文件的副本来跑，
# 这样 macOS 上也能验证渲染结果
OSR="$(mktemp)"
PROBE="$(mktemp)"
printf 'ID=ubuntu\nPRETTY_NAME="Ubuntu (test)"\n' > "$OSR"
sed -e "s|/etc/os-release|$OSR|g" "$SCRIPT" > "$PROBE"
chmod +x "$PROBE"
trap 'rm -f "$OSR" "$PROBE"' EXIT

assert_has() {
  local desc="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    pass "$desc"
  else
    fail "$desc" "输出包含「${needle}」" "$(printf '%s' "$hay" | grep -E 'ExecStart|安装 dsh' | head -2 | tr '\n' ' ')"
  fi
}

assert_lacks() {
  local desc="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    fail "$desc" "输出不含「${needle}」" "实际上出现了"
  else
    pass "$desc"
  fi
}

out="$(bash "$PROBE" --dry-run --no-tailscale --public-url https://dsh.example.com/ 2>&1)" || true
assert_has "dry-run 渲染出 --public-url"        "$out" '--public-url "https://dsh.example.com/"'
assert_has "dry-run 从 URL 推导 --trusted-host" "$out" '--trusted-host "dsh.example.com"'
assert_has "dry-run 打印了 unit 的 ExecStart"   "$out" 'ExecStart='

out2="$(bash "$PROBE" --dry-run --no-tailscale 2>&1)" || true
assert_lacks "无 public-url 时不带 --public-url" "$out2" '--public-url'
assert_lacks "无 public-url 时不带 --trusted-host" "$out2" '--trusted-host'

out3="$(bash "$PROBE" --dry-run --no-tailscale --dsh-version 9.9.9 2>&1)" || true
assert_lacks "--no-tailscale 时 unit 不依赖 tailscaled" "$out2" 'tailscaled.service'
out4="$(bash "$PROBE" --dry-run --no-tailscale --public-url https://dsh.example.com:8443/ 2>&1)" || true
assert_has "自定义端口保留在 --trusted-host 里" "$out4" '--trusted-host "dsh.example.com:8443"'

out5="$(bash "$PROBE" --dry-run --public-url https://custom.example/ 2>&1)" || true
assert_has "显式 --public-url 覆盖 Tailscale 推导" "$out5" '--public-url "https://custom.example/"'

assert_has "--dsh-version 生效" "$out3" '安装 dsh 9.9.9'

expect "拒绝非法 --public-url"   1 "--public-url 必须是"  "$SCRIPT" --public-url ftp://x/
expect "拒绝孤立的 --trusted-host" 1 "需要配合 --public-url" "$SCRIPT" --no-tailscale --trusted-host example.com --dry-run

if bash "$PROBE" --dry-run --no-tailscale >/dev/null 2>&1; then
  pass "dry-run 退出码为 0"
else
  fail "dry-run 退出码为 0" "exit 0" "非零"
fi

printf '\n变量边界（回归）\n'
# 变量名后面紧跟中文标点时，bash 会把那个字的第一个字节算进变量名，
# 在 set -u 下直接 unbound variable 崩掉。所有这种位置必须写成 ${VAR}。
bad_vars="$(python3 - "$SCRIPT" <<'PY' 2>/dev/null
import re, sys, pathlib
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]')
for i, line in enumerate(pathlib.Path(sys.argv[1]).read_text().splitlines(), 1):
    if pat.search(line):
        print(f'{i}: {line.strip()[:70]}')
PY
)"
if [ -z "$bad_vars" ]; then
  pass "没有 \$VAR 紧跟非 ASCII 字符"
else
  fail "没有 \$VAR 紧跟非 ASCII 字符" "全部使用 \${VAR}" "$(printf '%s' "$bad_vars" | head -3 | tr '\n' ' ')"
fi

printf '\n文档一致性\n'
# 这一类检查不计入 total：它们校验的是「文档有没有跟上代码」，
# 本身不是行为测试，也不该把 README 里那个数字搞成自指的循环。
doc_ng=0
doc_ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
doc_bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; doc_ng=$((doc_ng + 1)); }

# 1) README 里写的测试项数
doc_n="$(grep -oE '# [0-9]+ 项' README.md 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
if [ -z "$doc_n" ]; then
  doc_bad "README 里找不到「# N 项」的说明"
elif [ "$doc_n" -eq "$total" ]; then
  doc_ok "README 记的项数与实际一致（$total 项）"
else
  doc_bad "README 说 $doc_n 项，实际 $total 项"
fi

# 2) 脚本支持的每个开关，README 里都要提到
missing=""
while IFS= read -r flag; do
  [ -n "$flag" ] || continue
  grep -qF -- "$flag" README.md || missing="$missing $flag"
done < <(grep -oE '^\s+--[a-z-]+\)' "$SCRIPT" | tr -d ' )' | sort -u)
if [ -z "$missing" ]; then
  doc_ok "脚本的每个开关都在 README 里出现过"
else
  doc_bad "README 没提到：$missing"
fi

# 3) teardown 的开关同样要对得上
missing=""
while IFS= read -r flag; do
  [ -n "$flag" ] || continue
  grep -qF -- "$flag" README.md || missing="$missing $flag"
done < <(grep -oE '^\s+--[a-z-]+' ./teardown.sh | tr -d ' ' | sort -u)
if [ -z "$missing" ]; then
  doc_ok "teardown.sh 的开关都在 README 里出现过"
else
  doc_bad "README 没提到 teardown 的：$missing"
fi

printf '\n'
if [ "$fails" -eq 0 ] && [ "$doc_ng" -eq 0 ]; then
  printf '\033[32m全部 %d 项通过，文档一致\033[0m\n\n' "$total"
  exit 0
fi
[ "$fails" -gt 0 ] && printf '\033[31m%d/%d 项失败\033[0m\n' "$fails" "$total"
[ "$doc_ng" -gt 0 ] && printf '\033[31m%d 项文档不一致\033[0m\n' "$doc_ng"
printf '\n'
exit 1
