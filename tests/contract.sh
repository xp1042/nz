#!/usr/bin/env bash
# 谓词返回值极性 + 冷却时长回归。
# 起因两条实机/审查发现的缺陷：
#   a) sync_agent_secret 返回语义反转 -> 面板每 60s 误重启（实机揪出并已修）
#   b) flag_arm_long 的后缀曾是"已耗计数"，与 flag_tick 的全局阈值判定不匹配
#      -> 3 倍长冷却在第一个 tick 即被判到期清除，实际保护 0 个周期
# 这类问题静态检查看不见，只能把"极性和时长"写成断言锁死。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"          # 放项目根或 tests/ 均可
[ -f "$ROOT/file/lib.sh" ] || ROOT="$(cd "$ROOT/.." && pwd)"
cd "$ROOT" || exit 1

# 关键：lib.sh 在 source 的那一刻就按当时的 WORK_DIR 算好 STATE_DIR/FLAG_DIR/LOCK_DIR，
# 所以所有路径变量必须在 source 之前导出（本文件第一版就栽在顺序上）。
export WORK_DIR="$ROOT/.contract"
export LOG_DIR="$WORK_DIR/logs" STATE_DIR="$WORK_DIR/.state" FLAG_DIR="$WORK_DIR/.state/flags"
export WITH_LOCK_TIMEOUT=4                      # 争锁会真等，缩短以免挂住
# shellcheck disable=SC1091
. ./file/lib.sh

ok=0; bad=0
chk(){ if [ "$2" = ok ]; then ok=$((ok+1)); printf '  ok    %s\n' "$1"; else bad=$((bad+1)); printf '  FAIL  %s (%s)\n' "$1" "${3:-}"; fi; }
truth(){ # truth <描述> <期望真值 0真|1假> <命令...>
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local r=$?
  if { [ "$want" = 0 ] && [ "$r" -eq 0 ]; } || { [ "$want" = 1 ] && [ "$r" -ne 0 ]; }; then
    chk "$desc" ok
  else
    chk "$desc" fail "rc=$r 期望 want=$want"
  fi
}
# 数出"从布置到释放，一共拦下多少个周期"
count_locked(){ local n=0; while flag_tick >/dev/null 2>&1; do n=$((n+1)); [ "$n" -gt 200 ] && break; done; printf '%s' "$n"; }

ensure_dirs
[ -d "$FLAG_DIR" ] || mkdir -p "$FLAG_DIR"

echo "[路径隔离自检]"
if [ "${FLAG_DIR#"$ROOT"}" != "$FLAG_DIR" ] || [ "${FLAG_DIR#/}" != "$FLAG_DIR" ]; then
  chk "冷却标志不落在镜像默认 /app 下" ok
else
  chk "冷却标志不落在镜像默认 /app 下" fail "$FLAG_DIR"
fi
if [ "${LOCK_DIR#"$ROOT"}" != "$LOCK_DIR" ]; then
  chk "锁目录写在项目内" ok
else
  chk "锁目录写在项目内" fail "$LOCK_DIR"
fi

echo "[备份开关 backup_enabled]"
truth "四项未配 -> 假" 1 backup_enabled
GITHUB_TOKEN=a GITHUB_REPO_OWNER=b GITHUB_REPO_NAME=c ZIP_PASSWORD=d \
  truth "四项配齐 -> 真" 0 backup_enabled
GITHUB_TOKEN=a GITHUB_REPO_OWNER=b GITHUB_REPO_NAME=c \
  truth "缺任一项 -> 假" 1 backup_enabled

echo "[SQLite 兜底]"
v="$(WORK_DIR=/nope db_servers_count /nope 2>/dev/null)"
[ "$v" = "-1" ] && chk "db_servers_count 取不到 -> -1（而非 0，避免误判空库）" ok || chk "db_servers_count 取不到 -> -1" fail "got '$v'"
truth "db_integrity_ok 文件不存在 -> 假" 1 db_integrity_ok /nope/x.db
n="$(WORK_DIR="$ROOT/.contract" db_detect)"; [ -n "$n" ] && chk "db_detect 无库仍给兜底路径" ok || chk "db_detect 无库仍给兜底路径" fail "空"

echo "[手动备份触发词 is_manual_backup_trigger]"
truth "纯 backup -> 真" 0 is_manual_backup_trigger "backup"
truth "带空白/换行 -> 真" 0 is_manual_backup_trigger "$(printf '  backup  \n')"
truth "正文里提到 backup -> 假" 1 is_manual_backup_trigger "# 说明 backup 用法"
truth "README 正文含 backup -> 假" 1 is_manual_backup_trigger "# Nezha 备份库

手动触发：把本文件整体改为 backup
- \`data-2026-01-01-00-00-00.zip\`"

echo "[冷却时长 flag_arm / flag_arm_long / flag_tick]"
flag_clear
truth "无标志 -> 假（允许还原）" 1 flag_tick
RESTORE_COOLDOWN=6 flag_arm
n="$(RESTORE_COOLDOWN=6 count_locked)"
[ "$n" = "5" ] && chk "常规冷却拦下 5 个周期（=COOLDOWN-1）" ok || chk "常规冷却拦下 5 个周期" fail "n=$n"
truth "释放后 -> 假（允许还原）" 1 flag_tick
RESTORE_COOLDOWN=6 flag_arm_long
n="$(RESTORE_COOLDOWN=6 count_locked)"
[ "$n" = "17" ] && chk "长冷却拦下 17 个周期（=3x-1）—— 缺陷 b 的回归点" ok || chk "长冷却拦下 17 个周期" fail "n=$n"
flag_clear
[ -z "$(ls -A "$FLAG_DIR" 2>/dev/null)" ] && chk "flag_clear 后无残留" ok || chk "flag_clear 后无残留" fail "有残留"
RESTORE_COOLDOWN=1 flag_arm
n="$(RESTORE_COOLDOWN=1 count_locked)"
[ "$n" = "0" ] && chk "COOLDOWN=1 退化为当轮即放行（不出现负数死循环）" ok || chk "COOLDOWN=1 退化行为" fail "n=$n"

echo "[进程判活 svc_alive]"
truth "未知服务 -> 假" 1 svc_alive definitely_not_running_x
mkdir -p "$STATE_DIR"; printf '999999\n' > "$STATE_DIR/pid.xdead"
truth "pidfile 指向死进程 -> 假" 1 svc_alive xdead
rm -f "$STATE_DIR/pid.xdead"

echo "[全局锁 acquire_lock]"
rm -rf "$STATE_DIR/lock"
truth "首次获取 -> 真" 0 acquire_lock c1
p="$(bash -c "WORK_DIR='$WORK_DIR' WITH_LOCK_TIMEOUT=4 . '$ROOT/file/lib.sh'; acquire_lock c2 && echo got || echo busy")"
[ "$p" = "busy" ] && chk "他进程持锁 -> busy（跨进程互斥）" ok || chk "他进程持锁 -> busy" fail "got '$p'"
release_lock
[ ! -d "$STATE_DIR/lock" ] && chk "release_lock 清空锁目录" ok || chk "release_lock 清空锁目录" fail "仍在"
rm -rf "$STATE_DIR/lock"; mkdir -p "$STATE_DIR/lock"; printf '999999 dead\n' > "$STATE_DIR/lock/owner"
truth "owner 已死 -> 回收陈旧锁" 0 acquire_lock c3
release_lock
p="$(bash -c "WORK_DIR='$WORK_DIR' WITH_LOCK_TIMEOUT=4 . '$ROOT/file/lib.sh'; acquire_lock o && acquire_lock i && echo reentrant || echo not-reentrant")"
[ "$p" = "not-reentrant" ] && chk "锁不可重入（故禁止 with_lock 嵌套，见 start.sh:473-484）" ok || chk "锁不可重入" fail "got '$p'"

echo
echo "通过 $ok / 失败 $bad"
rm -rf "$ROOT/.contract"
[ "$bad" = 0 ] || exit 1
exit 0
