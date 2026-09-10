#!/usr/bin/env bash
# renew.sh — 二进制自更新（面板 / agent / cloudflared）
#
# 相比原版的变更：
#   2) 进程守护：不再自己 nohup 拉起（原来会在没装 agent 时报错、且与守护循环抢启动），
#               改为「换二进制 + kill」，由 start.sh 的 supervise() 统一步拉起
#   3) 监听端口：更新后不改动 config，token 由 start.sh 的 sync_agent_secret 保证
#   失败保护：下载失败/体积异常一律保留旧二进制

set -u
cd "$(dirname "$0")" 2>/dev/null || true
[ -f ./lib.sh ] && . ./lib.sh
ensure_dirs

[ -z "${ARCH:-}" ] && { err "不支持的架构"; exit 1; }

# 取本地版本（不同版本 -v 输出格式不一，全部容错）
local_ver() {
  case "$1" in
    dashboard) "$WORK_DIR/$DASH_BIN" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    agent)     "$WORK_DIR/$AGENT_BIN" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    cloudflared) "$WORK_DIR/$CF_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
  esac
}

remote_ver() {  # remote_ver <owner/repo>
  curl -s -m 20 "https://api.github.com/repos/$1/releases/latest" \
    | grep -m1 '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

# 换二进制：下 -> 校验 -> 备份旧的 -> mv -> 失败回滚
refresh() {  # refresh <bin_name> <url> <zip|raw>
  local name="$1" url="$2" kind="$3" tmp="$TEMP/$(basename "$name")"
  mkdir -p "$TEMP"
  log "下载 $name <- $url"
  curl -sL -m 300 -o "$tmp.dl" "$url" || { warn "下载失败，保留原二进制"; return 1; }
  [ -s "$tmp.dl" ] || { warn "空响应（可能是 API 限流），保留原二进制"; rm -f "$tmp.dl"; return 1; }

  mkdir -p "$tmp.x"
  if [ "$kind" = zip ]; then
    unzip -qo "$tmp.dl" -d "$tmp.x" || { warn "解压失败"; rm -rf "$tmp.dl" "$tmp.x"; return 1; }
    local found
    found="$(find "$tmp.x" -type f -name "$(basename "$name")" | head -n1)"
    # 官方包有时放在 dist/ 子目录
    [ -z "$found" ] && found="$(find "$tmp.x" -type f -name 'dashboard-linux-*' | head -n1)"
    [ -z "$found" ] && { warn "包里找不到 $name"; rm -rf "$tmp.dl" "$tmp.x"; return 1; }
    cp -f "$found" "$tmp.new"
  else
    mv -f "$tmp.dl" "$tmp.new"
  fi

  # 体积异常保护：官方面板二进制不可能小于 8MB
  local new_bytes old_bytes=0
  new_bytes="$(wc -c < "$tmp.new")"
  [ -f "$WORK_DIR/$name" ] && old_bytes="$(wc -c < "$WORK_DIR/$name")"
  if [ "$new_bytes" -lt 8000000 ]; then
    err "新二进制仅 $new_bytes 字节，疑似错误响应，拒绝替换"
    rm -rf "$tmp.dl" "$tmp.x" "$tmp.new"; return 1
  fi

  cp -f "$WORK_DIR/$name" "$WORK_DIR/$name.prev" 2>/dev/null || true
  mv -f "$tmp.new" "$WORK_DIR/$name" && chmod +x "$WORK_DIR/$name"
  rm -rf "$tmp.dl" "$tmp.x"
  log "$name 已替换（$old_bytes -> $new_bytes 字节）"
  return 0
}

TEMP="/tmp/nezha-renew-$$"
trap 'rm -rf "$TEMP"' EXIT
updated=0

if [ -z "${DASHBOARD_VERSION:-}" ]; then
  lv="$(local_ver dashboard)"; rv="$(remote_ver nezhahq/nezha)"
  if [ -n "$rv" ] && [ "$lv" != "$rv" ]; then
    info "面板 $lv -> $rv"
    refresh "$DASH_BIN" "https://github.com/nezhahq/nezha/releases/latest/download/dashboard-linux-${ARCH}.zip" zip && updated=1
  else
    [ -z "$rv" ] && warn "取不到面板最新版（限流？），跳过" || info "面板已是最新 $lv"
  fi
fi

if [ -x "$WORK_DIR/$AGENT_BIN" ]; then
  lv="$(local_ver agent)"; rv="$(remote_ver nezhahq/agent)"
  if [ -n "$rv" ] && [ "$lv" != "$rv" ]; then
    info "agent $lv -> $rv"
    refresh "$AGENT_BIN" "https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_${ARCH}.zip" zip && updated=1
  fi
fi

if [ -n "${ARGO_AUTH:-}" ] && [ -x "$WORK_DIR/$CF_BIN" ]; then
  lv="$(local_ver cloudflared)"; rv="$(remote_ver cloudflare/cloudflared)"
  if [ -n "$rv" ] && [ "$lv" != "$rv" ]; then
    info "cloudflared $lv -> $rv"
    refresh "$CF_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" raw && updated=1
  fi
fi

if [ "$updated" = 1 ]; then
  # 只 kill，不 start：supervise() 下一周期会按最新二进制拉起，避免双实例
  info "已替换二进制，交由守护循环重启"
  pkill -f "$WORK_DIR/$DASH_BIN" 2>/dev/null || true
  [ -x "$WORK_DIR/$AGENT_BIN" ] && pkill -f "$WORK_DIR/$AGENT_BIN" 2>/dev/null || true
else
  info "全部组件均为最新"
fi
exit 0
