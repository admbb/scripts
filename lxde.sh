#!/usr/bin/env bash
# Debian 12/13 LXDE + XRDP 一键安装，适用于 PVE LXC 或 Debian 服务器
set -Eeuo pipefail

RDP_USER="${RDP_USER:-desktop}"

error() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

[[ "$(id -u)" -eq 0 ]] || error "请使用 root 运行脚本。"
[[ -r /etc/os-release ]] || error "无法识别操作系统。"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || error "仅支持 Debian。"
[[ "${VERSION_ID:-}" == "12" || "${VERSION_ID:-}" == "13" ]] || error "仅支持 Debian 12/13。"
[[ "$RDP_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || error "RDP_USER 用户名不合法。"
[[ "$RDP_USER" != "root" ]] || error "请使用普通用户登录图形桌面，不要指定 root。"
command -v systemctl >/dev/null || error "需要 systemd；请在已启动的 Debian 容器或系统中运行。"

printf 'Debian %s | LXDE + XRDP | 登录用户: %s\n' "$VERSION_ID" "$RDP_USER"

info "1/5 更新 APT 软件包列表"
export DEBIAN_FRONTEND=noninteractive
apt-get update

info "2/5 安装 LXDE、中文字体与 XRDP"
apt-get install -y --no-install-recommends \
    lxde-core openbox-lxde-session lxterminal \
    xrdp xorgxrdp xserver-xorg-core \
    dbus-x11 xauth x11-xserver-utils \
    xdg-utils fonts-wqy-microhei ca-certificates
command -v startlxde >/dev/null || error "找不到 startlxde，会话软件包可能未正确安装。"

info "3/5 配置远程桌面用户"
if id "$RDP_USER" >/dev/null 2>&1; then
    echo "用户 $RDP_USER 已存在，将继续配置其 LXDE 会话。"
else
    useradd -m -s /bin/bash "$RDP_USER"
fi
HOME_DIR="$(getent passwd "$RDP_USER" | cut -d: -f6)"
[[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || error "用户主目录不存在：$HOME_DIR"
SESSION_FILE="$HOME_DIR/.xsession"
if [[ -e "$SESSION_FILE" ]] && ! grep -Fxq 'exec startlxde' "$SESSION_FILE"; then
    cp -a -- "$SESSION_FILE" "${SESSION_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
fi
printf 'exec startlxde\n' > "$SESSION_FILE"
chown "$RDP_USER:" "$SESSION_FILE"
chmod 644 "$SESSION_FILE"

printf '\n请设置用户 %s 的远程桌面登录密码：\n' "$RDP_USER"
passwd "$RDP_USER"

info "4/5 开启 XRDP 服务"
if id xrdp >/dev/null 2>&1 && getent group ssl-cert >/dev/null; then
    usermod -aG ssl-cert xrdp
fi
# 不覆盖 Debian 默认 /etc/xrdp/startwm.sh；它会加载用户的 ~/.xsession。
systemctl enable xrdp-sesman xrdp
systemctl restart xrdp-sesman xrdp
systemctl is-active --quiet xrdp-sesman || error "xrdp-sesman 未正常运行。"
systemctl is-active --quiet xrdp || error "xrdp 未正常运行。"

info "5/5 显示连接信息"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP="${IP:-<Debian容器IP>}"
printf '\n安装完成！\n连接地址：%s:3389\n登录用户：%s\n会话类型：Xorg\nWindows：Win+R -> mstsc -> %s:3389\n' "$IP" "$RDP_USER" "$IP"
printf '\n安全提示：请只在可信局域网或 VPN 内访问 3389，不要直接暴露公网。\n'
