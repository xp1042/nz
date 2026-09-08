#!/bin/bash
# scripts/backup.sh - Nezha 数据备份脚本
set -u

###########################################
# Nezha 备份脚本
###########################################

# 必要变量检查
if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPO_OWNER:-}" ] || [ -z "${GITHUB_REPO_NAME:-}" ]; then
    echo "[WARN] 缺少 GITHUB_TOKEN 或 GITHUB_REPO，跳过备份"
    exit 0
fi

if [ -z "${ZIP_PASSWORD:-}" ]; then
    echo "[WARN] 缺少 ZIP_PASSWORD，跳过备份"
    exit 0
fi

# 配置
DATA_DIR="${DATA_DIR:-/dashboard/data}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
API_BASE="https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
TIMESTAMP=$(TZ='Asia/Shanghai' date +"%Y-%m-%d-%H-%M-%S")
BACKUP_FILE="data-${TIMESTAMP}.zip"

echo "=========================================="
echo " Nezha 数据备份"
echo "=========================================="
echo "[INFO] 开始备份: $BACKUP_FILE"
echo "[INFO] 数据目录: $DATA_DIR"

# 检查数据目录
if [ ! -d "$DATA_DIR" ]; then
    echo "[ERROR] 数据目录不存在: $DATA_DIR"
    exit 1
fi

# 临时目录
TEMP_DIR="/tmp/nezha-backup-$$"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR" || exit 1

# 清理函数
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# 复制数据
echo "[INFO] 复制数据..."
cp -R "$DATA_DIR" "$TEMP_DIR/data"

# 清理 SQLite 历史表（可选，减小备份大小）
if [ -f "$TEMP_DIR/data/sqlite.db" ]; then
    echo "[INFO] 清理 SQLite 历史数据..."
    sqlite3 "$TEMP_DIR/data/sqlite.db" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
    sqlite3 "$TEMP_DIR/data/sqlite.db" "DELETE FROM service_histories; VACUUM;" 2>/dev/null || true
fi

# 删除不需要备份的文件
rm -rf "$TEMP_DIR/data/upload" 2>/dev/null || true
rm -f "$TEMP_DIR/data/*.log" 2>/dev/null || true
rm -f "$TEMP_DIR/data/*.yaml" 2>/dev/null || true  # 探针配置文件不需要备份

# 压缩备份（使用密码加密）
echo "[INFO] 压缩数据（加密）..."
zip -r -6 -P "$ZIP_PASSWORD" "$BACKUP_FILE" data/ >/dev/null 2>&1

if [ ! -f "$BACKUP_FILE" ]; then
    echo "[ERROR] 压缩失败"
    exit 1
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "[INFO] 备份文件大小: $BACKUP_SIZE"

# Base64 编码
base64 -w 0 "$BACKUP_FILE" > content.b64 2>/dev/null || base64 "$BACKUP_FILE" > content.b64

# 检查大小限制
B64_SIZE=$(wc -c < content.b64)
echo "[INFO] Base64 大小: $((B64_SIZE / 1024 / 1024))MB"

if [ "$B64_SIZE" -gt 100000000 ]; then
    echo "[ERROR] 文件太大（>100MB），无法上传到 GitHub"
    exit 1
fi

# 1. 上传备份文件
echo "[INFO] 上传备份文件..."
EXISTING_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "$API_BASE/contents/$BACKUP_FILE?ref=$GITHUB_BRANCH" 2>/dev/null | jq -r '.sha // empty')

if [ -n "$EXISTING_SHA" ]; then
    jq -n --rawfile content content.b64 \
        --arg msg "更新备份: $BACKUP_FILE" \
        --arg sha "$EXISTING_SHA" \
        --arg branch "$GITHUB_BRANCH" \
        '{message: $msg, content: $content, sha: $sha, branch: $branch}' > payload.json
else
    jq -n --rawfile content content.b64 \
        --arg msg "备份: $BACKUP_FILE ($BACKUP_SIZE)" \
        --arg branch "$GITHUB_BRANCH" \
        '{message: $msg, content: $content, branch: $branch}' > payload.json
fi

RESPONSE=$(curl -s -X PUT \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -d @payload.json \
    "$API_BASE/contents/$BACKUP_FILE")

rm -f payload.json content.b64

if echo "$RESPONSE" | jq -e '.content.sha' >/dev/null 2>&1; then
    echo "[SUCCESS] 备份文件已上传 ✓"
else
    echo "[ERROR] 上传失败: $(echo "$RESPONSE" | jq -r '.message // "未知错误"')"
    exit 1
fi

# 2. 更新 README.md
echo "[INFO] 更新 README.md..."
README_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "$API_BASE/contents/README.md?ref=$GITHUB_BRANCH" | jq -r '.sha // empty')

README_TEXT="# Nezha 数据备份

## 最新备份信息
- **文件名**: \`$BACKUP_FILE\`
- **备份时间**: $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
- **文件大小**: $BACKUP_SIZE

## 恢复说明
设置环境变量后容器会自动恢复最新备份。

## 手动触发备份
将此文件内容修改为 \`backup\` 即可触发手动备份。

## 环境变量
- \`GITHUB_REPO_OWNER\`: GitHub 用户名
- \`GITHUB_REPO_NAME\`: GitHub 仓库名称
- \`GITHUB_TOKEN\`: GitHub Token
- \`GITHUB_BRANCH\`: GitHub 备份分支
- \`ZIP_PASSWORD\`: 备份密码
"

README_B64=$(echo -n "$README_TEXT" | base64 -w 0 2>/dev/null || echo -n "$README_TEXT" | base64)

if [ -n "$README_SHA" ]; then
    jq -n --arg msg "更新README: $BACKUP_FILE" \
        --arg content "$README_B64" \
        --arg sha "$README_SHA" \
        --arg branch "$GITHUB_BRANCH" \
        '{message: $msg, content: $content, sha: $sha, branch: $branch}' > readme.json
else
    jq -n --arg msg "创建README" \
        --arg content "$README_B64" \
        --arg branch "$GITHUB_BRANCH" \
        '{message: $msg, content: $content, branch: $branch}' > readme.json
fi

curl -s -X PUT \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -d @readme.json \
    "$API_BASE/contents/README.md" >/dev/null

rm -f readme.json
echo "[SUCCESS] README.md 已更新 ✓"

# 3. 删除旧备份（仅在当前分支）
echo "[INFO] 清理旧备份（保留 ${KEEP_BACKUPS} 个）..."
OLD_BACKUPS=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "$API_BASE/contents?ref=$GITHUB_BRANCH" \
    | jq -r '.[].name' | grep '^data-.*\.zip$' | sort -r | tail -n +$((KEEP_BACKUPS + 1)))

if [ -n "$OLD_BACKUPS" ]; then
    for old_file in $OLD_BACKUPS; do
        echo "[INFO] 删除: $old_file"
        OLD_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "$API_BASE/contents/$old_file?ref=$GITHUB_BRANCH" | jq -r '.sha')
        
        curl -s -X DELETE \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"删除旧备份: $old_file\",\"sha\":\"$OLD_SHA\",\"branch\":\"$GITHUB_BRANCH\"}" \
            "$API_BASE/contents/$old_file" >/dev/null
    done
else
    echo "[INFO] 没有需要清理的旧备份"
fi

echo "=========================================="
echo "[SUCCESS] 备份完成: $BACKUP_FILE 🎉"
echo "=========================================="
