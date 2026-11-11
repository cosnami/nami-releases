#!/usr/bin/env bash
# Installs the Nami panel (PostgreSQL, Redis, server, web and Caddy for HTTPS) with Docker on Linux.
# Run again to upgrade to the latest version; the answers and data are kept.
#
#   curl -fsSL https://github.com/cosnami/nami-releases/raw/main/install.sh | sudo bash
#
# A first install asks for the domain and the administrator's email, unless NAMI_DOMAIN and
# NAMI_ADMIN_EMAIL give them.
#   --uninstall          stop and remove the containers, keeping the data
#   --uninstall --purge  also remove the data and /opt/nami
set -euo pipefail

dir=/opt/nami
base=${NAMI_BASE:-https://github.com/cosnami/nami-releases/raw/main}

fail() {
  printf '错误 / error: %s\n' "$*" >&2
  exit 1
}

random() { head -c "$1" /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'; }

toml() {
  local value=${1//\\/\\\\}
  printf '"%s"' "${value//\"/\\\"}"
}

ask() {
  local answer=
  while [[ -z $answer ]]; do
    read -r -p "$1: " answer </dev/tty || fail "无法提问，请用环境变量提供 / no terminal to ask: $1"
  done
  printf '%s' "$answer"
}

uninstall() {
  if [[ -f $dir/compose.yaml ]]; then
    if [[ ${1:-} == --purge ]]; then
      docker compose -f "$dir/compose.yaml" down --volumes
      rm -rf "$dir"
    else
      docker compose -f "$dir/compose.yaml" down
    fi
  fi
  echo "Nami 已卸载 / uninstalled"
}

configure() {
  local domain=${NAMI_DOMAIN:-} admin_email=${NAMI_ADMIN_EMAIL:-}
  [[ -n $domain && -n $admin_email ]] || echo "首次安装，请回答几个问题 / first install, a few questions"
  [[ -n $domain ]] || domain=$(ask "域名 / domain (DNS 已指向本机 / pointing here)")
  [[ -n $admin_email ]] || admin_email=$(ask "管理员邮箱 / admin email")
  [[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || fail "域名无效 / not a domain: $domain"
  local postgres_password redis_password
  postgres_password=$(random 24)
  redis_password=$(random 24)
  admin_password=$(random 18)
  umask 077
  cat >config.toml <<CONFIG
[server]
listen = "0.0.0.0:4433"
trusted_proxies = ["172.30.0.0/24"]

[log]
level = "info"

[database]
host = "postgres"
port = 5432
name = "nami"
username = "nami"
password = "$postgres_password"
ssl_mode = "disable"

[cache]
host = "redis"
port = 6379
password = "$redis_password"

[secrets]
key = "$(random 32)"

# 首次启动时创建的管理员；登录并修改密码后可删除这一节
[admin]
email = $(toml "$admin_email")
password = "$admin_password"
CONFIG
  cat >.env <<ENV
NAMI_DOMAIN=$domain
POSTGRES_PASSWORD=$postgres_password
REDIS_PASSWORD=$redis_password
ENV
  umask 022
  chown 65534:65534 config.toml
  admin="$admin_email"
}

main() {
  [[ $(uname -s) == Linux ]] || fail "只支持 Linux / Linux only"
  [[ $(id -u) -eq 0 ]] || fail "需要 root，请用 sudo 运行 / run as root (sudo)"
  if [[ ${1:-} == --uninstall ]]; then
    uninstall "${2:-}"
    return
  fi

  if ! command -v docker >/dev/null; then
    echo "安装 Docker / installing Docker"
    curl -fsSL https://get.docker.com | sh
  fi
  docker compose version >/dev/null 2>&1 || fail "需要 Docker Compose 插件 / the Docker Compose plugin is required"

  install -d -m 0700 "$dir"
  cd "$dir"
  local admin='' admin_password=''
  [[ -f .env ]] || configure
  curl -fsSL --retry 3 -o compose.yaml "$base/compose.yaml" || fail "下载 compose.yaml 失败 / download failed"
  docker compose up -d --remove-orphans --wait --wait-timeout 300 ||
    fail "服务没有全部启动，查看日志 / not every service started: docker compose -f $dir/compose.yaml logs"

  local domain
  domain=$(sed -n 's/^NAMI_DOMAIN=//p' .env)
  echo
  echo "Nami 已启动 / running: https://$domain"
  if [[ -n $admin_password ]]; then
    echo "管理员 / admin: $admin  初始密码 / password: $admin_password"
    echo "登录后请修改密码，在后台设置里把公开地址设为 https://$domain，并配置邮件（SMTP）"
  fi
  echo "配置 / config: $dir/config.toml   日志 / logs: docker compose -f $dir/compose.yaml logs -f"
}

# Called last, so a download cut short runs nothing.
main "$@"
