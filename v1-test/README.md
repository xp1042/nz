### V1版哪吒面板，自动备份,可选版本安装，可选择是否更新。

#### 安装好第一件事，**必须进面板改密码**

---

## ✅ 环境变量对照表

| 变量名 | 说明 |
|--------|------|
| `ARGO_AUTH` | Cloudflare Tunnel Token |
| `ARGO_DOMAIN` | 面板域名 |
| `GITHUB_TOKEN` | GitHub Token |
| `GITHUB_REPO_OWNER` | GitHub 用户名 |
| `GITHUB_REPO_NAME` | 备份仓库名 |
| `GITHUB_BRANCH` | 备份分支（默认 main） |
| `BACKUP_KEEP_COUNT` | 保留最近备份个数（默认保留 5 个） |
| `ZIP_PASSWORD` | 加密密码 |
| `NZ_UUID` | agent UUID |
| `NZ_CLIENT_SECRET` | agent secret |
| `NZ_TLS` | 是否 TLS（默认 true） |
| `DASHBOARD_VERSION` | 面板版本（留空则 latest） |

---

### 手动触发备份

将 GitHub 仓库中的 `README.md` 文件内容替换为以下内容，容器在下次检查时（每小时一次）会立即执行备份：

```
backup
```

---

### 备份触发逻辑

```
每小时检查一次
│
├── README.md 内容为 "backup" ──→ 立即备份
│
└── 当前时间为凌晨 4 点
    └── 且今天尚未备份 ──────────→ 自动备份
                                    └── 未设置 DASHBOARD_VERSION
                                        └── 同时检查版本更新
```

---

## 最终配置总结：路径分流彻底解决面板 502 且 Agent 不掉线

Cloudflare Tunnel 路由规则已经正确实现了**流量分离**：

### 核心思路
- **Agent gRPC 通信**（`/proto.NezhaService/*`） **继续走 Nginx**（`localhost:80`），由 Nginx 提供稳定的 HTTP/2 和 gRPC 代理支持。
- **面板 HTTP/API 请求**（所有其他路径 `*`） **直连 Dashboard**（`localhost:8008`），不再经过 Nginx 反代，避免 Nginx 对长连接（WebSocket）或 gRPC 协议处理不当导致的间歇性 502。

### 为什么这样就彻底好了？
1. **面板访问**（页面、API、WebSocket 等）直接命中 Dashboard 的 HTTP 服务，绕过了 Nginx 反代的连接中断问题，**502 不再出现**。
2. **Agent 上报和心跳**（gRPC over HTTP/2）仍走 Nginx，因为 Nginx 的 `grpc_pass` 配置能正确转发 gRPC 协议，且你已验证该代理链路稳定。
3. 两者互不干扰，各取所需。

### 规则的含义
| 域名 | 路径 | 后端 | 用途 |
|------|------|------|------|
| `Agent域名` | `/proto.NezhaService/*` | `:80` | 纯 Agent 域名，gRPC 经 Nginx |
| `面板` | `*` | `:8008` | 纯面板域名，全直连 |

