#!/usr/bin/env bash
# Installs native-edge on a systemd Linux host (x86_64 or aarch64), and stays on it as the command
# native-edge that manages it:
#
#   curl -fsSL https://github.com/cosnami/nami-releases/raw/main/native-edge/install.sh \
#     | sudo NAMI_URL='https://panel.example.com' NAMI_EDGE_TOKEN='edge.…' bash
#
# Without NAMI_URL and NAMI_EDGE_TOKEN an existing configuration is kept. Without NAMI_VERSION
# the newest release is installed; `native-edge install <file>` installs a binary built locally
# instead. native-edge does not upgrade itself: `native-edge update` does, and the restart closes
# every connection, so hosts are best updated one at a time.
set -euo pipefail

repository=cosnami/nami-releases
script_url=https://github.com/$repository/raw/main/native-edge/install.sh

user=native-edge
binary=/opt/native-edge/native-edge
manager=/usr/local/bin/native-edge
config_dir=/etc/native-edge
state_dir=/var/lib/native-edge
unit=/etc/systemd/system/native-edge.service

fail() {
  printf '错误 / error: %s\n' "$*" >&2
  exit 1
}

need_root() {
  [[ $(id -u) -eq 0 ]] || fail "需要 root，请用 sudo 运行 / run as root (sudo)"
}

usage() {
  cat <<USAGE
native-edge status               版本与运行状态 / version and state
native-edge log                  实时日志 / follow the log
native-edge start|stop|restart   启停服务 / control the service
native-edge update [版本]         更新，默认最新版 / update, to the newest by default
native-edge install <程序文件>     安装本地编译的程序 / install a binary built locally
native-edge uninstall [--purge]  卸载，--purge 连状态一起删 / remove, --purge also the state
USAGE
}

# Puts the release's binary in $work/native-edge.
download() {
  local arch version=${NAMI_VERSION:-}
  case $(uname -m) in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) fail "不支持的架构 / unsupported architecture: $(uname -m)" ;;
  esac
  if [[ -z $version ]]; then
    version=$(curl -fsSL "https://api.github.com/repos/$repository/releases?per_page=100" |
      grep -o '"tag_name": *"native-edge-v[^"]*"' | head -1 | sed 's/.*"native-edge-v//; s/"$//') || true
    [[ -n $version ]] || fail "找不到 native-edge 的发布版本 / no native-edge release found in $repository"
  fi
  echo "下载 / downloading native-edge $version ($arch)"
  curl -fsSL --retry 3 "https://github.com/$repository/releases/download/native-edge-v$version/native-edge-$arch-linux.gz" |
    gunzip >"$work/native-edge" || fail "下载失败 / download failed"
  chmod 0755 "$work/native-edge"
  [[ $("$work/native-edge" --version 2>/dev/null) == "native-edge $version" ]] ||
    fail "下载的程序无法运行或版本不符 / the downloaded binary does not run or is not $version"
}

install_edge() {
  need_root
  local source=${1:-} version
  if [[ -n ${NAMI_URL:-} || -n ${NAMI_EDGE_TOKEN:-} ]]; then
    [[ -n ${NAMI_URL:-} && -n ${NAMI_EDGE_TOKEN:-} ]] ||
      fail "NAMI_URL 和 NAMI_EDGE_TOKEN 需要同时设置 / set both NAMI_URL and NAMI_EDGE_TOKEN"
    [[ $NAMI_URL =~ ^https?://[^[:space:]\"\\]+$ ]] || fail "NAMI_URL 不是 http(s) 地址 / NAMI_URL is not an http(s) URL"
    [[ $NAMI_EDGE_TOKEN =~ ^edge\.[^[:space:]\"\\]+$ ]] || fail "NAMI_EDGE_TOKEN 无效 / NAMI_EDGE_TOKEN is not an Edge token"
  elif [[ ! -f $config_dir/config.toml ]]; then
    fail "首次安装需要 NAMI_URL 和 NAMI_EDGE_TOKEN / a first install needs NAMI_URL and NAMI_EDGE_TOKEN"
  fi

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  if [[ -n $source ]]; then
    [[ -f $source ]] || fail "找不到程序文件 / no such file: $source"
    install -m 0755 "$source" "$work/native-edge"
  else
    download
  fi
  version=$("$work/native-edge" --version 2>/dev/null) && [[ $version == "native-edge "* ]] ||
    fail "程序无法在这台主机上运行 / the binary does not run on this host"
  # This script stays as the native-edge command; piped in, it is fetched once more.
  if [[ -f ${BASH_SOURCE[0]:-} ]]; then
    cp "${BASH_SOURCE[0]}" "$work/manager"
  else
    curl -fsSL --retry 3 -o "$work/manager" "$script_url" || fail "下载失败 / download failed"
  fi

  id -u "$user" >/dev/null 2>&1 ||
    useradd --system --no-create-home --shell "$(command -v nologin || echo /bin/false)" "$user"
  install -d -m 0755 "${binary%/*}"
  install -d -m 0750 -o root -g "$user" "$config_dir"
  install -d -m 0700 -o "$user" -g "$user" "$state_dir"
  install -m 0755 "$work/native-edge" "$binary.new"
  mv -f "$binary.new" "$binary"
  install -m 0755 "$work/manager" "$manager.new"
  mv -f "$manager.new" "$manager"

  if [[ -n ${NAMI_URL:-} ]]; then
    (
      umask 077
      cat >"$config_dir/config.toml" <<CONFIG
server_url = "$NAMI_URL"
edge_token = "$NAMI_EDGE_TOKEN"
CONFIG
    )
    chown "$user:$user" "$config_dir/config.toml"
  fi
  runuser -u "$user" -- "$binary" check -c "$config_dir/config.toml" >/dev/null ||
    fail "配置无效 / the configuration does not hold: $config_dir/config.toml"

  cat >"$unit" <<UNIT
[Unit]
Description=native-edge
Wants=network-online.target
After=network-online.target

[Service]
User=$user
ExecStart=$binary run -c $config_dir/config.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable native-edge.service >/dev/null 2>&1
  systemctl restart native-edge.service

  echo "$version 已安装并启动 / installed and running"
  usage
}

uninstall() {
  need_root
  systemctl disable --now native-edge.service 2>/dev/null || true
  rm -f "$unit" "$manager"
  systemctl daemon-reload
  rm -rf "${binary%/*}" "$config_dir"
  if [[ ${1:-} == --purge ]]; then
    rm -rf "$state_dir"
    userdel "$user" 2>/dev/null || true
  fi
  echo "native-edge 已卸载 / uninstalled"
}

main() {
  [[ $(uname -s) == Linux ]] || fail "只支持 Linux / Linux only"
  command -v systemctl >/dev/null || fail "需要 systemd / systemd is required"
  # Piped in, the script installs; as the installed command, it explains itself.
  local command=${1:-$([[ $0 == "$manager" ]] && echo help || echo install)}
  case $command in
    install) install_edge "${2:-}" ;;
    status)
      "$binary" --version
      systemctl status native-edge.service --no-pager
      ;;
    log) journalctl -u native-edge.service -f ;;
    start | stop | restart)
      need_root
      systemctl "$command" native-edge.service
      ;;
    update)
      need_root
      curl -fsSL --retry 3 "$script_url" | NAMI_VERSION=${2:-} bash
      ;;
    uninstall) uninstall "${2:-}" ;;
    help | -h | --help) usage ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

# Called last, so a download cut short runs nothing.
main "$@"
