#!/usr/bin/env bash
# start.sh — koyeb 版哪吒面板容器入口
#
# 本轮一次性打进的 7 项能力（对应上游 Docker-for-Nezha-Argo-server-v1.x）：
#   1) 预置数据   preseed_data()      —— 可选导入 SEED_DB_URL、坏库隔离、config.yaml 模板、agent_secret_key 对齐
#   2) 进程守护   supervise()         —— 每周期 pidfile + HTTP 双判活，异常自动拉起，崩溃退避
#   3) 监听端口   $PORT 生效          —— nginx 与探活全部使用 HTTP_PORT/HTTPS_PORT/DASH_PORT
#   4) 本机探针   write_agent_config()—— NZ_TARGET=local|tunnel 可选直连，token 漂移自愈
#   5) 备份范围   backup.sh           —— 空库闸门 + resource 自定义主题 + 瘦身 + 副本自检
#   6) 还原时机   periodic_restore()  —— 开机还原 + 运行期轮询热还原（RESTORE_STATE 判重）
#   7) 防抖       lib.sh              —— 全局操作锁 + 备份后还原冷却 + 远端回读校验 + 还原后完整性回滚

set -uo pipefail

cd "$(dirname "$0")" 2>/dev/null || true
if [ ! -f ./lib.sh ]; then
  echo "[FATAL] 缺少 lib.sh（应与 start.sh 同目录）" >&2
  exit 1
fi
# shellcheck source=lib.sh
. ./lib.sh

[ -z "$ARCH" ] && { echo "[FATAL] 不支持的架构: $(uname -m)" >&2; exit 1; }

CONFIG_FILE="$WORK_DIR/data/config.yaml"
AGENT_CFG="$WORK_DIR/agent-config.yml"
NZ_TARGET="${NZ_TARGET:-tunnel}"
FORCE_AUTH="${Force_Auth:-false}"
PRESET_CONFIG="${PRESET_CONFIG:-true}"
DASH_VER_PIN="${DASHBOARD_VERSION:-}"

# ------------------------------------------------------------------ 环境校验
check_env() {
  if [ -z "${NZ_CLIENT_SECRET:-}" ]; then
    err "NZ_CLIENT_SECRET 未设置（面板 agent_secret_key / 探针 token），容器退出"
    exit 1
  fi
  [ -z "${ARGO_AUTH:-}" ] && warn "ARGO_AUTH 未设置：无 CF 隧道，面板只能靠 \$PORT 直连访问"
  if backup_enabled; then
    info "在线备份已启用：$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME@$GITHUB_BRANCH"
  else
    warn "备份变量不全（GITHUB_TOKEN / GITHUB_REPO_OWNER / GITHUB_REPO_NAME / ZIP_PASSWORD）→ 备份与热还原全部关闭"
  fi
  log "端口规划：HTTP=$HTTP_PORT (来自 \$PORT=${PORT:-未注入}) HTTPS=$HTTPS_PORT 面板=$DASH_PORT | 探针目标=$NZ_TARGET"
}

# ================================================================== 1) 预置数据
# 原版把 config.yaml 全交给面板首启生成，带来两个问题：
#   a) 还原带回的旧 config.yaml 里的 agent_secret_key 会盖掉 env 的 token -> 探针集体掉线
#   b) 面板生成 config 之前存在一段无 key 的窗口
# 这里做「预置 + 每次启动/每周期强制对齐」，等价于上游预置 sqlite.db + 回写 token 的作用，
# 但不引入第三方 DB（安全边界保留）。
preseed_data() {
  mkdir -p "$WORK_DIR/data" "$WORK_DIR/logs"
  local DB_FILE
  DB_FILE="$(db_detect)"
  export DB_FILE

  # 1a. 可选预置库（对齐上游 sqlite.db 预置能力，由用户提供 URL，不内置）
  if [ ! -s "$DB_FILE" ] && [ -n "${SEED_DB_URL:-}" ]; then
    log "导入预置数据库：$SEED_DB_URL"
    if curl -sL -m 300 -o "$DB_FILE.part" "$SEED_DB_URL" && [ -s "$DB_FILE.part" ]; then
      mv -f "$DB_FILE.part" "$DB_FILE"
      info "预置库导入完成"
    else
      rm -f "$DB_FILE.part"
      warn "预置库拉取失败，回退为空库"
    fi
  fi

  # 1b. 坏库隔离：带病启动会让面板起不来且随后把好备份挤掉
  if [ -s "$DB_FILE" ] && ! db_integrity_ok "$DB_FILE"; then
    warn "sqlite.db 完整性检查失败 -> 隔离为 $(basename "$DB_FILE").corrupt 并重建"
    mv -f "$DB_FILE" "${DB_FILE}.corrupt.$(date +%s)"
  fi

  # 1c. config.yaml 模板（PRESET_CONFIG=false 可关闭，交回面板自建）
  if [ ! -s "$CONFIG_FILE" ] && [ "$PRESET_CONFIG" != "false" ]; then
    log "预置 data/config.yaml"
    cat > "$CONFIG_FILE" <<EOF
site_name: ${SITE_NAME:-Nezha}
enable_pprof: false
force_auth: $FORCE_AUTH
agent_secret_key: $NZ_CLIENT_SECRET
listen_host: 0.0.0.0
listen_port: $DASH_PORT
EOF
    [ -n "${GH_CLIENTID:-}" ] && [ -n "${GH_CLIENTSECRET:-}" ] && cat >> "$CONFIG_FILE" <<EOF
oauth2:
  GitHub:
    client_id: "$GH_CLIENTID"
    client_secret: "$GH_CLIENTSECRET"
    endpoint:
      auth_url: "https://github.com/login/oauth/authorize"
      token_url: "https://github.com/login/oauth/access_token"
    user_info_url: "https://api.github.com/user"
    user_id_path: "id"
EOF
  fi

  # 1d. token 对齐（核心）+ force_auth 保持原语义
  sync_agent_secret
  apply_force_auth
}

# 让 config.yaml 的 agent_secret_key 恒等于 env 的 NZ_CLIENT_SECRET。
# 返回 0=有改动（调用方需重启面板），1=无需改动
sync_agent_secret() {
  # 契约：返回 0(真) = 本次有改动，调用方需重启面板；返回 1(假) = 无改动，勿重启。
  [ -f "$CONFIG_FILE" ] || return 1
  local cur changed=0
  cur="$(grep -E '^[[:space:]]*agent_secret_key:' "$CONFIG_FILE" | head -n1 \
          | sed -E 's/^[[:space:]]*agent_secret_key:[[:space:]]*//' | tr -d "\"' " )"
  if [ -z "$cur" ]; then
    printf 'agent_secret_key: %s\n' "$NZ_CLIENT_SECRET" >> "$CONFIG_FILE"
    log "config.yaml 缺少 agent_secret_key，已注入"
    changed=1
  elif [ "$cur" != "$NZ_CLIENT_SECRET" ]; then
    warn "检测到 token 漂移（库内 $cur ≠ env），已按 env 改写"
    sed -i -E "s|^[[:space:]]*agent_secret_key:.*|agent_secret_key: $NZ_CLIENT_SECRET|" "$CONFIG_FILE"
    changed=1
  fi
  [ "$changed" = 1 ] && return 0 || return 1
}

apply_force_auth() {
  [ -f "$CONFIG_FILE" ] || return 0
  if grep -q '^force_auth:' "$CONFIG_FILE"; then
    sed -i "s/^force_auth:.*/force_auth: $FORCE_AUTH/" "$CONFIG_FILE"
  else
    printf 'force_auth: %s\n' "$FORCE_AUTH" >> "$CONFIG_FILE"
  fi
}

# ================================================================== 3) 监听端口 + 反代
setup_ssl() {
  if [ ! -s "$WORK_DIR/nezha.pem" ] || [ ! -s "$WORK_DIR/nezha.key" ]; then
    openssl genrsa -out "$WORK_DIR/nezha.key" 2048 >/dev/null 2>&1
    openssl req -new -key "$WORK_DIR/nezha.key" -out "$WORK_DIR/nezha.csr" \
      -subj "/CN=${ARGO_DOMAIN:-localhost}" >/dev/null 2>&1
    openssl x509 -req -days 3650 -in "$WORK_DIR/nezha.csr" -signkey "$WORK_DIR/nezha.key" \
      -out "$WORK_DIR/nezha.pem" >/dev/null 2>&1
  fi
  chmod 600 "$WORK_DIR/nezha.key" 2>/dev/null || true
  chmod 644 "$WORK_DIR/nezha.pem" 2>/dev/null || true
}

create_nginx_config() {
  mkdir -p "$NGINX_CONF_DIR" 2>/dev/null || true
  # 注意：这里必须用未加引号的 heredoc，让 ${HTTP_PORT} 等变量展开（原版写死了 80/443）
  cat > "$NGINX_CONF_DIR/default.conf" <<NGX
map \$http_x_forwarded_for \$xff_first_ip {
    default "";
    "~^(?P<first>[^,]+)" \$first;
}
map \$http_cf_connecting_ip \$real_ip {
    default \$xff_first_ip;
    "~.+"   \$http_cf_connecting_ip;
}
map \$real_ip \$final_ip {
    default \$remote_addr;
    "~.+"   \$real_ip;
}

server {
    listen ${HTTP_PORT} default_server;
    listen [::]:${HTTP_PORT} default_server;
    http2 on;
    server_name _;
    underscores_in_headers on;

    # 给 PaaS 健康检查用的静态端点（不打到面板，面板挂了它也返回 200，
    # 所以只用于「容器活着」，真正的面板探活由 supervise() 直连 $DASH_PORT）
    location = /healthz { add_header Content-Type text/plain; return 200 "ok"; }

    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$final_ip;
        grpc_set_header CF-Connecting-IP \$final_ip;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://dashboard;
    }

    location ~* ^/api/v1/ws/(server|terminal|file)(.*)\$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$final_ip;
        proxy_set_header CF-Connecting-IP \$final_ip;
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:${DASH_PORT};
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$final_ip;
        proxy_set_header CF-Connecting-IP \$final_ip;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        proxy_pass http://127.0.0.1:${DASH_PORT};
    }
}

upstream dashboard {
    server 127.0.0.1:${DASH_PORT};
    keepalive 2048;
    keepalive_requests 20000;
}
NGX

  # 443：隧道回源用（自签证书，TLS 实际由 CF edge 终结）
  cat > "$NGINX_CONF_DIR/ssl.conf" <<SSL
server {
    listen ${HTTPS_PORT} ssl;
    listen [::]:${HTTPS_PORT} ssl;
    http2 on;
    server_name _;
    ssl_certificate     $WORK_DIR/nezha.pem;
    ssl_certificate_key $WORK_DIR/nezha.key;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    underscores_in_headers on;

    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$final_ip;
        grpc_set_header CF-Connecting-IP \$final_ip;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_pass grpc://dashboard;
    }

    location ~* ^/api/v1/ws/(server|terminal|file)(.*)\$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$final_ip;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_pass http://127.0.0.1:${DASH_PORT};
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$final_ip;
        proxy_set_header CF-Connecting-IP \$final_ip;
        proxy_read_timeout 3600s;
        proxy_pass http://127.0.0.1:${DASH_PORT};
    }
}
SSL

  # 主配置：mime.types / include 路径全部跟随 $NGINX_PREFIX 与 $NGINX_CONF_DIR
  cat > "$NGINX_MAIN_CONF" <<MAIN
user  nginx;
worker_processes  auto;
worker_rlimit_nofile 65535;
error_log  /var/log/nginx/error.log notice;
pid        /run/nginx.pid;
events { worker_connections 20480; }
http {
    include       $NGINX_PREFIX/mime.types;
    default_type  application/octet-stream;
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  65;
    http2_max_concurrent_streams 2048;
    include $NGINX_CONF_DIR/*.conf;
}
MAIN

  # 非 root / 非常规前缀（本机调试）时跳过校验；容器内 nginx 一定存在
  if command -v nginx >/dev/null 2>&1; then
    if ! nginx -t -c "$NGINX_MAIN_CONF" >/dev/null 2>&1; then
      err "nginx 配置校验失败（若因缺少 mime.types 可忽略，容器内不会出现）："
      nginx -t -c "$NGINX_MAIN_CONF" 2>&1 | sed 's/^/    /'
      [ -f "$NGINX_PREFIX/mime.types" ] && exit 1
      warn "缺少 $NGINX_PREFIX/mime.types，跳过 nginx -t"
    fi
  else
    warn "环境无 nginx 可执行文件，跳过 nginx -t"
  fi
  log "nginx 配置生成完成：http=$HTTP_PORT https=$HTTPS_PORT -> 127.0.0.1:$DASH_PORT"
}

# ------------------------------------------------------------------ 二进制
download_binaries() {
  local zip_url
  if [ ! -x "$WORK_DIR/$DASH_BIN" ]; then
    if [ -n "$DASH_VER_PIN" ]; then
      zip_url="https://github.com/nezhahq/nezha/releases/download/${DASH_VER_PIN}/dashboard-linux-${ARCH}.zip"
    else
      zip_url="https://github.com/nezhahq/nezha/releases/latest/download/dashboard-linux-${ARCH}.zip"
    fi
    log "下载面板：$zip_url"
    curl -sL -m 600 -o /tmp/dash.zip "$zip_url" || { err "面板下载失败"; exit 1; }
    unzip -qo /tmp/dash.zip -d "$WORK_DIR" || { err "面板解压失败"; exit 1; }
    rm -f /tmp/dash.zip
    # 官方包结构在 0.x/1.x 之间变过：有的直接平铺，有的在 dist/ 下
    if [ ! -f "$WORK_DIR/$DASH_BIN" ] && [ -f "$WORK_DIR/dist/$DASH_BIN" ]; then
      mv -f "$WORK_DIR/dist/$DASH_BIN" "$WORK_DIR/$DASH_BIN"
    fi
    rm -rf "$WORK_DIR/dist"
    chmod +x "$WORK_DIR/$DASH_BIN"
  fi

  if [ -n "${NZ_UUID:-}" ] && [ -x "$WORK_DIR/$DASH_BIN" ] && [ ! -x "$WORK_DIR/$AGENT_BIN" ]; then
    log "下载 agent"
    curl -sL -m 300 -o /tmp/agent.zip "https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_${ARCH}.zip" \
      && unzip -qo /tmp/agent.zip -d "$WORK_DIR" && rm -f /tmp/agent.zip \
      && chmod +x "$WORK_DIR/$AGENT_BIN" \
      || warn "agent 下载失败（面板仍可运行，只是无本机节点）"
  fi

  if [ -n "${ARGO_AUTH:-}" ] && [ ! -x "$WORK_DIR/$CF_BIN" ]; then
    log "下载 cloudflared"
    curl -sL -m 300 -o "$WORK_DIR/$CF_BIN" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
      && chmod +x "$WORK_DIR/$CF_BIN" \
      || err "cloudflared 下载失败，隧道不可用"
  fi
}

# ================================================================== 4) 本机探针
# 原版只支持「绕 CF 回连」（多两跳、隧道故障时自己也掉线）。
# 这里加 NZ_TARGET=local 走 127.0.0.1:$DASH_PORT 直连，隧道挂了本机节点仍显示在线。
write_agent_config() {
  [ -n "${NZ_UUID:-}" ] || { log "未设置 NZ_UUID，跳过本机探针"; return 0; }
  local server tls
  if [ "$NZ_TARGET" = "local" ]; then
    server="127.0.0.1:${DASH_PORT}"; tls="false"
  else
    server="${ARGO_DOMAIN:-127.0.0.1}:443"; tls="${NZ_TLS:-true}"
  fi
  cat > "$AGENT_CFG" <<EOF
client_secret: $NZ_CLIENT_SECRET
debug: false
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 3
server: $server
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: $tls
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $NZ_UUID
EOF
  log "探针配置：server=$server tls=$tls uuid=$NZ_UUID"
}

agent_wanted() { [ -n "${NZ_UUID:-}" ] && [ -x "$WORK_DIR/$AGENT_BIN" ]; }

# ================================================================== 2) 进程守护
start_all() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if ! svc_alive nginx; then
    nginx -s stop >/dev/null 2>&1 || true; sleep 1
    svc_start nginx nginx -g 'daemon off;'
  fi
  if [ -n "${ARGO_AUTH:-}" ] && [ -x "$WORK_DIR/$CF_BIN" ] && ! svc_alive cloudflared; then
    svc_start cloudflared "$WORK_DIR/$CF_BIN" tunnel --edge-ip-version auto --protocol http2 run --token "$ARGO_AUTH"
  fi
  if ! svc_alive dashboard; then
    svc_start dashboard "$WORK_DIR/$DASH_BIN"
    sleep 3
  fi
  if agent_wanted && ! svc_alive agent; then
    svc_start agent "$WORK_DIR/$AGENT_BIN" -c "$AGENT_CFG"
  fi
}

# 每周期执行：四进程判活 + 面板 HTTP 探活 + token 漂移自愈
supervise() {
  local need_restart=0

  svc_alive nginx       || { warn "nginx 未运行";        need_restart=1; }
  svc_alive dashboard   || { warn "面板进程未运行";      need_restart=1; }
  if [ -n "${ARGO_AUTH:-}" ] && [ -x "$WORK_DIR/$CF_BIN" ] && ! svc_alive cloudflared; then
    warn "cloudflared 未运行"; need_restart=1
  fi
  if agent_wanted && ! svc_alive agent; then
    warn "agent 未运行"
    with_lock supervise-agent ./restart.sh agent
  fi

  # 面板进程活着但 HTTP 无响应（死锁/502 自环）——pkill 型检测发现不了，必须探 HTTP
  if svc_alive dashboard && ! dash_healthy; then
    warn "面板进程在但 HTTP 无响应，判定为卡死"
    svc_stop dashboard
    need_restart=1
  fi

  if [ "$need_restart" = 1 ]; then
    start_all
    sleep 5
    if dash_healthy && svc_alive nginx; then
      svc_ok dashboard
      log "守护检查：服务已恢复"
    else
      svc_backoff dashboard
    fi
  else
    svc_ok dashboard
  fi

  # token 漂移自愈：还原或面板自写都可能把 config.yaml 改回去
  if sync_agent_secret; then
    warn "agent_secret_key 被外部改动，已复位并重启面板"
    with_lock supervise-dash ./restart.sh dashboard
  fi
}

# ================================================================== 6) 还原时机
# 开机还原一次（原版行为）+ 运行期按 RESTORE_STATE 判重热还原（上游每分钟轮询的精简版）
boot_restore() {
  backup_enabled || return 0
  [ "${SKIP_BOOT_RESTORE:-}" = "1" ] && { info "SKIP_BOOT_RESTORE=1，跳过开机还原"; return 0; }
  log "开机自动还原"
  if acquire_lock boot-restore; then
    ./restore.sh a
    local rc=$?
    release_lock
    [ "$rc" = 0 ] && log "开机还原流程结束（exit $rc）"
  else
    warn "未取得锁，跳过开机还原"
  fi
}

periodic_restore() {
  backup_enabled || return 0
  [ "${NO_RES:-0}" = "1" ] && return 0
  flag_tick && return 0                       # 仍在备份冷却期

  local readme online last
  readme="${1:-}"
  [ -z "$readme" ] && readme="$(gh_raw /README.md 2>/dev/null)"
  [ -z "$readme" ] && return 0                # API 不可达/限流：不动数据
  is_manual_backup_trigger "$readme" && return 0

  online="$(parse_backup_name "$readme")"
  case "$online" in
    data-*.zip) ;;
    *) warn "README 未解析到备份文件名（得到 '$online'），不执行还原"; return 0 ;;
  esac

  last="$(cat "$RESTORE_STATE" 2>/dev/null)"
  [ "$online" = "$last" ] && return 0

  log "检测到新备份：$online（当前=${last:-无}）→ 执行热还原"
  if acquire_lock auto-restore; then
    if ./restore.sh "$online"; then
      release_lock
      preseed_data                            # 关键：还原带回的旧 token 立刻按 env 复位
      write_agent_config
      with_lock restore-restart ./restart.sh all
      info "热还原完成并已重启服务"
    else
      release_lock
      warn "热还原失败，保持现有数据继续运行"
    fi
  fi
}

# ------------------------------------------------------------------ 备份调度
# 原版用「README 里的日期 != 今天」判定，但 backup.sh 写的是 Markdown 正文，
# 行首不是 data-...zip，那条 sed 永远取空 -> 判定恒真。改用本地 BACKUP_STATE。
schedule_backup() {
  backup_enabled || return 0
  local today nowh readme
  today="$(date +%Y-%m-%d)"
  nowh="$(date +%-H)"
  readme="${1-}"
  [ -z "$readme" ] && readme="$(gh_raw /README.md 2>/dev/null)"

  if is_manual_backup_trigger "$readme"; then
    log "README 内容为 backup → 触发手动备份"
    with_lock manual-backup ./backup.sh m
    return 0
  fi

  if [ "$nowh" -eq "$BACKUP_HOUR" ] 2>/dev/null; then
    if [ "$(cat "$BACKUP_STATE" 2>/dev/null)" != "$today" ]; then
      log "进入每日备份窗口（${BACKUP_HOUR}:00）"
      with_lock daily-backup ./backup.sh a
    fi
  fi
}

# 版本自更新：只在未 pin 版本时，每天最多一次，凌晨低峰
schedule_renew() {
  [ -z "${DASH_VER_PIN:-}" ] || return 0
  [ "${NO_AUTO_RENEW:-0}" = "1" ] && return 0
  local marker day
  marker="$STATE_DIR/renew.last"
  day="$(date +%Y-%m-%d)"
  [ "$(cat "$marker" 2>/dev/null)" = "$day" ] && return 0
  [ "$(date +%-H)" -lt "$BACKUP_HOUR" ] && return 0
  log "检查组件版本更新"
  if acquire_lock renew; then
    ./renew.sh; rc=$?
    release_lock
    [ "$rc" = 0 ] && echo "$day" > "$marker"
  fi
}

# ------------------------------------------------------------------ 主流程
main() {
  ensure_dirs
  check_env

  boot_restore            # 先恢复数据
  preseed_data            # 再预置/对齐（顺序很重要：预置在还原之后，否则被还原盖掉）

  setup_ssl
  create_nginx_config
  download_binaries
  write_agent_config
  start_all

  # 状态记录由 restore.sh 成功时自行写入（RESTORE_STATE），
  # 这里不重复记录，避免「开机还原失败却被标记为已同步」而永不重试。
  info "面板已启动：http://<域名>:\$PORT=$HTTP_PORT  隧道回源 :$HTTPS_PORT  内部 $DASH_PORT"
  info "守护周期 ${CHECK_INTERVAL}s | 备份小时 ${BACKUP_HOUR}:00 | 还原冷却 ${RESTORE_COOLDOWN} 周期"

  while true; do
    supervise

    # 一个周期只取一次 README，备份调度与热还原共用（原版逻辑里两处各拉一次，
    # 未认证时 60 次/小时的 GitHub 限额很容易被耗光，导致自动更新静默失效）
    if backup_enabled; then
      CYCLE_README="$(gh_raw /README.md 2>/dev/null)"
    else
      CYCLE_README=""
    fi
    schedule_backup "$CYCLE_README"
    periodic_restore "$CYCLE_README"
    schedule_renew
    sleep "$CHECK_INTERVAL"
  done
}

# ------------------------------------------------------------------ 调试入口
# start.sh render-nginx   只渲染 nginx 配置后退出（用于校验 $PORT 是否真的生效）
# start.sh self-test      跑一遍纯 shell 自检，不碰网络不启进程
case "${1:-}" in
  render-nginx)
    ensure_dirs; setup_ssl; create_nginx_config
    echo "--- $NGINX_CONF_DIR/default.conf (listen 行) ---"
    grep -n 'listen' "$NGINX_CONF_DIR/default.conf" "$NGINX_CONF_DIR/ssl.conf"
    exit 0 ;;
  self-test)
    ensure_dirs
    echo "ARCH=$ARCH HTTP_PORT=$HTTP_PORT HTTPS_PORT=$HTTPS_PORT DASH_PORT=$DASH_PORT"
    echo "DASH_BIN=$DASH_BIN CF_BIN=$CF_BIN"
    flag_arm; flag_tick && echo "cooldown=active" || echo "cooldown=free"
    flag_clear
    acquire_lock selftest && { echo "lock=ok"; release_lock; } || echo "lock=FAIL"
    echo "self-test done"
    exit 0 ;;
esac

main "$@"