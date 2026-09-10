#!/usr/bin/env bash
# restart.sh — 手动/被调重启组件
#
# 变更点（对应「进程守护」一项）：
#   - 复用 lib.sh 的 svc_stop/svc_start，杀进程统一走 pidfile+TERM→KILL，不再裸 pkill
#   - 重启后做 HTTP 探活确认，原版 pkill + nohup 后直接返回，成败未知
#   - 顺带对齐 config.yaml 的 token（restart dashboard 时）
#
# 用法：restart.sh [dashboard|agent|nginx|cloudflared|all]

set -u
cd "$(dirname "$0")" 2>/dev/null || true
if [ ! -f ./lib.sh ]; then echo "[FATAL] 缺少 lib.sh" >&2; exit 1; fi
. ./lib.sh
ensure_dirs

WHAT="${1:-dashboard}"

start_one() {
  case "$1" in
    dashboard)
      [ -x "$WORK_DIR/$DASH_BIN" ] || { warn "没有可执行的 $DASH_BIN"; return 1; }
      svc_start dashboard "$WORK_DIR/$DASH_BIN" ;;
    agent)
      [ -n "${NZ_UUID:-}" ] || { info "未设置 NZ_UUID，跳过 agent"; return 0; }
      [ -x "$WORK_DIR/$AGENT_BIN" ] || { info "未安装 agent，跳过"; return 0; }
      [ -f "$WORK_DIR/agent-config.yml" ] || { warn "缺少 agent-config.yml"; return 1; }
      svc_start agent "$WORK_DIR/$AGENT_BIN" -c "$WORK_DIR/agent-config.yml" ;;
    nginx)
      svc_start nginx nginx -g 'daemon off;' ;;
    cloudflared)
      [ -n "${ARGO_AUTH:-}" ] || { info "未配置 ARGO_AUTH，跳过 cloudflared"; return 0; }
      [ -x "$WORK_DIR/$CF_BIN" ] || { warn "缺少 $CF_BIN"; return 1; }
      svc_start cloudflared "$WORK_DIR/$CF_BIN" tunnel --edge-ip-version auto --protocol http2 run --token "$ARGO_AUTH" ;;
    *) err "未知组件：$1"; return 1 ;;
  esac
}

# 重启顺序：先起反代与隧道，再起面板，最后起探针（探针依赖面板可达）
if [ "$WHAT" = all ]; then
  ORDER_UP="nginx cloudflared"
  ORDER_DOWN="agent dashboard"
  for c in $ORDER_DOWN $ORDER_UP; do
    log "停止 $c"
    svc_stop "$c"
  done
  sleep 1
  # token 对齐必须在面板启动前完成，否则探针连上又被拒
  [ -f "$WORK_DIR/data/config.yaml" ] && \
    sed -i -E "s|^[[:space:]]*agent_secret_key:.*|agent_secret_key: ${NZ_CLIENT_SECRET:-}|" \
      "$WORK_DIR/data/config.yaml" 2>/dev/null || true
  for c in $ORDER_UP $ORDER_DOWN; do
    log "启动 $c"
    start_one "$c"
    [ "$c" = dashboard ] && sleep 3
  done
else
  log "重启 $WHAT"
  svc_stop "$WHAT"
  sleep 1
  start_one "$WHAT" || exit 1
  [ "$WHAT" = dashboard ] && sleep 3
fi

# 确认面板可达（面板不在关注列表时只做进程判活）
for _i in 1 2 3 4 5 6; do
  sleep 2
  if [ "$WHAT" = dashboard ] || [ "$WHAT" = all ] || [ "$WHAT" = nginx ]; then
    if dash_healthy; then info "$WHAT 重启成功，面板 HTTP 探活通过"; exit 0; fi
  else
    if svc_alive "$WHAT"; then info "$WHAT 重启成功"; exit 0; fi
  fi
done

err "$WHAT 重启后仍未就绪（详见 $LOG_DIR/），请人工检查"
exit 1
