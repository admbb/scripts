cat > /root/setup-ssh.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "错误：请使用 root 运行此脚本"
    exit 1
fi

echo "========== Debian SSH 自动配置 =========="

# 1. 安装 OpenSSH Server
echo "[1/6] 安装 OpenSSH Server..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openssh-server

# 2. 创建配置目录
echo "[2/6] 配置 root SSH 登录..."
mkdir -p /etc/ssh/sshd_config.d

CONFIG="/etc/ssh/sshd_config.d/00-root-login.conf"

# 备份原有配置
if [[ -f "$CONFIG" ]]; then
    cp -a "$CONFIG" "${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
fi

cat > "$CONFIG" <<'SSHEOF'
# Allow root SSH password login
PermitRootLogin yes
PasswordAuthentication yes
SSHEOF

chmod 644 "$CONFIG"

# 3. 验证 SSH 配置
echo "[3/6] 验证 SSH 配置..."
if ! /usr/sbin/sshd -t; then
    echo "错误：SSH 配置验证失败，请检查 $CONFIG"
    exit 1
fi

# 4. 设置 root 密码
echo "[4/6] 设置 root 密码..."
echo "请为 root 设置登录密码："
passwd root

# 5. 启动并设置开机自启
echo "[5/6] 启动 SSH 服务..."
systemctl enable ssh
systemctl restart ssh

# 6. 检查运行状态
echo "[6/6] 检查 SSH 服务..."

if systemctl is-active --quiet ssh; then
    echo "SSH 服务运行正常"
else
    echo "错误：SSH 服务启动失败"
    systemctl status ssh --no-pager || true
    exit 1
fi

echo ""
echo "========== SSH 配置结果 =========="

/usr/sbin/sshd -T | grep -E '^(permitrootlogin|passwordauthentication) ' || true

echo ""
echo "服务器 IP："
hostname -I

echo ""
echo "SSH 端口：22"
echo "SSH 用户：root"
echo ""
echo "连接示例："
IP=$(hostname -I | awk '{print $1}')
echo "ssh root@${IP}"
echo ""
echo "========== 配置完成 =========="
EOF

chmod +x /root/setup-ssh.sh
bash /root/setup-ssh.sh
