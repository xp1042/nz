#!/bin/bash
set -u

echo "========== Nezha 数据恢复 =========="

# 必要变量检查
if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPO_OWNER:-}" ] || [ -z "${GITHUB_REPO_NAME:-}" ] || [ -z "${ZIP_PASSWORD:-}" ]; then
    echo "[INFO] 未配置备份恢复变量，跳过恢复"
    exit 0
fi

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
API_BASE="https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
WORK_DIR=/app
TEMP_DIR="/tmp/nezha-restore-$$"
TMP_FILE="$TEMP_DIR/backup.zip"

mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

# 检查分支是否存在
echo "[INFO] 检查分支: $GITHUB_BRANCH"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "$API_BASE/branches/$GITHUB_BRANCH")

if [ "$HTTP_CODE" != "200" ]; then
    echo "[INFO] 分支不存在: $GITHUB_BRANCH，跳过恢复"
    exit 0
fi

# 获取 README 内容
echo "[INFO] 获取备份信息..."
README_CONTENT=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3.raw" \
    "$API_BASE/contents/README.md?ref=$GITHUB_BRANCH" 2>/dev/null)

# 如果是手动触发标记，直接跳过
if [ "$README_CONTENT" = "backup" ]; then
    echo "[INFO] README 内容为手动触发标记，跳过恢复"
    exit 0
fi

# 尝试从 README 中提取备份文件名
BACKUP_FILE=""
if [ -n "$README_CONTENT" ]; then
    BACKUP_FILE=$(echo "$README_CONTENT" | grep -oE 'data-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.zip' | head -n1)
fi

# 如果 README 中没有，或 README 为空/不存在，则从文件列表获取最新备份
if [ -z "$BACKUP_FILE" ]; then
    echo "[INFO] 从文件列表获取最新备份..."
    BACKUP_FILE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "$API_BASE/contents?ref=$GITHUB_BRANCH" \
        | jq -r '.[].name' | grep '^data-.*\.zip$' | sort -r | head -n1)
fi

if [ -z "$BACKUP_FILE" ]; then
    echo "[INFO] 未找到备份文件，跳过恢复"
    exit 0
fi

echo "[INFO] 恢复文件: $BACKUP_FILE"

# 下载备份文件
echo "[INFO] 下载备份文件..."
HTTP_CODE=$(curl -L -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3.raw" \
    -o "$TMP_FILE" \
    "$API_BASE/contents/$BACKUP_FILE?ref=$GITHUB_BRANCH")

if [ "$HTTP_CODE" != "200" ]; then
    echo "[INFO] 下载失败 (HTTP $HTTP_CODE)，跳过恢复"
    exit 0
fi

if [ ! -s "$TMP_FILE" ]; then
    echo "[INFO] 下载的文件为空，跳过恢复"
    exit 0
fi

echo "[INFO] 文件大小: $(du -h "$TMP_FILE" | cut -f1)"

# 验证 zip 文件
echo "[INFO] 验证备份文件..."
if ! unzip -t -P "$ZIP_PASSWORD" "$TMP_FILE" >/dev/null 2>&1; then
    echo "[INFO] 备份文件损坏或密码错误，跳过恢复"
    exit 0
fi

# 检查解压内容
echo "[INFO] 检查备份内容..."
unzip -l -P "$ZIP_PASSWORD" "$TMP_FILE" | grep -q "data/" || {
    echo "[INFO] 备份文件中无 data 目录，跳过恢复"
    exit 0
}

# 备份现有数据（如果存在）
if [ -d "$WORK_DIR/data" ] && [ -f "$WORK_DIR/data/sqlite.db" ]; then
    BACKUP_EXISTING="${WORK_DIR}/data.bak.$(date +%s)"
    echo "[INFO] 备份现有数据到: $BACKUP_EXISTING"
    cp -R "$WORK_DIR/data" "$BACKUP_EXISTING"
fi

# 解压恢复
echo "[INFO] 恢复数据..."
if ! unzip -P "$ZIP_PASSWORD" -o "$TMP_FILE" -d "$WORK_DIR" >/dev/null 2>&1; then
    echo "[INFO] 解压失败，跳过恢复"
    exit 0
fi

if [ ! -d "$WORK_DIR/data" ]; then
    echo "[INFO] 恢复后未找到 data 目录"
    exit 0
fi

echo "=========================================="
echo "[SUCCESS] 恢复完成 🎉"
echo "=========================================="
echo "[INFO] 恢复的文件:"
ls -la "$WORK_DIR/data"
