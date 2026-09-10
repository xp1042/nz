### V1 版哪吒面板（Koyeb 版）**补丁版**

自动备份 / 可选版本 / 可选择是否更新 —— 在原 `koyeb.zip` 基础上，一次性打进上游
`Docker-for-Nezha-Argo-server-v1.x` 的 7 项机制，并修掉原版几处会静默失效的逻辑。

> **安装好第一件事：进面板改密码（admin/admin 首启）。改完立即触发一次备份固化，否则热还原会回退凭证（见 9.6）。**

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
| `MIN_SERVERS_FOR_BACKUP` | `1` | 节点数低于此值判为空库拒绝备份。**默认 1**：只挡"重建后还没还原成的空库"，单节点面板正常备份（旧默认 2 会让单节点部署永不备份，见 8.4） |
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
**完整的 Koyeb 实操路径（无 Docker 构建流水线、API 部署、隧道回源选择、踩坑清单）见第九节。**

### 跑测试

```bash
bash tests/verify.sh     # 语法 + nginx 渲染 + 调用契约（19 项，不联网）
bash tests/smoke.sh      # lib.sh 逻辑 + 预置 config（30 项，不联网）
bash tests/contract.sh   # 谓词极性 + 冷却时长（25 项，不联网，约 10s）
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

## 八、验证状态

### 8.1 开发机自动化（bash -n / nginx 渲染断言 / lib.sh 纯逻辑断言）

- `bash -n` 六个脚本全通过
- `tests/verify.sh` 19 项：nginx 渲染（注入 `PORT=7777` 断言 `listen 7777 default_server;`、`listen 9443 ssl;`、`127.0.0.1:18008`、**无残留 `listen 80`**、`$host` 未被 shell 展开、gRPC upstream 保留）+ **调用契约**（`restore.sh` 无参=交互且带 tty 保护、`warn/err` 走 stderr、`backup.sh` 登记 `RESTORE_STATE`、空库闸门默认 1）
- `tests/smoke.sh` 30 项：端口体系、README 双格式解析、冷却递进、锁互斥与陈旧锁抢占、pid 判活、`agent_secret_key` 漂移复位
- `tests/contract.sh` 25 项：**谓词返回极性**与**冷却实际拦下的周期数**（8.3/8.4 三个缺陷都属"静态看没错、跑起来才反"这类，只有把极性和时长写成断言才拦得住）

### 8.2 Koyeb 实机全链路（2026-09-10，镜像 v2test1/v2test2，服务 jkv2）—— 原"未验证"清单现已全部转正

| 机制 | 实机结果 |
|---|---|
| 第 3 项 `$PORT` 参数化 | ✓ Koyeb 注入 `PORT=80`，日志 `端口规划：HTTP=80 (来自 $PORT=80)`，health_check `/healthz` 通过 |
| 第 4 项 `NZ_TARGET=local` | ✓ 探针经 `127.0.0.1:8008` 直连，面板 `[1] 在线`；隧道故障不误报离线 |
| 第 5 项 备份闭环 | ✓ README 改 `backup` → ≤60s 内在线快照→打包→上传 `data-<ts>.zip`+`manifest.txt`→回写 README→自动布冷却；远端回读校验通过 |
| 第 6 项 跨实例热还原 | ✓ **新部署首周期**自动从 GitHub 拉回上一实例的备份、完整性自检（节点数）、一次干净重启接管全部数据 —— 免疫"鬼魂库/数据回退"类事故 |
| 第 1 项 预置 config 模板 | ✓ 真实面板二进制接受 `preseed_data` 生成的 `config.yaml` 键位，首启 admin/admin，`sync_agent_secret` 复位生效 |
| 第 7 项 防抖 | ✓ 备份→冷却→还原→一次重启 全程无自踩；`restart.sh all` 后 HTTP 探活判定正常 |
| 隧道模式 | ✓ `ARGO_AUTH`+`ARGO_DOMAIN=jk.xp1042.bond`，cloudflared 注册、Web+gRPC 双通道、探针经公网隧道回连在线 |
| 凭证一致性 | ✓ 改用户名/密码后立即触发备份 → 备份含新凭证 → 容器热还原后新凭证仍有效（详见九） |

### 8.3 本次实机揪出并修复的一个真 bug（v2test1 → v2test2）

`sync_agent_secret()` 返回语义与调用方**恰好反转**：原实现"干净（token 无漂移）"时返回 0，而 `supervise()` 用 `if sync_agent_secret; then 重启 dashboard`，把 0 当"有改动"→ **面板每 60s 被误重启一次**（pid 持续轮换，日志刷 `agent_secret_key 被外部改动`）。修复（commit `f9b261b`）：

```bash
# 契约：0(真)=本次有改动需重启；1(假)=无改动勿重启
[ "$changed" = 1 ] && return 0 || return 1
```

修复后实测 20+ 分钟零误重启。**这正是第 2 项守护机制最典型的反模式教训：守护逻辑自身制造的故障比它救的活多。**

---

### 8.4 第二轮复查（2026-09-10 晚，对照线上实况与日志）又揪出三个缺陷

线上服务 `jkv2` HEALTHY、近 6 小时日志 143 行零 `[ERROR]`、`token 漂移`/误重启 **0 行**（证明 8.3 的修复生效）。在同一份日志里发现：

| 缺陷 | 表现与取证 | 修复 |
|---|---|---|
| **备份后自还原空转** | `21:53:26 手动备份 → data-…21-53-27.zip → 冷却 6 周期` → `21:58:40 检测到新备份：data-…21-53-27（当前=…19-56-59）→ 执行热还原` → `21:58:52 已重启服务`。**还原的就是它自己 5 分钟前刚推上去的那份**，每次备份必然换来一次全量重启。根因：`backup.sh` 只写 `BACKUP_STATE`（日期），从不写 `RESTORE_STATE`，冷却期满后名字比对必然不等 | `backup.sh` 回读校验通过后把 `$BACKUP_FILE` 登记进 `RESTORE_STATE`（本地数据此刻就是这个包）；`verify.sh` 加静态断言防回归 |
| **长冷却形同虚设** | `flag_arm_long` 写后缀 `18`，而 `flag_tick` 判 `后缀 >= RESTORE_COOLDOWN(6)` → 第一个 tick 即判"早该到期"删除，3 倍冷却实际持续 **0 个周期**——而它恰好用在"远端回读没确认"这个最该按住的时刻。`smoke.sh` 原断言只查写下的文件名后缀、从不数周期，所以一直没暴露 | 后缀语义由"已耗计数"改为**剩余周期数**，`flag_tick` 只对自身后缀递减到 1 才释放；常规冷却行为不变（仍拦 5 轮）。新增 `tests/contract.sh` 用整轮 tick 计数断言"常规 5 / 长 17" |
| **空库闸门默认值过高** | 线上被迫显式设 `MIN_SERVERS_FOR_BACKUP=1` 才备份得动（`manifest.txt: servers=1`）。默认 2 隐含"至少两个节点"的假设，与单节点面板这一主要使用形态冲突，后果是**静默永不备份**（只 warn 一行） | 默认改为 `1`（真正要挡的是重建后尚未还原的 0 节点空库），并在 `verify.sh` 断言该默认值 |

顺带两处非缺陷修正：`/healthz` 由 `add_header Content-Type` 改为 `default_type`（前者会与 nginx 默认值叠加，线上实测响应头是 `application/octet-stream,text/plain` 两个值）；`restore.sh` 无参数改为交互选单并加无 tty 保护（原注释与实现不符，注释说交互、代码走自动）。

**本节修复的实机复验（v2test3，根目录布局经 Actions #21 构建）**：新实例开机 6 秒即完成"拉取上一实例备份→自检→接管"；随后手动备份 `data-…23-07-47.zip` + 观察 8 个周期（> 6 冷却），日志**零**"检测到新备份→执行热还原"行——v2test2 时代"每次备份必自还原重启一次"的空转确认消失；`/healthz` 响应头实测为单一 `text/plain`。

### 8.5 文档与线上实况的一处偏差（未改代码，按需选边）

`9.3` 记的是隧道路由 `h2c://localhost:80`（即经容器内 nginx 分流）。但实测：

```
https://<svc>.koyeb.app/healthz  -> 200 "ok"                    ← nginx 应答
https://jk.xp1042.bond/healthz   -> 404 + 面板 SPA HTML          ← 面板应答，nginx 未参与
https://jk.xp1042.bond/          -> 200 面板页面
```

即**隧道域名的 Web 流量直连面板、未经容器内 nginx**（gRPC 路径仍按规则走 nginx）。功能上没问题（CF 回源本身带真实 IP、面板 8008 同端口已支持 web+gRPC），但意味着第五节的 `nz-realip` 头改写与 nginx 侧路径分流对该域名不生效。二选一：要么把隧道路由改成 `h2c://localhost:80` 让 nginx 统一分流，要么接受现状并把第五节当作"仅当回源指向 `$PORT` 时适用"。**当前代码两种配法都能跑。**

---

## 九、Koyeb 部署实战（可复制路径 + 踩坑清单）

### 9.1 无 Docker 的机器怎么出镜像（GitHub Actions 流水线）

Windows 开发机不装 Docker：把本目录推到 `xp1042/nz` **仓库根**（本仓库只保留这一个版本：`Dockerfile`、`file/`、`tests/`、`README.md`），用仓库自带的 `Packages.yml`（workflow_dispatch，参数 `image_name/image_tag/dockerfile/context`，默认值就按根目录布局给的）在 ubuntu runner 上构建并推到 `ghcr.io/<user>/jk:<tag>`（设 Public 免凭证拉取）。

```bash
# 推文件（GitHub Contents API，path=本地文件 多组）
node contents-push.mjs xp1042/nz main "Dockerfile=.../Dockerfile" "file/start.sh=.../file/start.sh" ...
# 触发构建（workflow 文件名要 .yml 结尾的仓库原名）
node gh-dispatch.mjs <gh_token> xp1042/nz Packages.yml main \
  "image_name=jk,image_tag=v2test3,dockerfile=Dockerfile,context=."
# 轮询镜像就绪（匿名 manifest 200 = 可拉）
node check-ghcr.mjs v2test3
```

注意 Dockerfile 是 `COPY file/* /app/`，**构建 context 必须是同时含 `Dockerfile` 和 `file/` 的目录**。

### 9.2 Koyeb 侧

- API base 是 **`https://app.koyeb.com/v1`**（不是 api.koyeb.com）。`POST /v1/services` 建服务（definition 见 tools/deploy-def-v2.json 形态：image + env[] + port 80 http + health_check HTTP `/healthz` + regions [fra] + scaling min0/max1 deep_sleep 3900s）。
- 免费计划**只允许一个运行中服务**；新部署 `PUT /v1/services/{id}`（整份 definition）切 tag 即滚动发布，每次发布=一次新容器=一次开机还原流程。
- `GET /v1/services`（列表）里才带 `definitions[].routes[].url`；`/v1/deployments/{id}/status`、列表里 `routes[].url` 等变体端点实测 404/缺字段，别浪费时间。
- 免费计划 65 分钟无流量深睡，**只有打到 `*.koyeb.app` 边缘的流量才计入 idle**。保活脚本打 `https://<svc>.koyeb.app/healthz`（每 45s 足够）。隧道域名 jk.xp1042.bond 的流量不算数。

### 9.3 Cloudflare 隧道侧（这次烧了最多口舌的地方）

1. **token 种类先分清**：R2 页生成的 `cfat_` 是对象存储 token（对 /cfd/tunnels、zone DNS 全部无效）；`cfut_` 才是 API Token。建 API Token 用 *Create Custom Token*，权限必须**两行都加**：
   - `Account · Cloudflare Tunnel · Edit`（建隧道/取连接器 token）
   - `Zone · DNS · Edit`（jk 记录；不过走后台建 Public hostname 的话 CF 自动代建）
   - 缺 Tunnel 权限时报错**不是 403**，而是诡异的 `7003/7000 Could not route / No route for that URI` —— 见到这俩码先查 token 权限，不是路径错。
2. **走 Zero Trust 后台手建隧道完全可行**（连接器 token 解码可验：`a`=account、`t`=tunnel uuid）：Create tunnel(Cloudflared) → Public hostname `jk.xp1042.bond` → URL 填 **`h2c://localhost:80`** → ⋯ → Get token 即 `ARGO_AUTH`。
3. **回源地址为什么选 `h2c://localhost:80`**：容器内 nginx :80 已 `http2 on` 且带 `/proto.NezhaService/ → grpc_pass`，web+gRPC 一次分流到位、无 TLS 校验问题。若填 `https://localhost:443`（自签）必须同时开 Skip TLS verify **且**保证 HTTP/2 回源——少任何一项的症状是"面板 API 能用、探针永远离线"，极难查。
4. **同一 hostname 多条 Public hostname 规则时第一条先命中**，第二条是死规则；catch-all 保留 `http_status:404`。
5. cloudflared 的注册日志在容器内 `logs/cloudflared.log`，Koyeb stdout 看不到——**验证以效果为准**：`GET https://<域名>/healthz` 回 nginx 的 `200 ok`（=经 nginx :80）+ 面板节点在线。

### 9.4 面板 API 速查（本镜像实测，新版 nezha/gin 风格，与 V1 老面板不同）

```text
POST /api/v1/login          → 200 + {data:{token}}；失败也是 200 + {error:ApiErrorUnauthorized}
                              （判成败必须看 data.token，不能看状态码）
GET  /api/v1/server         → Bearer token；节点数组，last_active 为 0001-01-01 即离线
PATCH /api/v1/server/{id}   → 改节点名；CSRF：用 login 响应 set-cookie 里真实的 nz-csrf 值
                              双提交（Cookie: nz-csrf=X + 头 X-CSRF-Token: X），自造值必 403
POST /api/v1/profile        → 改用户名/密码正解：
                              {original_password, new_username, new_password}
                              （PUT/PATCH /user、POST /user(=注册撞唯一约束) 全是歧路，
                               源码见 cmd/dashboard/controller/user.go:55 updateProfile）
```

**首启管理员 `ADMIN_USER`=`admin`、`ADMIN_PASSWORD`=`admin`；这两个变量只是初始值的记法，本镜像不读取环境变量**，改凭证走上面的 profile API 或后台页面（改完立即触发备份固化，见 9.6）。

### 9.5 备份库（nezha_backup）注意

- 仓库是 **private**：匿名 `GET /repos/.../readme` 返回 404 不是被删，**查询必须带 token**。
- 备份按时间戳命名 + `BACKUP_KEEP_COUNT=5` 滚动；README 首行=当前生效备份；`manifest.txt` 明文可查节点数/大小。
- 加密 zip 用 `ZIP_PASSWORD`（ZipCrypto 弱加密，安全边界=仓库 private+token 最小权限，README 七已声明）。

### 9.6 运维铁律（血泪浓缩）

1. **改了面板内任何要持久化的东西（凭证/节点名/设置）→ 立刻触发一次备份**（README 写 `backup`），否则下次容器重建/热还原回退到旧备份。
2. 同一时刻**只允许一个实例活着**（免费计划天然保证；付费多实例会共写备份库互相踩）。
3. 换镜像 tag 后先看日志确认 `被外部改动` / `重启 dashboard` 不刷屏，再测功能（守护 bug 都是刷屏式的，很好认）。
4. 验证探针在线以**面板 API `last_active` 推进**为准，肉眼"页面能开"不算数。
5. 保活、监控、GitHub 操作用**独立 .mjs 脚本**而不是 shell 内联拼 JSON——引号转义在 PowerShell 里必炸（`node -e "..."` 带反引号/单引号即坟场）。

### 9.7 仍按原样保持"未验证"边界的内容

- `renew.sh` 版本自更新（本次部署 `NO_AUTO_RENEW=1` 关闭）
- `SEED_DB_URL` 导入预置库、`Force_Auth`、GitHub OAuth 段
- 隧道 JSON(TunnelSecret) 模式、SSH 穿透（本来就不支持，见七）
