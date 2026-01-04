#!/bin/bash

# ==========================================
# Sing-box Socks 管理脚本
# 特性：Alice IPv6 Only 适配、智能 DNS 切换 (NAT64)、一键卸载
# ==========================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# ====================
# DNS 切换逻辑
# ====================
DNS_MODIFIED=false
RESOLV_CONF="/etc/resolv.conf"
BACKUP_CONF="/etc/resolv.conf.bak.singbox"

# 恢复 DNS 的函数 (无论何时退出都会尝试执行)
restore_dns() {
    if [ "$DNS_MODIFIED" = true ]; then
        echo -e "${YELLOW}正在恢复原始 DNS 配置...${PLAIN}"
        if [ -f "$BACKUP_CONF" ]; then
            cat "$BACKUP_CONF" > "$RESOLV_CONF"
            rm -f "$BACKUP_CONF"
            echo -e "${GREEN}原始 DNS 已恢复。${PLAIN}"
        else
            echo -e "${RED}警告：未找到 DNS 备份文件，无法自动恢复。请手动检查 /etc/resolv.conf${PLAIN}"
        fi
        DNS_MODIFIED=false
    fi
}

# 注册陷阱：脚本退出或被中断时，强制恢复 DNS
trap restore_dns EXIT INT TERM

# 临时切换 NAT64 DNS
switch_nat64_dns() {
    echo -e "${YELLOW}正在备份并切换到 NAT64 DNS 以支持 GitHub 下载...${PLAIN}"
    cp "$RESOLV_CONF" "$BACKUP_CONF"
    
    # 写入用户提供的 NAT64 DNS
    echo -e "nameserver 2a01:4f8:c2c:123f::1\nnameserver 2a00:1098:2c::1\nnameserver 2a01:4f9:c010:3f02::1" > "$RESOLV_CONF"
    
    DNS_MODIFIED=true
    echo -e "${GREEN}DNS 切换完成。${PLAIN}"
}

# ====================
# 函数：安装 Sing-box
# ====================
install_singbox() {
    echo -e "${GREEN}=== 开始安装 Sing-box ===${PLAIN}"

    if command -v sing-box &> /dev/null; then
        echo -e "${YELLOW}检测到 sing-box 已安装，跳过安装步骤...${PLAIN}"
    else
        # 1. 检查 GitHub 连通性
        echo -e "正在检查 GitHub 连接..."
        # 测试连接 objects.githubusercontent.com (下载域)
        if curl -I --connect-timeout 5 -6 https://objects.githubusercontent.com &>/dev/null; then
            echo -e "${GREEN}连接正常，直接下载...${PLAIN}"
        else
            echo -e "${RED}连接失败 (IPv6 Only 常见问题)。${PLAIN}"
            # 切换 DNS
            switch_nat64_dns
        fi

        # 2. 执行官方脚本
        echo -e "${YELLOW}正在运行官方安装脚本...${PLAIN}"
        curl -fsSL https://sing-box.app/install.sh | sh
        
        # 检查安装结果
        if ! command -v sing-box &> /dev/null; then
            echo -e "${RED}严重错误：安装失败！${PLAIN}"
            # DNS 会由 trap 自动恢复，这里直接退出
            exit 1
        fi
        
        echo -e "${GREEN}sing-box 安装成功！${PLAIN}"
        
        # 手动触发恢复 DNS (虽然 trap 会做，但安装完立即恢复是个好习惯)
        restore_dns
    fi

    # 3. 收集配置
    echo -e "\n${YELLOW}=== 配置 SOCKS5 信息 ===${PLAIN}"

    # 自动检测网卡 (IPv6 优先)
    AUTO_INTERFACE=$(ip route get 2001:4860:4860::8888 2>/dev/null | grep -oP 'dev \K\S+')
    if [ -z "$AUTO_INTERFACE" ]; then
        AUTO_INTERFACE=$(ls /sys/class/net | grep -v lo | head -1)
    fi

    DEFAULT_SERVER="2a14:67c0:116::1"
    DEFAULT_PORT="10001"
    DEFAULT_USER="alice"
    DEFAULT_PASS="alicefofo123..OVO"

    read -p "SOCKS5 地址 (IPv6) [默认: $DEFAULT_SERVER]: " INPUT_SERVER
    SOCKS_SERVER=${INPUT_SERVER:-$DEFAULT_SERVER}

    read -p "SOCKS5 端口 [默认: $DEFAULT_PORT]: " INPUT_PORT
    SOCKS_PORT=${INPUT_PORT:-$DEFAULT_PORT}

    read -p "SOCKS5 用户名 [默认: $DEFAULT_USER]: " INPUT_USER
    SOCKS_USER=${INPUT_USER:-$DEFAULT_USER}

    read -p "SOCKS5 密码 [默认: $DEFAULT_PASS]: " INPUT_PASS
    SOCKS_PASS=${INPUT_PASS:-$DEFAULT_PASS}

    read -p "出口网卡名称 [默认: $AUTO_INTERFACE]: " INPUT_INTERFACE
    BIND_INTERFACE=${INPUT_INTERFACE:-$AUTO_INTERFACE}

    # 4. 写入配置
    mkdir -p /etc/sing-box
    CONFIG_FILE="/etc/sing-box/config.json"
    
    echo -e "${YELLOW}正在写入配置文件...${PLAIN}"
    cat > $CONFIG_FILE <<EOF
{
  "log": {
    "disabled": true,
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": [
        "172.16.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "route_exclude_address": "::/0",
      "mtu": 1492,
      "auto_route": true,
      "strict_route": false,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "socks-out",
      "server": "$SOCKS_SERVER",
      "server_port": $SOCKS_PORT,
      "version": "5",
      "username": "$SOCKS_USER",
      "password": "$SOCKS_PASS",
      "bind_interface": "$BIND_INTERFACE"
    },
    {
      "type": "direct",
      "tag": "direct-out",
      "bind_interface": "$BIND_INTERFACE"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "ip_version": 6,
        "outbound": "direct-out"
      }
    ]
  }
}
EOF

    # 5. 启动服务
    echo -e "${YELLOW}启动服务...${PLAIN}"
    systemctl restart sing-box
    systemctl enable sing-box

    # 6. 验证
    sleep 2
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}Sing-box 启动成功！${PLAIN}"
        echo -e "正在测试 IPv4 连接 (curl api.ipify.org)..."
        
        # 注意：这里可能会因为 DNS 刚恢复而有一点延迟，重试一次
        CURRENT_IP=$(curl -s --max-time 5 api.ipify.org)
        if [ -z "$CURRENT_IP" ]; then
             sleep 1
             CURRENT_IP=$(curl -s --max-time 10 api.ipify.org)
        fi

        if [ -n "$CURRENT_IP" ]; then
            echo -e "${GREEN}测试通过！当前 IPv4 IP: $CURRENT_IP${PLAIN}"
        else
            echo -e "${RED}警告：无法获取 IPv4 地址。${PLAIN}"
            echo -e "SOCKS5 连接可能正常，但 DNS 解析可能需要检查。"
        fi
    else
        echo -e "${RED}启动失败，请检查日志：journalctl -u sing-box -n 20${PLAIN}"
    fi
}

# ====================
# 函数：卸载 Sing-box
# ====================
uninstall_singbox() {
    echo -e "${RED}警告：即将完全卸载 Sing-box。${PLAIN}"
    read -p "确定要继续吗？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi

    echo -e "${YELLOW}停止服务并清理文件...${PLAIN}"
    systemctl stop sing-box
    systemctl disable sing-box
    
    # 尝试多种路径删除
    rm -f /usr/local/bin/sing-box
    rm -f /usr/bin/sing-box
    rm -rf /etc/sing-box
    
    # 删除服务文件
    rm -f /etc/systemd/system/sing-box.service
    rm -f /usr/lib/systemd/system/sing-box.service
    
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# ====================
# 主菜单
# ====================
clear
echo -e "#############################################"
echo -e "#  Sing-box socks (Alice IPv6 Only 专用)    #"
echo -e "#     使用 NAT64 DNS 解决下载问题           #"
echo -e "#############################################"
echo -e "${GREEN}1.${PLAIN} 安装/配置 Sing-box"
echo -e "${RED}2.${PLAIN} 卸载 Sing-box"
echo -e "0. 退出"
read -p "请选择: " choice

case $choice in
    1) install_singbox ;;
    2) uninstall_singbox ;;
    *) exit 0 ;;
esac
