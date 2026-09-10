### V1 版哪吒面板（Koyeb 版）**补丁版**

自动备份 / 可选版本 / 可选择是否更新 —— 在原 `koyeb.zip` 基础上，一次性打进上游
`Docker-for-Nezha-Argo-server-v1.x` 的 7 项机制，并修掉原版几处会静默失效的逻辑。

> **安装好第一件事，必须进面板改密码。**

---

## 一、本次打进的 7 项

| # | 能力 | 上游做法 | 原版 koyeb.zip | 本补丁版做法 | 落点 |
|---|---|---|---|---|---|
| 1 | 预置数据 | 仓库内置 `sqlite.db` + `init.sh` 写 token | 无，全交面板首启生成 | 可选 `SEED_DB_URL` 导入、坏库自动隔离、预置 `config.yaml` 模板、`agent_secret_key` 恒按 env 复位 | `start.sh: preseed_data / sync_agent_secret` |
| 2 | 进程守护 | supervisord 4~6 个 program + 数量比对 | `nohup &`，崩了不管 | 每周期 pidfile + HTTP **双判活**，异常自动拉起，崩溃指数退避（5→120s 封顶） | `lib.sh: svc_*` / `start.sh: supervise` |
| 3 | 监听端口 | `PRO_PORT=${PORT:-80}` | **硬编码 `listen 80`**（忽略 `$PORT`） | nginx 的 `listen`、面板探活 URL、隧道回源端口全部参数化，另有 `HTTPS_PORT`、`DASH_PORT` 可调 | `lib.sh: *_PORT` / `start.sh: create_nginx_config` |
| 4 | 本机探针 | 内置，token 随机并回写 DB | 仅可选，且必须绕 CF 回连 | `NZ_TARGET=local` 可走 `127.0.0.1:8008` 直连（隧道故障也显示在线），默认仍 `tunnel` | `start.sh: write_agent_config` |
| 5 | 备份范围 | `data/` + `resource/*custom*`，含空库闸门 | 仅 `data/`，**无空库闸门** | 两者合并：空库闸门 `MIN_SERVERS_FOR_BACKUP` + 主题备份 + WAL/日志/upload 排除 + 副本自检 | `backup.sh` |
| 6 | 还原时机 | 每分钟 cron 轮询热还原 | 仅开机一次 | 开机还原 + 每 `CHECK_INTERVAL` 轮询热还原，`RESTORE_STATE` 判重（等价上游 `dbfile`） | `start.sh: periodic_restore` |
| 7 | 防抖 | `/tmp/flag` 计数自锁 9 分钟 | 无 | 全局 `mkdir` 操作锁（互斥 backup/restore/renew）+ 备份后还原冷却 `RESTORE_COOLDOWN` 周期 + 上传后**远端回读校验**，未确认则 3 倍长冷却 | `lib.sh: *_lock / flag_*` |

---

## 二、环境变量

### 硬必填

| 变量 | 说明 |
|---|---|
| `NZ_CLIENT_SECRET` | 面板 `agent_secret_key`，也是探针 token。**它说了算**：还原带回旧值会被强制改写 |

缺失即 `check_env` 直接退出容器。其余全部可选。

### 用隧道 / 接探针时必填

| 变量 | 说明 | 不填的后果 |
|---|---|---|
| `ARGO_AUTH` | Cloudflare Tunnel Token（本版仍**仅支持 Token**，不支持 TunnelSecret JSON） | 只 `warn`，不启 cloudflared，面板退化为仅靠 `$PORT` 直连 |
| `ARGO_DOMAIN` | 面板域名 | 自签证书 CN 退化为 `localhost`；`NZ_TARGET=tunnel` 时探针无法回连 |
| `NZ_UUID` | 探针 UUID | 不下载、不启动 `nezha-agent`，面板无本机节点 |

### 备份（四个都不填 = 备份与热还原整体关闭）

| 变量 | 默认 | 说明 |
|---|---|---|
| `GITHUB_REPO_OWNER` / `GITHUB_REPO_NAME` | — | 备份仓库（须 private） |
| `GITHUB_TOKEN` | — | 有 `Contents: Read/Write` 权限 |
| `ZIP_PASSWORD` | — | zip 加密口令 |
| `GITHUB_BRANCH` | `main` | 分支必须**已存在**（不存在时备份直接报错退出，不会自动建） |
| `BACKUP_KEEP_COUNT` | `5` | 远端保留份数（只清 `data-*.zip`，`README.md` 与 `manifest.txt` 不删） |
| `MAX_UPLOAD_MB` | `90` | 超过直接拒传，避免 API 报错 |

### 调度与守护（本次新增）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `80` | 由 PaaS 注入，**本版真正生效**（`HTTP_PORT` 的别名，也可直接设 `HTTP_PORT`） |
| `HTTPS_PORT` | `443` | 隧道回源 TLS 端口 |
| `DASH_PORT` | `8008` | 面板内部端口（web + gRPC 同端口复用） |
| `CHECK_INTERVAL` | `60` | 主循环秒数：守护 + 热还原探测共用 |
| `BACKUP_HOUR` | `4` | 每日自动备份小时，同时也是版本自更新的启动小时（`TZ`，默认 Asia/Shanghai） |
| `RESTORE_COOLDOWN` | `6` | 备份后跳过还原的周期数（默认 ≈6 分钟） |
| `MIN_SERVERS_FOR_BACKUP` | `2` | 节点数低于此值判为空库，拒绝备份 |
| `DATA_BAK_KEEP` | `3` | 本地 `data.bak.*` 快照保留份数（原版无限累积） |
| `WITH_LOCK_TIMEOUT` | `120` | 抢全局操作锁的最长等待秒数，超时跳过本次任务 |
| `NO_RES` | — | 设 `1` 关闭运行期热还原（只保留开机还原） |
| `NO_AUTO_RENEW` | — | 设 `1` 关闭版本自更新 |
| `SKIP_BOOT_RESTORE` | — | 设 `1` 跳过开机还原（首次全新部署时有用） |
| `PRESET_CONFIG` | `true` | 设 `false` 则不生成 `config.yaml`，全交面板自建 |
| `SEED_DB_URL` | — | 预置数据库直链（对齐上游内置 `sqlite.db` 的能力） |
| `SITE_NAME` | `Nezha` | 预置 config 的站点名 |
| `GH_CLIENTID` / `GH_CLIENTSECRET` | — | 填了则在预置 config 里写入 GitHub OAuth2 段 |

### 探针

| 变量 | 默认 | 说明 |
|---|---|---|
| `NZ_UUID` | — | 探针 UUID，不填则不装探针 |
| `NZ_TARGET` | `tunnel` | `tunnel`=经 CF 回连（原版行为）；`local`=`127.0.0.1:$DASH_PORT` 直连并自动 `tls:false` |
| `NZ_TLS` | `true` | 仅 `tunnel` 模式有意义 |
| `DASHBOARD_VERSION` | 空 | 留空才允许自更新（pin 了版本就完全不碰） |
| `Force_Auth` | `false` | 写入 `config.yaml` 的 `force_auth` |

### 路径覆盖（本机调试 / 非 root 镜像用）

`WORK_DIR`（`/app`）、`LOG_DIR`、`STATE_DIR`、`FLAG_DIR`、`NGINX_PREFIX`（`/etc/nginx`）、`NGINX_CONF_DIR`、`NGINX_MAIN_CONF`、`TZ`。
生产环境不要动。

---

## 三、备份 / 还原操作

**README 格式已改成机器可读**：首行是裸文件名 `data-....zip`，人类说明在其后。

- **手动备份**：把备份库 `README.md` 内容整体改成 `backup` → 下个周期（≤`CHECK_INTERVAL` 秒）触发，随后被脚本写回。
- **热回滚 / 指定还原**：把 `README.md` **首行**改成库里某个 `data-2025-...zip` 文件名 → 容器自动下载、校验、还原、重启服务。
- **手动命令行**：
  ```bash
  ./backup.sh              # 默认 m（手动）；a = 定时语义；f = 忽略空库闸门强推
  ./restore.sh             # 无参数 = 交互选单（需 tty；无 tty 会直接报错退出，不会卡住）
  ./restore.sh a           # 自动：与 .state/restored.last 相同则跳过
  ./restore.sh f           # 强制还原 README 指向的备份
  ./restore.sh data-2025-01-02-03-04-05.zip   # 还原指定文件（热回滚用）
  ./restart.sh all|dashboard|agent|nginx|cloudflared
  ./start.sh self-test     # 纯 shell 自检，不联网
  PORT=8080 ./start.sh render-nginx   # 只看 nginx 配置渲染结果（验证 $PORT 是否生效）
  ```

### 防抖时序（为什么不会自己踩自己）

```
备份成功 → 回读 README 校验 → 布置冷却标志(N) → 冷却期内轮询一律跳过还原
                                                    ↓ N 到 RESTORE_COOLDOWN
                                              自动释放，恢复热还原
任一环失败 → 三倍长冷却，宁可不动也不误动
还原前：zip 完整性+密码校验 → 包内 DB 自检 → 落盘 → 落盘后再自检 → 不过则回滚快照
```

`backup` / `restore` / `renew` 三者互斥（`mkdir` 原子锁，owner 进程死亡自动回收陈旧锁）。

---

## 四、目录结构

容器内 `/app`（`WORK_DIR`）：

```
/app/
|-- lib.sh                     # 公共库（新增）：锁 / 冷却标志 / 判活 / GitHub / SQLite 封装
|-- start.sh                   # 入口 + 预置 + 守护 + 调度
|-- backup.sh  restore.sh  renew.sh  restart.sh
|
|-- data/
|   |-- config.yaml            # 预置或面板自建；agent_secret_key 每周期按 env 复位
|   `-- sqlite.db              # 面板库；损坏会被改名为 *.corrupt.<epoch> 后重建
|
|-- agent-config.yml           # 探针配置（由 env 生成，故意放在 data/ 外，不进备份也不被还原覆盖）
|-- nezha.key / nezha.csr / nezha.pem    # 隧道回源用的自签证书（已存在则复用，不每次重生成）
|-- dashboard-linux-amd64[.prev]          # .prev 由 renew.sh 换二进制时留下的回滚件
|-- nezha-agent
|-- cloudflared-linux-amd64
|-- data.bak.<epoch>           # 还原前快照，最多 DATA_BAK_KEEP 份
|
|-- logs/                      # main.log + nginx/dashboard/agent/cloudflared 各自日志
`-- .state/                    # 运行期状态（不进备份）
    |-- pid.<key>              # 四进程 pidfile：nginx / dashboard / agent / cloudflared
    |-- fail.<key>             # 崩溃退避计数
    |-- restored.last          # 已生效的备份名（等价上游 /dashboard/dbfile）
    |-- backup.last            # 最近一次成功备份的日期（修掉原版"今天已备份"判定失效）
    |-- renew.last             # 最近一次版本检查日期
    |-- lock/                  # mkdir 原子锁，owner 文件记录持锁 pid
    `-- flags/backup-inprogress.<N>   # 还原冷却计数
```

远端备份库里会出现三个东西：`data-<时间>.zip`（加密数据）、`README.md`（首行裸文件名 = 当前生效备份）、`manifest.txt`（不加密的清单，便于不进容器就能核对大小/节点数/时间）。

---

## 五、流量路径（谁监听什么）

容器内**只有一个 nginx** 在对外监听，面板与探针都在 `127.0.0.1` 上：

```
                       ┌─ Cloudflare Tunnel（在 CF 后台配路由）
                       │
  浏览器 ──https──> CF edge ─┬─ 面板域名  *                    ──> http://localhost:$PORT ─┐
                             │                                                            ├─> nginx
  探针   ──gRPC──> CF edge ─┴─ Agent域名 /proto.NezhaService/*  ──> http://localhost:$PORT ─┘   │
                             （或 :$HTTPS_PORT 走自签 TLS 回源）                                  │
                                                                                                 ▼
                                                                        nginx ─┬─ grpc_pass  ──> 127.0.0.1:$DASH_PORT
                                                                               └─ proxy_pass  ──> 127.0.0.1:$DASH_PORT
```

nginx 内部的两条分流规则（`create_nginx_config` 生成，`$PORT`/`$HTTPS_PORT` 全部来自环境变量）：

| 路径 | 处理 | 原因 |
|---|---|---|
| `/proto.NezhaService/*` | `grpc_pass grpc://dashboard`（HTTP/2 gRPC） | 探针上报必须走 gRPC 代理，`proxy_pass` 转发不了 |
| `/api/v1/ws/(server\|terminal\|file)*` | `proxy_pass` + `Upgrade`/`Connection` 头 | 终端与文件管理的 WebSocket |
| `*`（其余） | `proxy_pass http://127.0.0.1:$DASH_PORT` | 面板页面与 API |

真实 IP 链：`CF-Connecting-IP` → `X-Forwarded-For` 首段 → `remote_addr` 三级 `map` 取值，经 `nz-realip` 头透传给面板，保证面板记录的是探针真实出口 IP 而不是 CF 节点 IP。

> 原版 README 里"面板域名直连 `:8008` 绕过 nginx"的说法，对应的是 **CF 后台的隧道路由**写法；本补丁版容器内统一由 nginx 监听 `$PORT` 后分流，不再需要（也不应该）把 `8008` 直接暴露给隧道——`DASH_PORT` 只绑 `127.0.0.1`。

---

## 六、构建与部署

```bash
docker build -t yourname/koyeb-nezha:latest .
```

### 本机跑（看日志与自测）

```bash
docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e NZ_CLIENT_SECRET=your-token \
  -e ARGO_AUTH=<tunnel-token> -e ARGO_DOMAIN=panel.example.com \
  -e NZ_UUID=<agent-uuid> -e NZ_TARGET=tunnel \
  -e GITHUB_REPO_OWNER=me -e GITHUB_REPO_NAME=nezha-backup \
  -e GITHUB_TOKEN=ghp_xxx -e ZIP_PASSWORD=xxx \
  yourname/koyeb-nezha:latest
```

`PORT=8080` 就是验证第 3 项修复的最直接方式：改这个值，`docker exec <c> ./start.sh render-nginx` 应看到 `listen 8080 default_server;`。

### Koyeb

服务端口填 `80`（或让平台注入 `PORT`，两者本版都支持），健康检查路径可选 `/healthz`。
其余变量按上表在 Secrets/Environment 里配。

### 跑测试

```bash
bash tests/verify.sh    # bash -n + nginx 渲染断言（不联网）
bash tests/smoke.sh     # lib.sh 纯逻辑 34 项断言（不联网、不需 zip/sqlite3）
```

---

## 七、仍未实现的上游特性（明确边界）

- TunnelSecret **JSON 模式**与 `argo.yml` 自动路由（仍只支持 Token，路径要在 CF 后台手配）
- 通过隧道暴露 **SSH**
- 面板**自带 vless/vmess 节点与订阅**（`UUID` / `SUB_NAME` / `CF_IP`）
- `nezfz` / `webapp` 等额外闭源二进制（刻意不移植）
- Nezha **v0.x 兼容**与多端口体系（`WEB_PORT` / `GRPC_PORT` 分离）
- `zip -P` 仍是 ZipCrypto 弱加密，安全性依赖仓库 private + token 权限最小化

---

## 八、验证状态（诚实边界）

已在 Linux 语义下自动化验证：

- `bash -n` 六个脚本全通过
- `tests/verify.sh`：注入 `PORT=7777` 渲染 nginx，断言 `listen 7777 default_server;`、`listen 9443 ssl;`、`127.0.0.1:18008` 出现，且**无残留 `listen 80`**、`$host` 未被 shell 展开、gRPC upstream 保留
- `tests/smoke.sh` 34 项断言：端口体系、README 双格式解析、`backup` 标记不误判、冷却 tick 递增至释放、长冷却 3 倍、锁互斥与陈旧锁抢占自愈、pid 判活、`agent_secret_key` 漂移复位

**未验证**（开发机无 Docker/WSL，且 Git Bash 缺 `zip`/`sqlite3`/`jq`）：

- `backup.sh` / `restore.sh` 的真实 GitHub API 读写闭环
- 真实 nezha 面板对 `config.yaml` 模板键位的接受度（若面板拒绝启动，设 `PRESET_CONFIG=false` 即回退到原版"全交面板自建"行为）
- `NZ_TARGET=local` 下面板与探针的实际建连

上容器后建议按此顺序确认：`tests/verify.sh` → `./start.sh self-test` → 配齐 GH 变量后 `./backup.sh f` → 改远端 README 首行看 `periodic_restore` 是否在 `CHECK_INTERVAL` 内响应。
