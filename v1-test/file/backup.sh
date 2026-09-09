#!/bin/bash
set -u

echo "========== Nezha 数据备份 =========="

# 必要变量检查（缺少只提示不中断）
if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPO_OWNER:-}" ] || [ -z "${GITHUB_REPO_NAME:-}" ] || [ -z "${ZIP_PASSWORD:-}" ]; then
    echo "[WARN] 缺少备份环境变量配置，跳过备份"
    echo "[WARN] 需要: GITHUB_TOKEN, GITHUB_REPO_OWNER, GITHUB_REPO_NAME, ZIP_PASSWORD"
    exit 0
fi

# ========== 保留最近备份个数 ==========
BACKUP_KEEP_COUNT="${BACKUP_KEEP_COUNT:-5}"

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
API_BASE="https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
WORK_DIR=/app
TEMP_DIR="/tmp/nezha-backup-$$"
TIMESTAMP=$(TZ='Asia/Shanghai' date +"%Y-%m-%d-%H-%M-%S")
BACKUP_FILE="data-${TIMESTAMP}.zip"

mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

echo "[INFO] 备份时间戳: $TIMESTAMP"
echo "[INFO] 备份文件名: $BACKUP_FILE"
echo "[INFO] 保留备份数量: $BACKUP_KEEP_COUNT"

# 检查数据目录
if [ ! -d "$WORK_DIR/data" ]; then
    echo "[WARN] 数据目录不存在: $WORK_DIR/data，跳过备份"
    exit 0
fi

# 复制数据
echo "[INFO] 复制数据..."
cp -R "$WORK_DIR/data" "$TEMP_DIR/data"

# 清理 SQLite 历史表（可选，减小备份大小）
if [ -f "$TEMP_DIR/data/sqlite.db" ]; then
    echo "[INFO] 清理 SQLite 历史数据..."
    sqlite3 "$TEMP_DIR/data/sqlite.db" "DELETE FROM service_histories; VACUUM;" 2>/dev/null || true
fi

# sqlite3 打开副本时已自动回放 WAL，包内不得残留 wal/shm，避免恢复端重放错乱
rm -f "$TEMP_DIR/data/sqlite.db-wal" "$TEMP_DIR/data/sqlite.db-shm" \
      "$TEMP_DIR/data/data.db-wal" "$TEMP_DIR/data/data.db-shm" \
      "$TEMP_DIR/data/sqlite.db-journal" "$TEMP_DIR/data/data.db-journal" 2>/dev/null || true

# 删除不需要备份的文件
rm -rf "$TEMP_DIR/data/upload" 2>/dev/null || true
rm -f "$TEMP_DIR/data/"*.log 2>/dev/null || true

# 压缩备份（使用密码加密）
echo "[INFO] 压缩数据（加密）..."
cd "$TEMP_DIR"
zip -r -6 -P "$ZIP_PASSWORD" "$BACKUP_FILE" data/ >/dev/null 2>&1

if [ ! -f "$BACKUP_FILE" ]; then
    echo "[WARN] 压缩失败"
    exit 0
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "[INFO] 备份文件大小: $BACKUP_SIZE"

# Base64 编码
base64 -w 0 "$BACKUP_FILE" > content.b64 2>/dev/null || base64 "$BACKUP_FILE" > content.b64

# 检查包大小限制
B64_SIZE=$(wc -c < content.b64)
if [ "$B64_SIZE" -gt 100000000 ]; then
    echo "[WARN] 文件太大（>100MB），无法上传到 GitHub"
    exit 0
fi

# 检查分支是否存在
echo "[INFO] 检查分支: $GITHUB_BRANCH"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "$API_BASE/branches/$GITHUB_BRANCH")

if [ "$HTTP_CODE" != "200" ]; then
    echo "[WARN] 分支不存在: $GITHUB_BRANCH"
    echo "[WARN] 请在 GitHub 仓库中创建该分支，或修改 GITHUB_BRANCH 变量"
    exit 0
fi

# 上传备份文件
echo "[INFO] 上传备份文件到 GitHub..."
EXISTING_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "$API_BASE/contents/$BACKUP_FILE?ref=$GITHUB_BRANCH" | jq -r '.sha // empty')

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
    echo "[WARN] 上传失败: $(echo "$RESPONSE" | jq -r '.message // "未知错误"')"
    exit 0
fi

# 更新 README.md
echo "[INFO] 更新 README.md..."

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

README_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "$API_BASE/contents/README.md?ref=$GITHUB_BRANCH" | jq -r '.sha // empty')

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

# 清理旧备份
echo "[INFO] 清理旧备份..."
OLD_BACKUPS=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "$API_BASE/contents?ref=$GITHUB_BRANCH" \
    | jq -r '.[].name' | grep '^data-.*\.zip$' | sort -r | tail -n +$((BACKUP_KEEP_COUNT + 1)))

if [ -n "$OLD_BACKUPS" ]; then
    for old_file in $OLD_BACKUPS; do
        echo "[INFO] 删除旧备份: $old_file"
        OLD_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "$API_BASE/contents/$old_file?ref=$GITHUB_BRANCH" | jq -r '.sha')
        
        curl -s -X DELETE \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"删除旧备份: $old_file\",\"sha\":\"$OLD_SHA\",\"branch\":\"$GITHUB_BRANCH\"}" \
            "$API_BASE/contents/$old_file" >/dev/null
    done
    echo "[SUCCESS] 旧备份清理完成 ✓"
else
    echo "[INFO] 没有需要清理的旧备份"
fi

echo "=========================================="
echo "[SUCCESS] 备份完成: $BACKUP_FILE 🎉"
echo "=========================================="
