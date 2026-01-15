#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# --- 路径定义 ---
ROOT_PATH="/root"
INSTALL_DIR="$ROOT_PATH/realm"
TAR_FILE="$ROOT_PATH/realm.tar.gz"
BIN_FILE="$INSTALL_DIR/realm"
CONFIG_FILE="$INSTALL_DIR/realm.toml"
LOG_FILE="$INSTALL_DIR/realm.log"
SERVICE_PATH="/etc/systemd/system/realm.service"
DNS_BACKUP="/etc/resolv.conf.bak_realm"
DNS_MODIFIED=0
BACKUP_DIR="$ROOT_PATH/realm_backup"

# 检查 Root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 用户运行此脚本！${PLAIN}" && exit 1

# --- 辅助工具 ---
info() { echo -e "${BLUE}[INFO]${PLAIN} $1"; }
success() { echo -e "${GREEN}[OK]${PLAIN} $1"; }
warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
err() { echo -e "${RED}[ERROR]${PLAIN} $1"; }

pause() {
    echo -e "\n${BLUE}按任意键返回主菜单...${PLAIN}"
    read -n 1 -s -r
}

# --- 功能模块 ---

backup_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        info "备份当前配置..."
        mkdir -p "$BACKUP_DIR"
        local timestamp=$(date "+%Y%m%d_%H%M%S")
        cp "$CONFIG_FILE" "$BACKUP_DIR/realm.toml.$timestamp"
        success "已备份至: $BACKUP_DIR"
    fi
}

backup_and_set_dns_ipv6() {
    info "检测到可能的 IPv6 环境，尝试优化 DNS..."
    if [[ -f /etc/resolv.conf ]]; then cp /etc/resolv.conf "$DNS_BACKUP"; fi
    echo -e "nameserver 2a01:4f8:c2c:123f::1\nnameserver 2a00:1098:2c::1\nnameserver 2a01:4f9:c010:3f02::1" > /etc/resolv.conf
    DNS_MODIFIED=1
    sleep 3
}

restore_dns() {
    if [[ $DNS_MODIFIED -eq 1 ]]; then
        if [[ -f "$DNS_BACKUP" ]]; then mv -f "$DNS_BACKUP" /etc/resolv.conf; fi
        DNS_MODIFIED=0
    fi
}
trap restore_dns EXIT

get_download_url() {
    info "检测网络环境 (超时限制 3s)..."
    if curl -s --connect-timeout 3 --max-time 3 -I https://github.com >/dev/null 2>&1; then
        success "GitHub 连接正常"
    else
        if curl -s --connect-timeout 2 --max-time 2 -I https://www.baidu.com >/dev/null 2>&1; then
            warn "检测到中国大陆网络，且无法直连 GitHub。"
            warn "由于您选择了官方直连，下载可能会失败或极慢。"
        else
            warn "网络受限，尝试 IPv6 DNS 优化..."
            backup_and_set_dns_ipv6
        fi
    fi

    info "获取最新版本..."
    latest_version=$(curl -s --connect-timeout 5 --max-time 5 "https://api.github.com/repos/zhboner/realm/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ -z "$latest_version" ]]; then
        err "获取版本超时或失败！(可能是 GFW 阻断)"
        err "尝试使用默认版本 v2.7.0 进行最后尝试..."
        latest_version="v2.7.0"
    else
        success "最新版本: ${latest_version}"
    fi
    
    arch=$(uname -m)
    if [[ $arch == "x86_64" ]]; then
        REALM_URL="https://github.com/zhboner/realm/releases/download/${latest_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
    elif [[ $arch == "aarch64" ]]; then
        REALM_URL="https://github.com/zhboner/realm/releases/download/${latest_version}/realm-aarch64-unknown-linux-gnu.tar.gz"
    else
        err "不支持的架构: $arch"
        return 1
    fi
    return 0
}

install_realm() {
    backup_config

    if [[ -f "$INSTALL_DIR" ]]; then
        rm -f "$INSTALL_DIR"
    fi

    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
    fi

    if ! get_download_url; then return; fi

    info "下载至: ${YELLOW}$TAR_FILE${PLAIN}"
    wget -O "$TAR_FILE" "$REALM_URL" --show-progress --tries=2 --timeout=10
    restore_dns

    if [[ ! -s "$TAR_FILE" ]]; then
        err "下载失败！文件为空。"
        rm -f "$TAR_FILE"
        return
    fi

    info "解压中..."
    tar -xvf "$TAR_FILE" -C "$INSTALL_DIR" >/dev/null 2>&1
    rm -f "$TAR_FILE"

    if [[ ! -f "$BIN_FILE" ]]; then
        err "解压后未找到程序文件！"
        return
    fi
    chmod +x "$BIN_FILE"
    success "安装成功！"

    if [[ -f "/root/realm.toml" ]] && [[ ! -f "$CONFIG_FILE" ]]; then
        mv "/root/realm.toml" "$CONFIG_FILE"
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<EOF
[network]
no_tcp = false
use_udp = true
EOF
    fi

    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=$BIN_FILE -c $CONFIG_FILE
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    
    echo -e "${YELLOW}是否立即添加转发规则？[y/n]${PLAIN}"
    read -r add_now
    if [[ "$add_now" == "y" ]]; then
        add_rule
    else
        start_service
    fi
}

add_rule() {
    mkdir -p "$INSTALL_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then 
        echo '[network]' > "$CONFIG_FILE"
        echo 'no_tcp = false' >> "$CONFIG_FILE"
        echo 'use_udp = true' >> "$CONFIG_FILE"
    fi

    while true; do
        echo -e "\n${BLUE}=== 添加转发规则 ===${PLAIN}"
        echo -e "请输入本地监听端口 ${YELLOW}(例如 20000)${PLAIN}:"
        read -r lport
        [[ -z "$lport" ]] && break 
        
        echo -e "请输入目标 IP/域名 ${YELLOW}(例如 1.1.1.1)${PLAIN}:"
        read -r raddr
        
        echo -e "请输入目标端口 ${YELLOW}(例如 443)${PLAIN}:"
        read -r rport
        
        cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
listen = "[::]:$lport"
remote = "$raddr:$rport"
EOF
        success "规则已添加: [::]:$lport -> $raddr:$rport"
        
        echo -e "${YELLOW}继续添加吗？[y/n]${PLAIN}"
        read -r continue_add
        if [[ "$continue_add" != "y" ]]; then
            break
        fi
    done
    
    restart_service
}

edit_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "配置文件不存在！"
        return
    fi
    backup_config
    nano "$CONFIG_FILE"
    restart_service
}

view_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        err "暂无日志文件"
        return
    fi
    echo -e "${BLUE}=== 显示最后 20 行日志 ===${PLAIN}"
    tail -n 20 "$LOG_FILE"
    echo -e "${BLUE}========================${PLAIN}"
}

start_service() {
    systemctl start realm
    check_status
}

stop_service() {
    systemctl stop realm
    success "服务已停止"
}

restart_service() {
    info "正在重启..."
    systemctl restart realm --no-block
    echo -ne "${BLUE}等待服务启动...${PLAIN}"
    sleep 5
    echo -e " ${GREEN}完成${PLAIN}"
    check_status
}

check_status() {
    echo -e "------------------------------"
    if systemctl is-active --quiet realm; then
        echo -e "状态: ${GREEN}运行中 (Active)${PLAIN}"
        echo -e "进程: $(pgrep -a realm)"
        echo -e "目录: $INSTALL_DIR"
    else
        echo -e "状态: ${RED}未运行 (Stopped)${PLAIN}"
        echo -e "提示: 如果刚重启完，可能是检测太快，请稍后再试。"
    fi
    echo -e "------------------------------"
}

update_realm() {
    info "开始更新..."
    systemctl stop realm
    install_realm
}

uninstall_realm() {
    echo -e "${RED}⚠️  确认卸载？(将删除 /root/realm 整个文件夹) [y/n]${PLAIN}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop realm
        systemctl disable realm >/dev/null 2>&1
        rm -rf "$INSTALL_DIR"
        rm -f "$SERVICE_PATH"
        systemctl daemon-reload
        success "卸载完成，已清理 $INSTALL_DIR"
    fi
}

show_menu() {
    while true; do
        echo -e "\n==========================================="
        echo -e "             Realm 管理脚本                 "
        echo -e "==========================================="
        echo -e "  1. 安装 Realm"
        echo -e "  2. 更新 Realm"
        echo -e "  3. 卸载 Realm"
        echo -e "-------------------------------------------"
        echo -e "  4. 添加转发规则"
        echo -e "  5. 修改配置文件"
        echo -e "  6. 查看运行日志"
        echo -e "-------------------------------------------"
        echo -e "  7. 启动服务"
        echo -e "  8. 停止服务"
        echo -e "  9. 重启服务"
        echo -e "  10.查看状态"
        echo -e "  0. 退出脚本"
        echo -e "==========================================="
        echo -e "请输入选项 [0-10]:"
        read -r choice

        case $choice in
            1) install_realm ;;
            2) update_realm ;;
            3) uninstall_realm ;;
            4) add_rule ;;
            5) edit_config ;;
            6) view_log ;;
            7) start_service ;;
            8) stop_service ;;
            9) restart_service ;;
            10) check_status ;;
            0) exit 0 ;;
            *) err "输入无效" ;;
        esac

        pause
    done
}

show_menu
