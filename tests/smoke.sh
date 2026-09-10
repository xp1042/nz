#!/usr/bin/env bash
# 本机冒烟测试 lib.sh 的纯 shell 逻辑（不需要网络/面板/sqlite 也能跑）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# 允许从项目根或 tests/ 目录运行
[ -f "$ROOT/file/lib.sh" ] || ROOT="$(cd "$ROOT/.." && pwd)"
export WORK_DIR="$ROOT/.t/app"
export WITH_LOCK_TIMEOUT=4
rm -rf "$ROOT/.t"; mkdir -p "$WORK_DIR"
. "$ROOT/file/lib.sh"
ensure_dirs

fail=0
chk() {
  if [ "$2" = "$3" ]; then echo "  ok    $1"
  else echo "  FAIL  $1 | got[$2] want[$3]"; fail=1; fi
}

echo "== 3) 监听端口体系 =="
chk "lib 里 HTTP_PORT"    "${HTTP_PORT}"   "80"
chk "HTTPS_PORT"          "${HTTPS_PORT}"  "443"
chk "DASH_PORT"           "${DASH_PORT}"   "8008"
chk "DASH_BIN 含架构"     "$([ -n "$DASH_BIN" ] && echo yes)" "yes"
p=$(PORT=8080 bash -c 'WORK_DIR='"$WORK_DIR"' . '"$ROOT"'/file/lib.sh; echo "$HTTP_PORT"')
chk "注入 PORT=8080 生效" "$p" "8080"

echo "== 6) README 文件名解析 =="
n=$(parse_backup_name "data-2025-01-02-03-04-05.zip
# Nezha 数据备份
- 最新备份：\`data-2025-01-02-03-04-05.zip\`")
chk "首行裸文件名式" "$n" "data-2025-01-02-03-04-05.zip"
n=$(parse_backup_name "# Nezha 数据备份
- 最新备份：\`data-2024-12-31-00-00-00.zip\`")
chk "正文内嵌式(旧版)" "$n" "data-2024-12-31-00-00-00.zip"
n=$(parse_backup_name "backup")
chk "backup 标记不误判" "$n" ""
n=$(parse_backup_name "")
chk "空 README" "$n" ""

echo "== 7a) 手动备份标记判定 =="
is_manual_backup_trigger "backup"            && r=yes || r=no; chk "精确 backup"            "$r" "yes"
is_manual_backup_trigger "$(printf '  backup  \n\n')" && r=yes || r=no; chk "带空白仍算"             "$r" "yes"
is_manual_backup_trigger "# xx
手动触发备份：把本文件内容整体改为 backup。" && r=yes || r=no; chk "正文含backup不算触发"   "$r" "no"

echo "== 7b) 还原冷却（防抖核心）=="
flag_clear
flag_tick && r=locked || r=free; chk "无标志 -> 允许还原" "$r" "free"
RESTORE_COOLDOWN=3
flag_arm
flag_tick && r=locked || r=free; chk "tick1 -> 仍冷却" "$r" "locked"
flag_tick && r=locked || r=free; chk "tick2 -> 仍冷却" "$r" "locked"
flag_tick && r=locked || r=free; chk "tick3 -> 释放"   "$r" "free"
flag_tick && r=locked || r=free; chk "释放后 -> 允许"  "$r" "free"
n=$(ls -1 "$FLAG_DIR" 2>/dev/null | grep -c 'backup-inprogress' || true)
chk "释放后标志已清空" "$n" "0"
flag_arm_long
n=$(ls -1 "$FLAG_DIR" | sed -n 's/.*backup-inprogress\.\(.*\)/\1/p' | sort -rn | head -n1)
chk "长冷却为3倍" "$n" "$((3*RESTORE_COOLDOWN))"
flag_clear

echo "== 7c) 全局操作锁 =="
acquire_lock t1 && r=got || r=busy; chk "首次拿锁" "$r" "got"
p=$(bash -c "WORK_DIR=$WORK_DIR WITH_LOCK_TIMEOUT=4 . $ROOT/file/lib.sh; ensure_dirs; acquire_lock t2 && echo got || echo busy")
chk "并发第二个应 busy" "$p" "busy"
release_lock
acquire_lock t3 && r=got || r=busy; chk "释放后可再拿" "$r" "got"
release_lock

echo "== 7d) 陈旧锁自愈 =="
mkdir -p "$STATE_DIR"; rmdir "$LOCK_DIR" 2>/dev/null
mkdir -p "$LOCK_DIR"; printf '999999 dead\n' > "$LOCK_DIR/owner"
acquire_lock reclaim && r=got || r=busy
chk "owner 进程已死可抢占" "$r" "got"
release_lock

echo "== 2) 进程判活 / 退避 =="
sleep 30 & bg=$!
mkdir -p "$STATE_DIR"; echo "$bg" > "$STATE_DIR/pid.fakeproc"
svc_alive fakeproc && r=alive || r=dead; chk "pid 存活 -> alive" "$r" "alive"
kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null
rm -f "$STATE_DIR/pid.fakeproc"
svc_alive fakeproc && r=alive || r=dead; chk "无 pid 无进程 -> dead" "$r" "dead"
chk "svc_pattern(dashboard)" "$(svc_pattern dashboard)" "$WORK_DIR/dashboard-linux-${ARCH}"
# 退避：只验计数文件，不真 sleep
echo 3 > "$STATE_DIR/fail.demo"
chk "退避计数可读回" "$(cat "$STATE_DIR/fail.demo")" "3"

echo "== 5) SQLite 辅助 =="
c=$(db_servers_count "$WORK_DIR/data/nope.db"); chk "缺库 -> -1" "$c" "-1"
db_integrity_ok "$WORK_DIR/data/nope.db" && r=ok || r=bad; chk "缺库 -> bad" "$r" "bad"

echo "== 1) 预置 config.yaml（模拟面板 data 目录）=="
mkdir -p "$WORK_DIR/data"
printf 'site_name: Nezha\nagent_secret_key: OLD_TOKEN_FROM_BACKUP\nlisten_port: 8008\n' > "$WORK_DIR/data/config.yaml"
export NZ_CLIENT_SECRET=NEW_TOKEN_FROM_ENV
sync() {
  local cfg="$WORK_DIR/data/config.yaml" cur
  cur="$(grep -E '^[[:space:]]*agent_secret_key:' "$cfg" | head -n1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d "\"' ")"
  if [ "$cur" != "$NZ_CLIENT_SECRET" ]; then
    sed -i -E "s|^[[:space:]]*agent_secret_key:.*|agent_secret_key: $NZ_CLIENT_SECRET|" "$cfg"
  fi
}
sync
got=$(grep agent_secret_key "$WORK_DIR/data/config.yaml" | awk '{print $2}')
chk "token 漂移已按 env 复位" "$got" "NEW_TOKEN_FROM_ENV"

echo
[ "$fail" = 0 ] && echo "== ALL PASS ==" || echo "== SOME FAILED =="
rm -rf "$ROOT/.t"
exit $fail
