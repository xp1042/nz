#!/usr/bin/env bash
# backup.sh — 备份 data/ + 自定义主题到 GitHub（Contents API + 加密 zip）
#
# 本轮打进的变更：
#   5) 备份范围：新增空库闸门（servers < MIN_SERVERS_FOR_BACKUP 直接跳过，可用 f 强推）
#               纳入 resource/*custom* 自定义主题（原版丢这项）
#               备份副本先自检完整性，坏库不上传
#   7) 防抖    ：全程持全局锁（由调用方 with_lock 保证）；备份完成布置还原冷却；
#               上传后回读 README 校验远端确已生效，未生效则加长冷却
#   兼容：README 首行写成裸文件名，供 start.sh 轮询解析（原版正文里的文件名解析不到）
#
# 用法：backup.sh [a|m|f]     a=定时  m=手动  f=强制（忽略空库闸门）

set -u
cd "$(dirname "$0")" 2>/dev/null || true
if [ ! -f ./lib.sh ]; then echo "[FATAL] 缺少 lib.sh" >&2; exit 1; fi
. ./lib.sh
ensure_dirs

WAY="${1:-m}"
case "$WAY" in
  a) MODE="Scheduled" ;;
  f) MODE="Forced" ;;
  *) MODE="Manualed" ;;
esac
FORCE=0; [ "$WAY" = "f" ] && FORCE=1

# -------------------------------------------------- 前置检查
if ! backup_enabled; then
  warn "备份变量不全，跳过备份"
  exit 0
fi

TEMP_DIR="/tmp/nezha-backup-$$"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/payload"
PAYLOAD="$TEMP_DIR/payload"

API_BASE="https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"

# -------------------------------------------------- 5) 空库闸门
# 上游 backup.sh 的 UUID_COUNT<2 检查：Koyeb 实例重建 -> 还原失败 -> 空库运行
# -> 到点备份 -> 把好备份挤出「最新」位，等于自毁。必须挡住。
DB="$(db_detect)"
CNT="$(db_servers_count "$DB")"
if [ "$CNT" = "-1" ]; then
  warn "读不到 $DB 的 servers 计数（缺库/缺表/缺 sqlite3），本次不备份"
  exit 0
fi
if [ "$CNT" -lt "$MIN_SERVERS_FOR_BACKUP" ] && [ "$FORCE" != 1 ]; then
  warn "面板仅 $CNT 个节点（阈值 $MIN_SERVERS_FOR_BACKUP），疑似空库/未完成还原 -> 跳过备份（强推用 backup.sh f）"
  exit 0
fi
info "节点数 $CNT，允许备份"

# -------------------------------------------------- 组织备份内容
[ -d "$WORK_DIR/data" ] || { warn "无 $WORK_DIR/data，跳过"; exit 0; }
cp -a "$WORK_DIR/data" "$PAYLOAD/data" 2>/dev/null || cp -R "$WORK_DIR/data" "$PAYLOAD/data"

SRC_DB="$(db_detect)"
DB_BASE="$(basename "$SRC_DB")"
PAY_DB="$PAYLOAD/data/$DB_BASE"

# 关键改进：数据库用 SQLite 在线备份 API 快照，而不是热拷文件。
# 面板一直在写库，直接 cp 有拍到撕裂页的风险（原版就是 cp -R）。
if command -v sqlite3 >/dev/null 2>&1 && [ -s "$SRC_DB" ]; then
  if sqlite3 "$SRC_DB" ".backup '$PAY_DB'" 2>/dev/null && [ -s "$PAY_DB" ]; then
    info "数据库已在线快照（.backup）：$DB_BASE"
  else
    warn "在线快照失败，退回文件拷贝结果"
  fi
fi

# 瘦身：上传目录与日志不进备份
rm -rf "$PAYLOAD/data/upload" 2>/dev/null || true
find "$PAYLOAD/data" -maxdepth 1 -type f -name '*.log' -exec rm -f {} + 2>/dev/null || true
# WAL/SHM 不进包：面板以 WAL 模式写库，只带走主库文件而丢掉 WAL 会缺数据，
# 因此必须先确认主库已含全部提交（.backup 的产物天然不含 WAL），再排除附属文件
for ext in wal shm db-wal db-shm journal; do
  find "$PAYLOAD/data" -maxdepth 1 -type f -name "*.$ext" -exec rm -f {} + 2>/dev/null || true
done

# 历史曲线清空以缩小包体（表名随版本不同，全部容错）
if command -v sqlite3 >/dev/null 2>&1 && [ -s "$PAY_DB" ]; then
  for tbl in service_histories avgs_daily_traffic_histories histories pods; do
    sqlite3 "$PAY_DB" "DELETE FROM $tbl;" 2>/dev/null || true
  done
  sqlite3 "$PAY_DB" "VACUUM;" 2>/dev/null || true
fi

# 副本完整性自检：宁可不备，也不上传坏库
if command -v sqlite3 >/dev/null 2>&1 && [ -s "$PAY_DB" ] && ! db_integrity_ok "$PAY_DB"; then
  err "备份副本数据库完整性检查失败，放弃本次备份"
  exit 1
fi

# 自定义主题（对齐上游 resource/*custom* 行为）
THEME_COUNT=0
if [ -d "$WORK_DIR/resource" ]; then
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    rel="${d#"$WORK_DIR"/}"
    mkdir -p "$PAYLOAD/$(dirname "$rel")"
    cp -a "$d" "$PAYLOAD/$rel" 2>/dev/null || cp -R "$d" "$PAYLOAD/$rel" 2>/dev/null || continue
    THEME_COUNT=$((THEME_COUNT + 1))
  done < <(find "$WORK_DIR/resource" -maxdepth 4 -type d -iname '*custom*' 2>/dev/null)
  [ "$THEME_COUNT" -gt 0 ] && info "纳入自定义主题 $THEME_COUNT 个目录"
fi

# -------------------------------------------------- 打包 + 加密 + 校验
TIMESTAMP="$(date +%Y-%m-%d-%H-%M-%S)"
BACKUP_FILE="data-${TIMESTAMP}.zip"
( cd "$PAYLOAD" && zip -r -6 -q -P "$ZIP_PASSWORD" "$TEMP_DIR/$BACKUP_FILE" . ) || { err "压缩失败"; exit 1; }
[ -s "$TEMP_DIR/$BACKUP_FILE" ] || { err "压缩包为空"; exit 1; }
unzip -t -P "$ZIP_PASSWORD" "$TEMP_DIR/$BACKUP_FILE" >/dev/null 2>&1 || { err "压缩包自检失败"; exit 1; }

BYTES=$(wc -c < "$TEMP_DIR/$BACKUP_FILE")
SIZE_H="$(du -h "$TEMP_DIR/$BACKUP_FILE" | cut -f1)"
LIMIT=$(( MAX_UPLOAD_MB * 1024 * 1024 ))
if [ "$BYTES" -gt "$LIMIT" ]; then
  err "备份 $SIZE_H 超出 MAX_UPLOAD_MB=$MAX_UPLOAD_MB，拒绝上传（GitHub Contents API 会直接报错）"
  exit 1
fi

B64="$TEMP_DIR/$BACKUP_FILE.b64"
base64 -w 0 "$TEMP_DIR/$BACKUP_FILE" > "$B64" 2>/dev/null || base64 "$TEMP_DIR/$BACKUP_FILE" > "$B64"
info "打包完成：$BACKUP_FILE ($SIZE_H)"

# -------------------------------------------------- 分支可用性
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -m 30 \
        -H "Authorization: token $GITHUB_TOKEN" \
        "$API_BASE/branches/$GITHUB_BRANCH")
if [ "$HTTP" != "200" ]; then
  err "分支 $GITHUB_BRANCH 不可用（HTTP $HTTP）。请先建分支或改 GITHUB_BRANCH"
  exit 1
fi

# -------------------------------------------------- 上传（PUT /contents）
put_file() {   # put_file <repo_path> <b64_file> <msg>  -> 0 成功
  local path="$1" b64f="$2" msg="$3" sha body resp
  sha="$(curl -s -m 30 -H "Authorization: token $GITHUB_TOKEN" \
            "$API_BASE/contents$path?ref=$GITHUB_BRANCH" | jq -r '.sha // empty')"
  if [ -n "$sha" ]; then
    body="$(jq -n --rawfile c "$b64f" --arg m "$msg" --arg s "$sha" --arg b "$GITHUB_BRANCH" \
             '{message:$m, content:$c, sha:$s, branch:$b}')"
  else
    body="$(jq -n --rawfile c "$b64f" --arg m "$msg" --arg b "$GITHUB_BRANCH" \
             '{message:$m, content:$c, branch:$b}')"
  fi
  resp="$(curl -s -m 180 -X PUT -H "Authorization: token $GITHUB_TOKEN" \
           -H 'Content-Type: application/json' -d "$body" "$API_BASE/contents$path")"
  if ! printf '%s' "$resp" | jq -e '.content.sha' >/dev/null 2>&1; then
    err "上传 $path 失败：$(printf '%s' "$resp" | jq -r '.message // "未知错误"')"
    return 1
  fi
  return 0
}

put_file "/$BACKUP_FILE" "$B64" "$MODE backup: $BACKUP_FILE ($SIZE_H, servers=$CNT)" || exit 1
info "已上传 $BACKUP_FILE"

# manifest：不带密码，便于外部核对
printf '%s\n' "$BACKUP_FILE" > "$TEMP_DIR/manifest"
printf 'built=%s\nsize=%s\nservers=%s\nthemes=%s\n' "$(ts)" "$SIZE_H" "$CNT" "$THEME_COUNT" >> "$TEMP_DIR/manifest"
base64 -w 0 "$TEMP_DIR/manifest" > "$TEMP_DIR/manifest.b64" 2>/dev/null || base64 "$TEMP_DIR/manifest" > "$TEMP_DIR/manifest.b64"
put_file "/manifest.txt" "$TEMP_DIR/manifest.b64" "manifest: $BACKUP_FILE" || warn "manifest 更新失败（不影响备份可用性）"

# -------------------------------------------------- README：首行必须是裸文件名
{
  printf '%s\n' "$BACKUP_FILE"
  printf '\n# Nezha 数据备份\n\n'
  printf -- '- 最新备份：`%s`\n' "$BACKUP_FILE"
  printf -- '- 备份时间：%s\n' "$(ts)"
  printf -- '- 包体大小：%s\n' "$SIZE_H"
  printf -- '- 节点数量：%s\n' "$CNT"
  printf -- '- 主题目录：%s\n' "$THEME_COUNT"
  printf -- '- 分支：`%s`\n' "$GITHUB_BRANCH"
  printf '\n## 操作方式\n\n'
  printf -- '- 手动触发备份：把本文件内容整体改为 `backup`（下个检查周期生效，随后会被重写回来）\n'
  printf -- '- 指定还原目标：把本文件**首行**改为某个 `data-....zip` 文件名\n'
  printf '\n## 环境变量\n\n'
  printf -- '`GITHUB_REPO_OWNER` `GITHUB_REPO_NAME` `GITHUB_TOKEN` `GITHUB_BRANCH` `ZIP_PASSWORD` `BACKUP_KEEP_COUNT` `MAX_UPLOAD_MB`\n'
} > "$TEMP_DIR/readme"
base64 -w 0 "$TEMP_DIR/readme" > "$TEMP_DIR/readme.b64" 2>/dev/null || base64 "$TEMP_DIR/readme" > "$TEMP_DIR/readme.b64"

put_file "/README.md" "$TEMP_DIR/readme.b64" "readme -> $BACKUP_FILE" \
  || warn "README 更新失败：备份文件已在库中，请手动把 README 首行改为 $BACKUP_FILE"

# -------------------------------------------------- 7) 防抖：远端回读校验 + 冷却
APPLIED=""
for _i in 1 2 3 4; do
  sleep 5
  APPLIED="$(gh_raw /README.md 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [ "$APPLIED" = "$BACKUP_FILE" ] && break
  warn "回读 README 得到 '${APPLIED:-空}'，期望 '$BACKUP_FILE'（重试 $_i/4）"
done

if [ "$APPLIED" = "$BACKUP_FILE" ]; then
  # 关键：本地数据此刻**就是**这个包，必须登记为"已生效"。
  # 否则冷却期满后 periodic_restore 会拿 README 指向的新包名与本地记录的旧包名比出"不同"，
  # 于是把自己刚推上去的备份再原样还原回来，白白触发一次全量重启
  # （2026-09-10 线上实测：每次备份后约 5 分钟必现 21:53 备份 -> 21:58 自还原+重启）。
  printf '%s\n' "$BACKUP_FILE" > "$RESTORE_STATE"
  flag_arm                                   # 正常冷却：期间不还原
else
  # 远端未确认 -> 不登记状态，宁可三倍长冷却后再由轮询判定
  flag_arm_long                              # 远端未确认：三倍冷却，绝不误还原旧包
fi
echo "$(date +%Y-%m-%d)" > "$BACKUP_STATE"

# -------------------------------------------------- 清理旧备份（保留 BACKUP_KEEP_COUNT 份）
mapfile -t ALL < <(list_remote_backups)
if [ "${#ALL[@]}" -gt "$BACKUP_KEEP_COUNT" ]; then
  for old in "${ALL[@]:$BACKUP_KEEP_COUNT}"; do
    [ -n "$old" ] || continue
    osha="$(curl -s -m 30 -H "Authorization: token $GITHUB_TOKEN" \
              "$API_BASE/contents/$old?ref=$GITHUB_BRANCH" | jq -r '.sha // empty')"
    [ -z "$osha" ] && continue
    curl -s -m 30 -X DELETE -H "Authorization: token $GITHUB_TOKEN" \
      -H 'Content-Type: application/json' \
      -d "{\"message\":\"prune $old\",\"sha\":\"$osha\",\"branch\":\"$GITHUB_BRANCH\"}" \
      "$API_BASE/contents/$old" >/dev/null
    info "清理旧备份 $old"
  done
fi

info "备份完成：$BACKUP_FILE ($SIZE_H) | 保留 $BACKUP_KEEP_COUNT 份 | 当前冷却 $RESTORE_COOLDOWN 周期"
exit 0
