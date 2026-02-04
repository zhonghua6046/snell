#!/bin/bash

# ==================================================
# Shadowsocks-Rust 管理脚本 (V6 - IPv6 适配版)
# ==================================================

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PLAIN='\033[0m'

# 路径定义
BIN_PATH="/usr/local/bin"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"

# 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 sudo 或 root 用户运行此脚本！${PLAIN}"
   exit 1
fi

# ================= 工具函数 =================

separator() {
    echo -e "\n${BLUE}==================================================${PLAIN}\n"
}

pause() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo ""
    separator
}

url_encode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# 智能获取 IP (优先 v4，失败则 v6，最后手动)
get_public_ip() {
    local ipv4=$(curl -s4m3 ip.sb)
    if [[ -n "$ipv4" ]]; then
        echo "$ipv4"
        return
    fi
    
    local ipv6=$(curl -s6m3 ip.sb)
    if [[ -n "$ipv6" ]]; then
        echo "$ipv6"
        return
    fi
    
    echo "无法自动获取IP"
}

check_deps() {
    local CMD_INSTALL
    if [[ -f /etc/redhat-release ]]; then
        CMD_INSTALL="yum install -y"
    elif cat /etc/issue | grep -q -E -i "debian|ubuntu"; then
        CMD_INSTALL="apt-get install -y"
    else
        CMD_INSTALL="yum install -y"
    fi
    
    if ! command -v jq &> /dev/null || ! command -v wget &> /dev/null; then
        echo -e "${GREEN}正在安装必要依赖 (jq, curl, wget, tar...)${PLAIN}"
        ${CMD_INSTALL} curl wget jq tar xz-utils openssl lsof
    fi
}

get_meta_data() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) GITHUB_ARCH="x86_64-unknown-linux-gnu" ;;
        aarch64) GITHUB_ARCH="aarch64-unknown-linux-gnu" ;;
        *) echo -e "${RED}不支持的架构: ${ARCH}${PLAIN}"; exit 1 ;;
    esac

    echo -e "正在查询 GitHub 最新版本..."
    local API_URL="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
    local LATEST_JSON=$(curl -s "${API_URL}")
    
    LATEST_TAG_RAW=$(echo "$LATEST_JSON" | jq -r .tag_name)
    LATEST_TAG=${LATEST_TAG_RAW#v} 
    
    LATEST_URL=$(echo "$LATEST_JSON" | jq -r ".assets[] | select(.name | contains(\"${GITHUB_ARCH}\")) | .browser_download_url" | grep ".tar.xz$")
    
    if [[ -z "$LATEST_URL" ]]; then
        echo -e "${RED}获取失败，请检查网络或 GitHub API 限制。${PLAIN}"
        exit 1
    fi
}

install_binaries() {
    check_deps
    echo -e "${GREEN}正在下载版本 ${LATEST_TAG}...${PLAIN}"
    wget -O /tmp/ss-rust.tar.xz "$LATEST_URL"
    echo -e "${GREEN}正在解压安装...${PLAIN}"
    mkdir -p /tmp/ss-rust
    tar -xf /tmp/ss-rust.tar.xz -C /tmp/ss-rust
    find /tmp/ss-rust -type f -name "ss*" -exec mv {} ${BIN_PATH}/ \;
    chmod +x ${BIN_PATH}/ss*
    rm -rf /tmp/ss-rust /tmp/ss-rust.tar.xz
}

install_full() {
    get_meta_data
    install_binaries
    
    if [[ ! -d ${CONFIG_DIR} ]]; then mkdir -p ${CONFIG_DIR}; fi
    if [[ ! -f ${CONFIG_FILE} ]]; then echo '{"servers": []}' > ${CONFIG_FILE}; fi
    
    cat > ${SERVICE_FILE} <<EOF
[Unit]
Description=Shadowsocks-Rust Server Service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH}/ssserver -c ${CONFIG_FILE}
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable shadowsocks-rust
    
    echo -e "${GREEN}安装完成！即将进入节点配置...${PLAIN}"
    sleep 1
    add_node_logic
}

# ================= 核心：添加节点逻辑 =================
add_node_logic() {
    echo -e "\n${BLUE}========== 配置新节点 ==========${PLAIN}"
    
    # 1. 协议选择
    echo -e "请选择加密协议:"
    echo -e "  1) aes-128-gcm"
    echo -e "  2) aes-256-gcm"
    echo -e "  3) chacha20-ietf-poly1305"
    echo -e "  4) 2022-blake3-aes-128-gcm"
    echo -e "  5) 2022-blake3-aes-256-gcm"
    echo -e "  6) 2022-blake3-chacha20-poly1305"
    
    read -p "请输入数字 [1-6] (默认2): " method_num
    case $method_num in
        1) METHOD="aes-128-gcm" ;;
        3) METHOD="chacha20-ietf-poly1305" ;;
        4) METHOD="2022-blake3-aes-128-gcm" ;;
        5) METHOD="2022-blake3-aes-256-gcm" ;;
        6) METHOD="2022-blake3-chacha20-poly1305" ;;
        *) METHOD="aes-256-gcm" ;;
    esac
    echo -e "已选择协议: ${YELLOW}$METHOD${PLAIN}"

    # 2. 监听地址选择 (解决纯 IPv6 问题)
    echo -e "\n请选择监听地址 (Listen Address):"
    echo -e "  1) 0.0.0.0 (IPv4 Only / 传统)"
    echo -e "  2) ::      (IPv6 Only / 双栈 - 纯v6机器选这个)"
    read -p "请输入数字 [1-2] (默认1): " listen_num
    if [[ "$listen_num" == "2" ]]; then
        SERVER_ADDR="::"
        echo -e "监听地址: ${YELLOW}[::]${PLAIN}"
    else
        SERVER_ADDR="0.0.0.0"
        echo -e "监听地址: ${YELLOW}0.0.0.0${PLAIN}"
    fi

    # 3. 出站流量优先级 (ipv6_first)
    echo -e "\n请选择出站流量优先级 (Outbound Priority):"
    echo -e "  1) IPv4 优先 (默认 - ipv6_first: false)"
    echo -e "  2) IPv6 优先 (ipv6_first: true)"
    read -p "请输入数字 [1-2] (默认1): " prio_num
    if [[ "$prio_num" == "2" ]]; then
        V6_FIRST="true"
        echo -e "流量策略: ${YELLOW}IPv6 优先${PLAIN}"
    else
        V6_FIRST="false"
        echo -e "流量策略: ${YELLOW}IPv4 优先${PLAIN}"
    fi

    # 4. 端口
    while true; do
        echo -e "\n请输入端口号 (1024-65535)"
        read -p "留空则自动生成 (20000+): " input_port
        if [[ -z "$input_port" ]]; then
            PORT=$(shuf -i 20000-60000 -n 1)
        else
            PORT=$input_port
        fi
        if lsof -i :$PORT > /dev/null; then
            echo -e "${RED}端口 $PORT 已被占用，请更换！${PLAIN}"
        else
            echo -e "使用端口: ${YELLOW}$PORT${PLAIN}"
            break
        fi
    done

    # 5. 密码
    echo -e "\n请输入密码"
    if [[ "$METHOD" == *"2022"* ]]; then
        echo -e "${YELLOW}提示: SS-2022 协议建议使用自动生成。${PLAIN}"
    fi
    read -p "留空则自动生成: " input_pwd
    if [[ -z "$input_pwd" ]]; then
        if [[ "$METHOD" == *"2022"* ]]; then
            PASSWORD=$(openssl rand -base64 32)
        else
            PASSWORD=$(openssl rand -base64 16)
        fi
        echo -e "已自动生成密码: ${YELLOW}${PASSWORD}${PLAIN}"
    else
        PASSWORD=$input_pwd
        echo -e "使用密码: ${YELLOW}${PASSWORD}${PLAIN}"
    fi

    # 6. 名称
    echo -e "\n请输入节点名称 (用于备注)"
    read -p "留空默认为 \"SS-端口号\": " input_name
    if [[ -z "$input_name" ]]; then
        NODE_NAME="SS-${PORT}"
    else
        NODE_NAME="$input_name"
    fi

    # 写入配置 (增加 ipv6_first 字段)
    TMP_JSON=$(mktemp)
    jq ".servers += [{\"server\": \"$SERVER_ADDR\", \"server_port\": $PORT, \"password\": \"$PASSWORD\", \"method\": \"$METHOD\", \"mode\": \"tcp_and_udp\", \"ipv6_first\": $V6_FIRST}]" ${CONFIG_FILE} > "$TMP_JSON" && mv "$TMP_JSON" ${CONFIG_FILE}
    
    echo -e "${GREEN}正在重启服务...${PLAIN}"
    systemctl restart shadowsocks-rust
    
    if systemctl is-active --quiet shadowsocks-rust; then
        show_single_link "$PORT" "$PASSWORD" "$METHOD" "$NODE_NAME" "$SERVER_ADDR"
    else
        echo -e "${RED}启动失败！请检查日志。${PLAIN}"
        systemctl status shadowsocks-rust --no-pager
    fi
}

show_single_link() {
    local port=$1
    local pwd=$2
    local method=$3
    local name=$4
    local listen_addr=$5
    
    # 自动获取公网 IP (兼容 IPv6)
    local public_ip=$(get_public_ip)
    
    # 如果自动获取失败，让用户输入
    if [[ "$public_ip" == "无法自动获取IP" ]]; then
        read -p "无法自动获取公网 IP，请输入服务器 IP: " manual_ip
        public_ip=$manual_ip
    fi

    # 生成链接
    local raw="${method}:${pwd}@${public_ip}:${port}"
    local b64=$(echo -n "${raw}" | base64 -w 0)
    local encoded_name=$(url_encode "$name")
    local link="ss://${b64}#${encoded_name}"
    
    echo -e "\n${YELLOW}============== 节点分享 ==============${PLAIN}"
    echo -e "节点名称: ${GREEN}${name}${PLAIN}"
    echo -e "服务器IP: ${public_ip}"
    echo -e "端口: ${port}"
    echo -e "密码: ${pwd}"
    echo -e "协议: ${method}"
    echo -e "监听地址: ${listen_addr}"
    echo -e "----------------------------------------"
    echo -e "SS 链接: ${GREEN}${link}${PLAIN}"
    echo -e "${YELLOW}========================================${PLAIN}"
}

list_nodes() {
    if [[ ! -f ${CONFIG_FILE} ]]; then echo -e "${RED}无配置文件！${PLAIN}"; return; fi
    local count=$(jq '.servers | length' ${CONFIG_FILE})
    echo -e "\n当前共有 $count 个节点:"
    for ((i=0; i<$count; i++)); do
        local p=$(jq -r ".servers[$i].server_port" ${CONFIG_FILE})
        local m=$(jq -r ".servers[$i].method" ${CONFIG_FILE})
        local w=$(jq -r ".servers[$i].password" ${CONFIG_FILE})
        local s=$(jq -r ".servers[$i].server" ${CONFIG_FILE})
        show_single_link "$p" "$w" "$m" "Node-$p" "$s"
    done
}

update_core() {
    check_deps
    get_meta_data 
    if command -v ${BIN_PATH}/ssserver >/dev/null; then
        CURRENT_VER_RAW=$(${BIN_PATH}/ssserver --version | awk '{print $2}')
        CURRENT_VER=${CURRENT_VER_RAW#v}
    else
        CURRENT_VER="未安装"
    fi
    echo -e "当前版本: ${BLUE}${CURRENT_VER}${PLAIN}"
    echo -e "最新版本: ${GREEN}${LATEST_TAG}${PLAIN}"
    if [[ "$CURRENT_VER" == "$LATEST_TAG" ]]; then
        echo -e "${YELLOW}当前已是最新版本，无需升级。${PLAIN}"
        read -p "是否强制重新安装？[y/N] (默认N): " yn
    else
        echo -e "${GREEN}发现新版本！${PLAIN}"
        read -p "是否立即升级？[y/N] (默认N): " yn
    fi
    yn=${yn:-n}
    if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
        echo "停止服务..."
        systemctl stop shadowsocks-rust
        install_binaries
        systemctl start shadowsocks-rust
        echo -e "${GREEN}升级成功！服务已重启。${PLAIN}"
    else
        echo "已取消升级。"
    fi
}

uninstall_core() {
    echo -e "\n${RED}警告：此操作将删除所有 SS 服务和配置文件！${PLAIN}"
    read -p "确认卸载吗？[y/N] (默认N): " confirm
    confirm=${confirm:-n}
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop shadowsocks-rust
        systemctl disable shadowsocks-rust
        rm -f ${SERVICE_FILE}
        systemctl daemon-reload
        rm -f ${BIN_PATH}/ss*
        rm -rf ${CONFIG_DIR}
        echo -e "${GREEN}已成功卸载。${PLAIN}"
    else
        echo -e "${YELLOW}操作已取消。${PLAIN}"
    fi
}

while true; do
    separator
    echo -e "   Shadowsocks-Rust 管理脚本 (V6)"
    echo -e "----------------------------------"
    echo -e " 1. 安装服务 (全新安装)"
    echo -e " 2. 添加节点 (支持 v6 监听/出站策略)"
    echo -e " 3. 查看节点 (获取链接)"
    echo -e " 4. 升级内核 (版本检测)"
    echo -e " 5. 卸载服务"
    echo -e " 0. 退出脚本"
    echo -e "----------------------------------"
    read -p " 请选择: " choice
    case "$choice" in
        1) install_full; pause ;;
        2) 
            if [[ ! -f ${CONFIG_FILE} ]]; then echo -e "${RED}请先安装！${PLAIN}"; else add_node_logic; fi
            pause 
            ;;
        3) list_nodes; pause ;;
        4) update_core; pause ;;
        5) uninstall_core; pause ;;
        0) exit 0 ;;
        *) echo "无效选择"; ;;
    esac
done
