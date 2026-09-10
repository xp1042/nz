#!/usr/bin/env bash
# restore.sh — 从 GitHub 拉取备份并还原到 /app/data（含 resource 自定义主题）
#
# 本轮打进的变更：
#   6) 还原时机：支持 a（自动/判重）模式，可被 start.sh 主循环周期调用，实现运行期热还原；
#               成功后写 RESTORE_STATE（等价上游 dbfile），同名不再重复还原
#   7) 防抖    ：zip 校验 + 包内 sqlite 完整性校验 + 还原后二次校验，任一环失败自动回滚快照
#   快照治理：data.bak.* 仅保留 DATA_BAK_KEEP 份（原版每次重启无限累积，会撑爆 Koyeb 临时盘）
#
# 用法：restore.sh [a|f|list|<data-xxx.zip>]
#   a            自动：取 README 指向（或库中最新）的备份，与本地状态相同则跳过
#   f            强制：忽略本地状态，还原 README 指向的备份
#   list         交互式列表选择
#   <文件名>      还原指定备份
# 注：start.sh 内部一律显式传 a 或文件名，绝不走交互分支（容器无 tty）

set -u
cd "$(dirname "$0")" 2>/dev/null || true
if [ ! -f ./lib.sh ]; then echo "[FATAL] 缺少 lib.sh" >&2; exit 1; fi
. ./lib.sh
ensure_dirs

# 无参数 -> 交互选单（对齐上游 restore.sh 语义）；原版本地脚本被 start.sh 调用时总带参数
MODE="${1:-list}"

if ! backup_enabled; then
  info "未配置备份变量（GITHUB_TOKEN/GITHUB_REPO_OWNER/GITHUB_REPO_NAME/ZIP_PASSWORD），跳过还原"
  exit 0
fi

TEMP_DIR="/tmp/nezha-restore-$$"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR"

API_BASE="https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"

# -------------------------------------------------- 定位目标备份
README="$(gh_raw /README.md 2>/dev/null)"

if is_manual_backup_trigger "$README"; then
  info "README 内容是手动备份触发标记 'backup'，本次不还原"
  exit 0
fi

TARGET=""
case "$MODE" in
  a)
     TARGET="$(parse_backup_name "$README")"
     if [ -z "$TARGET" ]; then
       TARGET="$(list_remote_backups | head -n1)"
     fi
     case "$TARGET" in
       data-*.zip) ;;
       *) info "未找到可用备份，跳过还原"; exit 0 ;;
     esac
     LAST="$(cat "$RESTORE_STATE" 2>/dev/null)"
     if [ "$TARGET" = "$LAST" ]; then
       info "本地已同步至 $TARGET，无需还原"
       exit 0
     fi
     ;;
  f)
     TARGET="$(parse_backup_name "$README")"
     [ -n "$TARGET" ] || { err "README 未解析到备份文件名，无法强制还原"; exit 1; }
     ;;
  data-*.zip)
     TARGET="$MODE"
     ;;
  list|*)
     # 交互分支：无 tty 时绝不卡住（容器里被误调用的兜底）
     [ -t 0 ] || { err "非交互环境请指定模式：restore.sh a|f|<文件名>"; exit 1; }
     mapfile -t LIST < <(list_remote_backups)
     [ "${#LIST[@]}" -gt 0 ] || { warn "备份库里没有 data-*.zip"; exit 1; }
     for i in "${!LIST[@]}"; do printf ' %d. %s\n' "$((i+1))" "${LIST[$i]}"; done
     CH=""
     for _t in 1 2 3 4 5; do
       read -rp "选择要还原的备份 [1-${#LIST[@]}]: " CH || { err "读取输入失败"; exit 1; }
       case "$CH" in
         ''|*[!0-9]*) echo "  无效输入"; continue ;;
       esac
       [ "$CH" -ge 1 ] && [ "$CH" -le "${#LIST[@]}" ] && break
       echo "  超出范围"
     done
     case "$CH" in ''|*[!0-9]*) err "选择失败，退出"; exit 1 ;; esac
     TARGET="${LIST[$((CH-1))]}"
     ;;
esac

info "还原目标：$TARGET"

# -------------------------------------------------- 下载（走 Contents API raw，避开 CDN 缓存）
HTTP=$(curl -sL -m 300 -o "$TEMP_DIR/$TARGET" -w '%{http_code}' \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3.raw" \
        "$API_BASE/contents/$TARGET?ref=$GITHUB_BRANCH")
[ "$HTTP" = "200" ] || { warn "下载失败 HTTP $HTTP，保留现有数据"; exit 1; }
[ -s "$TEMP_DIR/$TARGET" ] || { warn "下载内容为空，保留现有数据"; exit 1; }
info "已下载 $TARGET ($(du -h "$TEMP_DIR/$TARGET" | cut -f1))"

# -------------------------------------------------- 7) 防抖第 1 层：包与密码校验
unzip -t -P "$ZIP_PASSWORD" "$TEMP_DIR/$TARGET" >/dev/null 2>&1 \
  || { err "zip 完整性/密码校验失败，拒绝还原"; exit 1; }
unzip -l -P "$ZIP_PASSWORD" "$TEMP_DIR/$TARGET" | grep -q 'data/' \
  || { err "包内没有 data/ 目录，包结构不对，拒绝还原"; exit 1; }

mkdir -p "$TEMP_DIR/x"
unzip -q -o -P "$ZIP_PASSWORD" "$TEMP_DIR/$TARGET" -d "$TEMP_DIR/x" \
  || { err "解压失败，拒绝还原"; exit 1; }

# 防抖第 2 层：包内数据库先自检，坏库直接放弃（文件名随版本变过，做一次探测）
NEW_DB=""
for cand in "$TEMP_DIR/x/data/sqlite.db" "$TEMP_DIR/x/data/db.sqlite"; do
  [ -s "$cand" ] && { NEW_DB="$cand"; break; }
done
if [ -z "$NEW_DB" ]; then
  NEW_DB="$(find "$TEMP_DIR/x/data" -maxdepth 1 -type f \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | head -n1)"
fi
if [ -n "$NEW_DB" ] && ! db_integrity_ok "$NEW_DB"; then
  err "备份包内的数据库已损坏（$NEW_DB），放弃还原"
  exit 1
fi

# -------------------------------------------------- 快照现有 data/
SNAP=""
if [ -d "$WORK_DIR/data" ] && [ -s "$(db_detect)" ]; then
  SNAP="${WORK_DIR}/data.bak.$(date +%s)"
  cp -a "$WORK_DIR/data" "$SNAP" 2>/dev/null || cp -R "$WORK_DIR/data" "$SNAP"
  info "现有数据快照：$SNAP"
  mapfile -t OLDS < <(ls -1d "$WORK_DIR"/data.bak.* 2>/dev/null | sort -r | tail -n +$((DATA_BAK_KEEP + 1)))
  if [ "${#OLDS[@]}" -gt 0 ]; then
    for o in "${OLDS[@]}"; do
      [ -n "$o" ] && [ -d "$o" ] && rm -rf "$o" && info "清理过期快照 $(basename "$o")"
    done
  fi
fi

rollback() {
  [ -n "$SNAP" ] || { err "无可回滚快照"; return 1; }
  err "回滚到快照 $SNAP"
  rm -rf "$WORK_DIR/data"
  cp -a "$SNAP" "$WORK_DIR/data" 2>/dev/null || cp -R "$SNAP" "$WORK_DIR/data"
  return 0
}

# -------------------------------------------------- 落盘
mkdir -p "$WORK_DIR/data"
# 先清掉现存的库文件（含不同命名的历史残留，如 sqlite.db 与 db.sqlite 并存），
# 否则还原后 db_detect 可能挑到残留的旧库。快照已在上面生成，可安全删。
find "$WORK_DIR/data" -maxdepth 1 -type f \
  \( -name '*.db' -o -name '*.sqlite' -o -name '*.db-wal' -o -name '*.db-shm' -o -name '*.sqlite-wal' -o -name '*.sqlite-shm' \) \
  -exec rm -f {} + 2>/dev/null || true

if ! cp -a "$TEMP_DIR/x/data/." "$WORK_DIR/data/" 2>/dev/null; then
  cp -R "$TEMP_DIR/x/data/." "$WORK_DIR/data/" || { err "写入 data/ 失败"; rollback; exit 1; }
fi

# resource 主题（对应 backup 新增项）；注意不要整体覆盖内置主题
if [ -d "$TEMP_DIR/x/resource" ]; then
  mkdir -p "$WORK_DIR/resource"
  cp -a "$TEMP_DIR/x/resource/." "$WORK_DIR/resource/" 2>/dev/null \
    || cp -R "$TEMP_DIR/x/resource/." "$WORK_DIR/resource/" 2>/dev/null \
    || warn "resource 主题还原失败（不影响面板启动）"
fi

# 防抖第 3 层：还原后再次自检，不过就回滚
LIVE_DB="$(db_detect)"
if [ -s "$LIVE_DB" ] && ! db_integrity_ok "$LIVE_DB"; then
  err "还原后数据库完整性检查失败"
  rollback || err "回滚也失败，请人工介入"
  exit 1
fi

# 备份带回的 config.yaml 里 token 可能是旧的 —— 由调用方 preseed_data/sync_agent_secret 复位。
# 这里不直接改，避免 restore.sh 单独运行时依赖 start.sh 的函数。
echo "$TARGET" > "$RESTORE_STATE"

info "还原完成：$TARGET"
CNT="$(db_servers_count)"
[ "$CNT" != "-1" ] && info "还原后节点数：$CNT"
ls -la "$WORK_DIR/data" 2>/dev/null | sed 1d
exit 0
