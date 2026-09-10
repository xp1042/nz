# koyeb 版哪吒面板 —— 补丁版镜像
#
# 相比原 Dockerfile 的变化：
#   - COPY file/* 已含新增的 lib.sh（公共库），必须一并授权
#   - ENV PORT=80 兜底：PaaS 注入 $PORT 时会覆盖，本地 docker run 也能跑
#   - 预建 logs/.state：脚本运行期状态目录，避免首启竞态
#   - nginx 日志转软链到 stdout/stderr：Koyeb 只有采集 stdout 的日志通道

FROM nginx:latest

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        unzip \
        bash \
        curl \
        git \
        tar \
        openssl \
        jq \
        procps \
        tzdata \
        zip \
        sqlite3 \
        libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

COPY file/* /app/

WORKDIR /app

RUN chmod +x /app/*.sh && \
    mkdir -p /app/data /app/logs /app/.state/flags && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

# 监听端口由 start.sh 读取 $PORT 生成 nginx 配置（不再硬编码 80）
ENV PORT=80

EXPOSE 80 443

ENTRYPOINT ["/app/start.sh"]
