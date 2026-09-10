#!/usr/bin/env bash
# lib.sh — koyeb 版哪吒面板公共库（被 start/backup/restore/renew/restart source）
#
# 职责：端口体系、路径体系、状态文件（等价上游 dbfile）、备份/还原冷却标志、
#       全局操作锁、进程判活与重启退避、GitHub 仓库访问封装、SQLite 辅助。
# 约定：本文件只有定义与默认值，source 无副作用。

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="${WORK_DIR:-/app}"
LOG_DIR="${LOG_DIR:-$WORK_DIR/logs}"
STATE_DIR="${STATE_DIR:-$WORK_DIR/.state}"
FLAG_DIR="${FLAG_DIR:-$STATE_DIR/flags}"
LOCK_DIR="$STATE_DIR/lock"

# 状态记录（对齐上游 /dashboard/dbfile 的作用）
RESTORE_STATE="$STATE_DIR/restored.last"   # 已生效的备份文件名
BACKUP_STATE="$STATE_DIR/backup.last"      # 最近一次成功备份的日期

# ---------------------------------------------------------------- 架构
ARCH=""
case "$(uname -m)" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7*|armhf)  ARCH="arm" ;;
  s390x)         ARCH="s390x" ;;
esac
export ARCH

DASH_BIN="dashboard-linux-${ARCH}"
AGENT_BIN="nezha-agent"
CF_BIN="cloudflared-linux-${ARCH}"

# ---------------------------------------------------------------- 端口
# 修复点：尊重 PaaS 注入的 $PORT。Koyeb/Railway/Fly 会把流量导到随机端口，
# 原先硬编码 listen 80 会造成「直连域名 502、走隧道却正常」的假象。
HTTP_PORT="${PORT:-${HTTP_PORT:-80}}"
HTTPS_PORT="${HTTPS_PORT:-443}"
DASH_PORT="${DASH_PORT:-8008}"      # v1 面板：web 与 gRPC 同端口

# nginx 路径体系（容器内保持默认；本机调试或非 root 镜像可覆盖）
NGINX_PREFIX="${NGINX_PREFIX:-/etc/nginx}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-$NGINX_PREFIX/conf.d}"
NGINX_MAIN_CONF="${NGINX_MAIN_CONF:-$NGINX_PREFIX/nginx.conf}"

# ---------------------------------------------------------------- 调度参数
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"      # 主循环周期（秒）：守护 + 还原探测共用
BACKUP_HOUR="${BACKUP_HOUR:-4}"             # 每日自动备份小时（TZ 决定时区）
RESTORE_COOLDOWN="${RESTORE_COOLDOWN:-6}"   # 备份后跳过还原的周期数
DATA_BAK_KEEP="${DATA_BAK_KEEP:-3}"         # 本地快照保留份数
BACKUP_KEEP_COUNT="${BACKUP_KEEP_COUNT:-5}" # 远端备份保留份数
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
MAX_UPLOAD_MB="${MAX_UPLOAD_MB:-90}"
WITH_LOCK_TIMEOUT="${WITH_LOCK_TIMEOUT:-120}"
MIN_SERVERS_FOR_BACKUP="${MIN_SERVERS_FOR_BACKUP:-2}"

export TZ="${TZ:-Asia/Shanghai}"

# ---------------------------------------------------------------- 日志
# 约定：info/log 走 stdout；warn/err 走 stderr。
# 否则 `x="$(some_fn)"` 会把告警混进变量里（本轮踩过的真实坑）。
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
_logf() { printf '[%s] %s\n' "$(ts)" "$*" >> "$LOG_DIR/main.log" 2>/dev/null || true; }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; _logf "$*"; }
info() { printf '\033[32m[INFO] %s\033[0m\n' "$*"; _logf "INFO $*"; }
warn() { printf '\033[33m[WARN] %s\033[0m\n' "$*" >&2; _logf "WARN $*"; }
err()  { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; _logf "ERROR $*"; }

ensure_dirs() { mkdir -p "$WORK_DIR/data" "$LOG_DIR" "$STATE_DIR" "$FLAG_DIR" 2>/dev/null || true; }

# ---------------------------------------------------------------- 全局操作锁
# 防止 backup / restore / renew 并发。还原中途被备份拍到半成品 data/ 是致命的。
acquire_lock() {
  local name="$1" waited=0 pid
  mkdir -p "$STATE_DIR"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -f "$LOCK_DIR/owner" ]; then
      pid="$(awk '{print $1}' "$LOCK_DIR/owner" 2>/dev/null)"
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        warn "回收陈旧锁（owner pid=$pid 已退出）"
        rm -rf "$LOCK_DIR"; continue
      fi
    fi
    sleep 2; waited=$((waited + 2))
    if [ "$waited" -ge "$WITH_LOCK_TIMEOUT" ]; then
      warn "等锁超时 ${WITH_LOCK_TIMEOUT}s，跳过本次 $name"
      return 1
    fi
  done
  printf '%s %s\n' "$$" "$name" > "$LOCK_DIR/owner"
  return 0
}

release_lock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }

with_lock() {
  local name="$1"; shift
  acquire_lock "$name" || return 1
  "$@"; local rc=$?
  release_lock
  return $rc
}

# ---------------------------------------------------------------- 冷却标志（防抖核心）
# 备份完成后连续 RESTORE_COOLDOWN 个周期内禁止还原，避免：
#   1) GitHub Contents API 秒级不一致 -> 把旧备份还原回来覆盖刚写入的新数据
#   2) 刚推上去的备份被自己的轮询立刻还原（无意义停机）
# 语义同上游 /tmp/flag + 计数后缀，但周期数可配。
FLAG_PREFIX="$FLAG_DIR/backup-inprogress"

flag_arm() {
  mkdir -p "$FLAG_DIR" 2>/dev/null || true
  rm -f "$FLAG_DIR"/backup-inprogress.* 2>/dev/null || true
  printf '%s arm\n' "$(ts)" > "$FLAG_PREFIX.1"
  log "还原冷却已启动：$RESTORE_COOLDOWN 个周期（约 $((RESTORE_COOLDOWN * CHECK_INTERVAL / 60)) 分钟）"
}

flag_arm_long() {  # 回读校验失败时用更长冷却
  local n=$(( RESTORE_COOLDOWN * 3 ))
  mkdir -p "$FLAG_DIR" 2>/dev/null || true
  rm -f "$FLAG_DIR"/backup-inprogress.* 2>/dev/null || true
  printf '%s long-arm\n' "$(ts)" > "$FLAG_PREFIX.$n"
  warn "远端状态未确认，布置长冷却：$n 个周期"
}

# 返回 0 = 仍在冷却（调用方应跳过还原）；返回 1 = 可以还原
flag_tick() {
  local f n best="" bestn=0
  [ -d "$FLAG_DIR" ] || return 1
  for f in "$FLAG_DIR"/backup-inprogress.*; do
    [ -e "$f" ] || continue
    n="${f##*.}"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt "$bestn" ]; then bestn="$n"; best="$f"; fi
  done
  [ -z "$best" ] && return 1
  if [ "$bestn" -ge "$RESTORE_COOLDOWN" ]; then
    rm -f "$best"
    log "还原冷却结束（$bestn/$RESTORE_COOLDOWN），恢复自动还原"
    return 1
  fi
  # 计数 +1 并落回文件（保留原因备注，便于排查）
  printf '%s tick %s/%s\n' "$(ts)" "$((bestn + 1))" "$RESTORE_COOLDOWN" > "$FLAG_PREFIX.$((bestn + 1))"
  rm -f "$best"
  return 0
}

flag_clear() { rm -f "$FLAG_DIR"/backup-inprogress.* 2>/dev/null || true; }

# ---------------------------------------------------------------- 进程判活
# 不引入 supervisord（PaaS 内存小，多一个常驻 daemon 不划算），
# 用 pidfile + pgrep 双判据达到同等效果。
# 服务键固定四个：nginx / cloudflared / dashboard / agent
svc_pid() { cat "$STATE_DIR/pid.$1" 2>/dev/null; }

svc_pattern() {
  case "$1" in
    nginx)       printf '%s' 'nginx: master process' ;;
    cloudflared) printf '%s' "$WORK_DIR/$CF_BIN" ;;
    dashboard)   printf '%s' "$WORK_DIR/$DASH_BIN" ;;
    agent)       printf '%s' "$WORK_DIR/$AGENT_BIN" ;;
    *)           printf '%s' "$1" ;;
  esac
}

svc_alive() {
  local name="$1" pid
  pid="$(svc_pid "$name")"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  pgrep -f "$(svc_pattern "$name")" >/dev/null 2>&1
}

svc_start() {   # svc_start <key> <cmd...>
  local name="$1"; shift
  mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
  nohup "$@" >> "$LOG_DIR/$name.log" 2>&1 &
  local p=$!
  echo "$p" > "$STATE_DIR/pid.$name"
  log "启动 $name (pid $p)"
}

svc_stop() {   # svc_stop <key>  —— 先 TERM 后 KILL，并清 pidfile
  local name="$1" pid
  pid="$(svc_pid "$name")"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  pkill -f "$(svc_pattern "$name")" 2>/dev/null || true
  rm -f "$STATE_DIR/pid.$name"
  return 0
}

# 重启退避：同一进程频繁崩溃时按 5/10/20/40/80/120s 封顶，
# 避免二进制损坏时把 CPU 与 GitHub 下载配额烧光。
svc_backoff() {
  local name="$1" f fails sleep_s
  f="$STATE_DIR/fail.$name"
  fails=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$f"
  local e=$fails; [ "$e" -gt 5 ] && e=5
  sleep_s=$(( 5 * (1 << e) )); [ "$sleep_s" -gt 120 ] && sleep_s=120
  warn "$name 连续第 $fails 次异常重启，退避 ${sleep_s}s"
  sleep "$sleep_s"
}

svc_ok() { rm -f "$STATE_DIR/fail.$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- 健康探测
# 直接探面板本身（127.0.0.1:DASH_PORT），不要探 nginx —— 否则 nginx 挂了
# 会误判成面板卡死并把面板重启一遍。
dash_healthy() {
  curl -s -o /dev/null -m 8 "http://127.0.0.1:${DASH_PORT}/" 2>/dev/null
  return $?
}

nginx_healthy() {
  curl -s -o /dev/null -m 8 "http://127.0.0.1:${HTTP_PORT}/healthz" 2>/dev/null
}

# ---------------------------------------------------------------- GitHub
backup_enabled() {
  [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPO_OWNER:-}" ] && \
  [ -n "${GITHUB_REPO_NAME:-}" ] && [ -n "${ZIP_PASSWORD:-}" ]
}

gh_get() {   # gh_get </path>            JSON 输出
  curl -s -m 30 -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME$1"
}

gh_raw() {   # gh_raw </path>            原文输出；走 Contents API 而非 raw.githubusercontent，避开 CDN 缓存
  curl -sL -m 60 -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3.raw" \
    "https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME/contents$1?ref=$GITHUB_BRANCH"
}

# 从 README 解析备份文件名：兼容「首行裸文件名」与「正文内嵌」两种写法
parse_backup_name() {
  local c="${1:-}" n
  n="$(printf '%s\n' "$c" | sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;/^data-.*\.zip$/p}')"
  [ -z "$n" ] && n="$(printf '%s\n' "$c" | grep -oE 'data-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.zip' | head -n1)"
  printf '%s' "$n"
}

is_manual_backup_trigger() {
  local c; c="$(printf '%s' "${1:-}" | tr -d '[:space:]')"
  [ "$c" = "backup" ]
}

list_remote_backups() {   # 按时间倒序列出 data-*.zip
  gh_get "/contents?ref=$GITHUB_BRANCH" | jq -r '.[]?.name' 2>/dev/null \
    | grep -E '^data-.*\.zip$' | sort -r
}

# ---------------------------------------------------------------- SQLite
# 面板 DB 文件名随大版本变过（data/sqlite.db / data/db.sqlite），做一次自适应探测，
# 找不到就返回默认路径（后续调用都有 -s 判空，不会误动作）。
db_detect() {
  local d="$WORK_DIR/data" f best="" bestsz=-1
  [ -f "$d/sqlite.db" ] && { printf '%s' "$d/sqlite.db"; return 0; }
  while IFS= read -r f; do
    [ -s "$f" ] || continue
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$bestsz" ]; then bestsz="$sz"; best="$f"; fi
  done < <(find "$d" -maxdepth 1 -type f \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null)
  [ -n "$best" ] && { printf '%s' "$best"; return 0; }
  printf '%s' "$d/sqlite.db"
}

db_servers_count() {   # 取不到时输出 -1
  local db="${1:-}" n
  [ -n "$db" ] || db="$(db_detect)"
  [ -s "$db" ] || { echo "-1"; return 1; }
  command -v sqlite3 >/dev/null 2>&1 || { echo "-1"; return 1; }
  n="$(sqlite3 "$db" "SELECT COUNT(*) FROM servers;" 2>/dev/null | tr -dc '0-9')"
  [ -z "$n" ] && { echo "-1"; return 1; }
  echo "$n"
}

db_integrity_ok() {
  local db="${1:-}" r
  [ -n "$db" ] || db="$(db_detect)"
  [ -s "$db" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 0   # 无 sqlite3 时不做判定，不阻塞流程
  r="$(sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | head -n1)"
  [ "$r" = "ok" ]
}
