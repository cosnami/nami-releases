#!/usr/bin/env bash
# Installs Nami Edge on a systemd Linux host (x86_64 or aarch64); run again to repair or upgrade.
# The admin console shows the command for each host:
#
#   curl -fsSL https://github.com/cosnami/nami-releases/raw/main/edge/install.sh \
#     | sudo NAMI_URL='https://panel.example.com' NAMI_EDGE_TOKEN='nami-edge.…' NAMI_VERSION='1.0.0' bash
#
# Without NAMI_URL and NAMI_EDGE_TOKEN an existing configuration is kept. Without NAMI_VERSION
# the newest release is installed; NAMI_RELEASE_REPOSITORY names where releases come from.
#   --uninstall          remove the service, binary and configuration, keeping the state
#   --uninstall --purge  also remove the state and the nami-edge user
set -euo pipefail

repository=${NAMI_RELEASE_REPOSITORY:-cosnami/nami-releases}
version=${NAMI_VERSION:-}

user=nami-edge
binary_dir=/opt/nami-edge
config_dir=/etc/nami-edge
state_dir=/var/lib/nami-edge
unit=/etc/systemd/system/nami-edge.service

fail() {
  printf '错误 / error: %s\n' "$*" >&2
  exit 1
}

[[ $(uname -s) == Linux ]] || fail "只支持 Linux / Linux only"
[[ $(id -u) -eq 0 ]] || fail "需要 root，请用 sudo 运行 / run as root (sudo)"
command -v systemctl >/dev/null || fail "需要 systemd / systemd is required"

uninstall() {
  systemctl disable --now nami-edge.service 2>/dev/null || true
  rm -f "$unit"
  systemctl daemon-reload
  rm -rf "$binary_dir" "$config_dir"
  if [[ ${1:-} == --purge ]]; then
    rm -rf "$state_dir"
    userdel "$user" 2>/dev/null || true
  fi
  echo "Nami Edge 已卸载 / uninstalled"
}

if [[ ${1:-} == --uninstall ]]; then
  uninstall "${2:-}"
  exit 0
fi

case $(uname -m) in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) fail "不支持的架构 / unsupported architecture: $(uname -m)" ;;
esac
if [[ -n ${NAMI_URL:-} || -n ${NAMI_EDGE_TOKEN:-} ]]; then
  [[ -n ${NAMI_URL:-} && -n ${NAMI_EDGE_TOKEN:-} ]] ||
    fail "NAMI_URL 和 NAMI_EDGE_TOKEN 需要同时设置 / set both NAMI_URL and NAMI_EDGE_TOKEN"
elif [[ ! -f $config_dir/config.toml ]]; then
  fail "首次安装需要 NAMI_URL 和 NAMI_EDGE_TOKEN / a first install needs NAMI_URL and NAMI_EDGE_TOKEN"
fi

if [[ -z $version ]]; then
  version=$(curl -fsSL "https://api.github.com/repos/$repository/releases?per_page=100" |
    grep -o '"tag_name": *"edge-v[^"]*"' | head -1 | sed 's/.*"edge-v//; s/"$//') || true
  [[ -n $version ]] || fail "找不到 edge 的发布版本 / no Edge release found in $repository"
fi

echo "下载 / downloading Nami Edge $version ($arch)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 "https://github.com/$repository/releases/download/edge-v$version/nami-edge-$arch-linux.gz" |
  gunzip >"$work/nami-edge" || fail "下载失败 / download failed"
chmod 0755 "$work/nami-edge"
[[ $("$work/nami-edge" --version) == "nami-edge $version" ]] ||
  fail "下载的程序无法运行或版本不符 / the downloaded binary does not run or is not $version"

id -u "$user" >/dev/null 2>&1 ||
  useradd --system --no-create-home --shell "$(command -v nologin || echo /bin/false)" "$user"
# The Edge owns its binary's directory so it can upgrade itself without root.
install -d -m 0755 -o "$user" -g "$user" "$binary_dir"
install -d -m 0750 -o root -g "$user" "$config_dir"
install -d -m 0700 -o "$user" -g "$user" "$state_dir"
install -m 0755 -o "$user" -g "$user" "$work/nami-edge" "$binary_dir/nami-edge.new"
mv -f "$binary_dir/nami-edge.new" "$binary_dir/nami-edge"

if [[ -n ${NAMI_URL:-} ]]; then
  [[ $NAMI_URL =~ ^https?://[^[:space:]\"\\]+$ ]] || fail "NAMI_URL 不是 http(s) 地址 / NAMI_URL is not an http(s) URL"
  [[ $NAMI_EDGE_TOKEN =~ ^nami-edge\.[^[:space:]\"\\]+$ ]] || fail "NAMI_EDGE_TOKEN 无效 / NAMI_EDGE_TOKEN is not an Edge token"
  (
    umask 077
    cat >"$config_dir/config.toml" <<CONFIG
server_url = "$NAMI_URL"
edge_token = "$NAMI_EDGE_TOKEN"
CONFIG
  )
  chown "$user:$user" "$config_dir/config.toml"
fi
"$binary_dir/nami-edge" check -c "$config_dir/config.toml" >/dev/null ||
  fail "配置无效 / the configuration does not hold: $config_dir/config.toml"

cat >"$unit" <<UNIT
[Unit]
Description=Nami Edge
Wants=network-online.target
After=network-online.target

[Service]
User=$user
ExecStart=$binary_dir/nami-edge run -c $config_dir/config.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable nami-edge.service >/dev/null 2>&1
systemctl restart nami-edge.service

echo "Nami Edge $version 已安装并启动 / installed and running"
echo "日志 / logs: journalctl -u nami-edge -f"
