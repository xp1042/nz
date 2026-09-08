# ⭐ Star 万万岁 ⭐ 一键哪吒面板 🚀

## 在 Hugging Face 部署哪吒面板 **V2** 版（带自动备份功能）

> **请注意**：本版本已适配哪吒面板 **V2**（面板与 Agent 均为 V2），并**移除了原版的第三方"访问保活"上报**——本镜像不会向任何第三方发送你的面板地址。
> 若需自行保活，可使用你自己的 UptimeRobot 等外部监控服务直接监控面板地址即可。

---

## 📋 部署参数说明

| 变量名             | 示例值                                       | 必需 | 说明 |
| ------------------ | -------------------------------------------- | ---- | ---- |
| `ARGO_AUTH`        | `eyJhIjoi....`                               | ✔️   | Argo Tunnel Token，从 [Cloudflare Tunnels](https://one.dash.cloudflare.com/) 获取 |
| `ARGO_DOMAIN`      | `nezha.com`                                  | ✔️   | 面板访问域名，会同时用于内嵌 Agent 上报 |
| `GITHUB_TOKEN`     | `ghp_xxxxxxxx`                               | ✔️   | GitHub Token，用于自动备份到 GitHub 私库 |
| `GITHUB_REPO_OWNER`| `your_username`                              | ✔️   | 存储备份的 GitHub 用户名 |
| `GITHUB_REPO_NAME` | `nezha-backup`                               | ✔️   | 备份仓库名称（建议建私库） |
| `GITHUB_BRANCH`    | `main`                                       | ✔️   | 备份仓库使用的分支 |
| `ZIP_PASSWORD`     | `147369`                                     | ✔️   | 备份压缩包加密口令 |
| `NZ_UUID`          | `f8ff434***********62e0`                     | ✔️   | 在面板"管理后台 → 服务器"里添加服务器后获得的 Agent UUID |
| `NZ_CLIENT_SECRET` | `kDerKiY***********mvj0XMy`                  | ❌   | 从面板"管理后台 → 管理设置"里的 `agentsecretkey` 复制；不填则首次启动自动生成 |
| `NZ_TLS`           | `true`                                       | ❌   | 是否使用 TLS，默认 `true` |
| `DASHBOARD_VERSION`| `v2.3.8`                                     | ❌   | 面板版本，默认 `latest`（官方最新 **V2** 版） |
| `BACKUP_HOUR`      | `4`                                          | ❌   | 每日自动备份的时间（小时，容器时区 Asia/Shanghai），默认凌晨 4 点 |

### 与原 V1 版的差异

- 面板默认安装官方最新 **V2** 版（`DASHBOARD_VERSION` 可指定任意 `v2.x` 版本）；
- 内嵌 Agent 优先加载 **V2 agent** 动态库（`agent-<arch>.so`），不兼容时自动回退 V1（`v1-<arch>.so`）；
- 生成的面板配置已清理 V2 中废弃的 `max_agent_conn` / `grpc_*` 等键；
- 旧版（V1）备份恢复时自动迁移配置（删除废弃键，数据文件结构 V1/V2 通用）；
- **移除**了部署时向 `oyz8.ct8.pl` 第三方上报面板地址的行为（隐私考虑）。

---

## 🚀 快速部署

### 1. Fork 仓库后启用 Actions

Fork 本仓库 → **Actions** → 启用工作流。

### 2. 构建自己的 Docker 镜像

1. 进入 **Actions** → 选择 **🐳 构建最新的镜像并上传**；
2. **Run workflow**（镜像名随意，如 `nz`，标签默认 `latest`）；
3. 等待构建完成（3–10 分钟），镜像地址：
   `ghcr.io/<你的用户名>/<镜像名>:latest`

### 3. 创建 Cloudflare Tunnel

1. 登录 [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → **Networks → Tunnels**；
2. **Create a tunnel** → 选择 Cloudflared → 命名（如 `nezha`）→ 保存；
3. 复制 **Token**（即 `ARGO_AUTH`）；
4. **Public Hostname** 里把你的域名指向 `http://localhost:8008`。

### 4. 准备备份私库与 Token

见下方"🧭 一步一步照着做教程"，创建私库（如 `nezha-backup`）与 GitHub Token。

### 5. 部署 Hugging Face Space

1. 新建 Space → 选择 **Docker** 类型；
2. 在 **Settings → Variables and secrets** 中添加上表中的变量（`ARGO_AUTH`、`GITHUB_TOKEN` 等建议用 **Secret**）；
3. Space 的 README 中指定镜像：

```yaml
---
title: Nz V2
emoji: 🚀
colorFrom: gray
colorTo: gray
sdk: docker
app_port: 7860
---
```

4. 等待构建完成，访问 `https://<你的域名>` 进入面板。

### 6. 获取 NZ_UUID / NZ_CLIENT_SECRET

- 打开面板 → **管理后台**；
- 默认账号密码为 `admin` / `admin`（首次登录后请立即修改！）；
- **管理后台 → 服务器 → 添加服务器**，得到的 `UUID` 填入 `NZ_UUID`；
- **管理后台 → 系统设置** 中的 `Agentsecretkey` 即 `NZ_CLIENT_SECRET`（不填则首次启动自动生成，可在配置文件中查看）。

---

## 💾 数据自动备份

- 每天定时自动把 `/dashboard/data`（数据库、主题等）加密压缩上传到你的 GitHub 私库；
- 每次重启容器时自动恢复最新备份；
- 手动触发：修改备份私库的 `README.md`，内容仅写 `backup`，一分钟后会触发备份并自动清空该文件；
- 保留最近 `KEEP_BACKUPS`（默认 5）份备份，旧的自动删除。

---

## ⚠️ 注意

* 面板版本可在部署时通过 `DASHBOARD_VERSION` 指定（默认 latest，即官方最新 **V2** 版）；
* 部署成功后请**立即修改默认管理员密码**；
* 本镜像不含任何第三方数据上报，`PROJECT_URL` 变量已废弃，无需设置。

---

## 📮 Telegram 通知（可选）

在面板 **管理后台 → 报警 → 通知方式** 中新建：

- **URL**：`https://api.telegram.org/bot<你的BOT_TOKEN>/sendMessage`
- **请求方式**: POST
- **请求类型**: JSON
- **Body**:

```json
{
    "chat_id": "123456789",
    "text": "🟢 *哪吒监控告警*\n\n*规则*: *#RULENAME#\n\n*服务器*: *#SERVER.NAME# #NEZHA#\n\n*时间*: #DATETIME#",
    "parse_mode": "Markdown",
    "reply_markup": {
        "inline_keyboard": [
            [
                {
                    "text": " 管理面板入口",
                    "url": "https://nezha.com"
                }
            ]
        ]
    }
}
```

- **确认**: 请求体检查 TLS

---

### *更多搭建教程！* 🎉
