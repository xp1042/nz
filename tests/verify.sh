#!/usr/bin/env bash
# 语法校验 + nginx 渲染校验（不联网、不启进程）
set -uo pipefail
cd "$(dirname "$0")" 2>/dev/null || true
# 允许从项目根或 tests/ 目录运行
[ -d file ] || cd ..
rc=0

echo "== bash -n =="
for f in lib.sh start.sh backup.sh restore.sh renew.sh restart.sh; do
  if bash -n "file/$f" 2>/tmp/e; then echo "  ok    $f"; else echo "  FAIL  $f: $(cat /tmp/e)"; rc=1; fi
done

echo "== render-nginx（注入 PORT=7777）=="
rm -rf .t
export WORK_DIR="$PWD/.t/app"
export NGINX_PREFIX="$PWD/.t/nginx"
export NGINX_CONF_DIR="$PWD/.t/nginx/conf.d"
export NGINX_MAIN_CONF="$PWD/.t/nginx/nginx.conf"
mkdir -p "$WORK_DIR" "$NGINX_CONF_DIR"
export PORT=7777 HTTPS_PORT=9443 DASH_PORT=18008
bash file/start.sh render-nginx >/tmp/render.log 2>&1 || { echo "  FAIL render: $(tail -5 /tmp/render.log)"; rc=1; }
for pair in "listen 7777 default_server;" "listen 9443 ssl;" "127.0.0.1:18008"; do
  if grep -qF "$pair" "$NGINX_CONF_DIR/default.conf" "$NGINX_CONF_DIR/ssl.conf" 2>/dev/null; then
    echo "  ok    渲染含 [$pair]"
  else
    echo "  FAIL  渲染缺 [$pair]"; rc=1
  fi
done
if grep -qE 'listen[ ]+80([ ;]|$)' "$NGINX_CONF_DIR/default.conf" 2>/dev/null; then
  echo "  FAIL  仍残留硬编码 listen 80"; rc=1
else
  echo "  ok    无硬编码 listen 80"
fi
# nginx 变量必须保持 \$host 之类原样（不能被 shell 展开成空）
if grep -q 'proxy_set_header Host \$host;' "$NGINX_CONF_DIR/default.conf"; then
  echo "  ok    nginx 变量未被 shell 吞掉"
else
  echo "  FAIL  nginx \$host 被展开了"; rc=1
fi
if grep -q 'grpc_pass grpc://dashboard;' "$NGINX_CONF_DIR/default.conf"; then
  echo "  ok    gRPC upstream 保留"
else
  echo "  FAIL  gRPC 段丢失"; rc=1
fi

echo "== self-test =="
bash file/start.sh self-test 2>&1 | sed 's/^/  /'

echo "== 调用契约 =="
# 1) start.sh 调 restore.sh 必须显式传参，否则会撞进无 tty 的交互保护分支
if grep -nE '\./restore\.sh[[:space:]]*$' file/start.sh >/dev/null 2>&1; then
  echo "  FAIL  start.sh 存在不带参的 ./restore.sh 调用"; rc=1
else
  echo "  ok    start.sh 调 restore.sh 均显式传参"
fi
# 2) restore.sh 无参 = 交互，且必须有 tty 保护
grep -qF 'MODE="${1:-list}"' file/restore.sh \
  && grep -qF '[ -t 0 ]' file/restore.sh \
  && echo "  ok    restore.sh 无参=交互 + 有 tty 保护" \
  || { echo "  FAIL  restore.sh 交互分支或 tty 保护缺失"; rc=1; }
# 3) lib.sh 的 warn/err 必须走 stderr，否则会被 $(...) 污染进变量
grep -qE '^warn\(\).*>&2' file/lib.sh && grep -qE '^err\(\).*>&2' file/lib.sh \
  && echo "  ok    warn/err 输出到 stderr" \
  || { echo "  FAIL  warn/err 未分离到 stderr"; rc=1; }
# 4) 所有脚本必须引用 lib.sh
miss=0
for f in start.sh backup.sh restore.sh renew.sh restart.sh; do
  grep -q 'lib.sh' "file/$f" || { echo "  FAIL  $f 未引用 lib.sh"; miss=1; }
done
[ "$miss" = 0 ] && echo "  ok    五个脚本均引用 lib.sh"

# 5) 备份成功后必须登记"已生效状态"，否则冷却期满会自还原刚推上去的包并全量重启
if grep -qE 'printf .%s.n. "\$BACKUP_FILE" > "\$RESTORE_STATE"' file/backup.sh; then
  echo "  ok    backup.sh 成功后登记 RESTORE_STATE（防自还原空转）"
else
  echo "  FAIL  backup.sh 未登记 RESTORE_STATE -> 每次备份后 5 分钟会自还原并重启"; rc=1
fi
# 6) /healthz 不能用 add_header 设 Content-Type（会与 nginx 默认值叠加成两个）
if grep -q 'location = /healthz' file/start.sh && ! grep -q 'location = /healthz { add_header Content-Type' file/start.sh; then
  echo "  ok    /healthz 用 default_type 而非 add_header（避免重复 Content-Type）"
else
  echo "  FAIL  /healthz 响应头会重复 Content-Type"; rc=1
fi
# 7) 空库闸门默认值：单节点部署必须能备份
if grep -qE 'MIN_SERVERS_FOR_BACKUP:-1' file/lib.sh; then
  echo "  ok    空库闸门默认 1（只挡真正的空库）"
else
  echo "  FAIL  空库闸门默认值不是 1，单节点部署会被静默跳过备份"; rc=1
fi

echo
[ "$rc" = 0 ] && echo "== ALL PASS ==" || echo "== SOME FAILED =="
rm -rf .t
exit "$rc"
