# FROM nginx:alpine

# RUN apk add --no-cache wget unzip bash curl git tar openssl jq procps tzdata zip sqlite sqlite-libs

FROM nginx:latest

# 更新源并安装所需软件包（部分包名已调整）
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

RUN chmod +x start.sh backup.sh restore.sh restart.sh renew.sh

EXPOSE 80 443

ENTRYPOINT ["/app/start.sh"]
