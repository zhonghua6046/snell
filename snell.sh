#!/bin/bash

# 脚本出现错误时自动退出
set -e

# --- 变量及函数定义 ---

# 版本号定义 (下次更新只需修改这里)
VERSION="v5.0.1"

# 彩色输出
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"

SNELL_BIN_FILE="/usr/local/bin/snell-server"
SNELL_CONFIG_DIR="/etc/snell"
SNELL_CONFIG_FILE="/etc/snell/snell-server.conf"
SNELL_SERVICE_FILE="/lib/systemd/system/snell.service"

# 检查是否为 Root 用户
check_root(){
    if [[ $EUID -ne 0 ]]; then
        echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_font_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限。"
        exit 1
    fi
}

# 自动检测包管理器
check_package_manager(){
    if command -v apt-get >/dev/null 2>&1; then
        PM="apt"
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
    else
        echo -e "${Error} 未知的包管理器，脚本无法继续。"
        exit 1
    fi
}

# 安装依赖
install_dependencies(){
    echo -e "${Info} 正在安装必要工具 (wget, unzip)..."
    if [ "$PM" = "apt" ]; then
        apt-get update && apt-get install -y wget unzip
    elif [ "$PM" = "yum" ] || [ "$PM" = "dnf" ]; then
        $PM install -y wget unzip
    fi
    echo -e "${Info} 依赖安装完成。"
}

# 生成强密码
generate_strong_psk(){
    tr -dc 'A-Za-z0-9!@#$%^&*()_+-' </dev/urandom | head -c 24
}

# 生成随机端口
generate_random_port(){
    # 范围 20000-65535
    echo $((RANDOM % 45536 + 20000))
}

# 核心下载逻辑 (安装和升级共用)
download_snell(){
    echo -e "${Info} 正在检查服务器架构..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-amd64.zip";;
        i386 | i686) ARCH_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-i386.zip";;
        aarch64) ARCH_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-aarch64.zip";;
        armv7l) ARCH_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-armv7l.zip";;
        *) echo -e "${Error} 不支持的服务器架构: $ARCH"; exit 1;;
    esac
    
    echo -e "${Info} 检测到架构为 ${ARCH}，正在下载 Snell Server ${VERSION}..."
    wget -O snell-server.zip "$ARCH_URL"
    
    echo -e "${Info} 解压安装文件..."
    unzip -o snell-server.zip -d /usr/local/bin/
    chmod +x "$SNELL_BIN_FILE"
    rm snell-server.zip
    echo -e "${Info} Snell Server 二进制文件部署完成。"
}

# 安装Snell
install_snell(){
    if [ -f "$SNELL_BIN_FILE" ]; then
        echo -e "${Error} Snell Server似乎已经安装，请勿重复安装！如果需要更新，请选择菜单中的 [升级] 选项。"
        exit 1
    fi
    
    check_package_manager
    install_dependencies
    
    # 调用下载函数
    download_snell

    # 配置Snell
    echo -e "${Info} 开始配置 Snell Server..."
    read -p "请输入 Snell 服务端口 [留空则随机生成 20000-65535]: " SNELL_PORT
    if [ -z "${SNELL_PORT}" ]; then
        SNELL_PORT=$(generate_random_port)
        echo -e "${Info} 已为您随机生成端口: ${SNELL_PORT}"
    fi

    read -p "请输入 Pre-Shared Key (PSK) [留空则自动生成强密码]: " SNELL_PSK
    if [ -z "${SNELL_PSK}" ]; then
        SNELL_PSK=$(generate_strong_psk)
    fi

    read -p "是否开启 IPv6 支持? [y/N]: " SNELL_IPV6_ENABLE
    [[ "$SNELL_IPV6_ENABLE" =~ ^[yY]$ ]] && SNELL_IPV6="true" || SNELL_IPV6="false"

    mkdir -p "$SNELL_CONFIG_DIR"
    cat > "$SNELL_CONFIG_FILE" <<EOF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${SNELL_IPV6}
EOF
    echo -e "${Info} 配置文件创建成功。"

    # 配置Systemd服务
    cat > "$SNELL_SERVICE_FILE" <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target
[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${SNELL_BIN_FILE} -c ${SNELL_CONFIG_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server
[Install]
WantedBy=multi-user.target
EOF
    echo -e "${Info} Systemd 服务文件创建成功。"

    # 启动服务
    systemctl daemon-reload
    systemctl enable snell
    systemctl start snell

    echo -e "\n${Green_font_prefix}Snell Server 安装并启动成功!${Font_color_suffix}\n"
    view_config_info
}

# 升级Snell (新增功能)
update_snell(){
    if [ ! -f "$SNELL_BIN_FILE" ]; then
        echo -e "${Error} 未检测到 Snell Server 安装，无法升级。请先选择安装。"
        exit 1
    fi

    echo -e "${Info} 正在准备升级 Snell Server 到版本 ${VERSION}..."
    
    # 备份旧版本
    if [ -f "$SNELL_BIN_FILE" ]; then
        echo -e "${Info} 备份当前版本到 ${SNELL_BIN_FILE}.bak ..."
        mv "$SNELL_BIN_FILE" "${SNELL_BIN_FILE}.bak"
    fi

    # 停止服务
    systemctl stop snell

    # 调用下载函数
    check_package_manager # 确保unzip/wget存在
    install_dependencies
    download_snell

    # 重启服务
    systemctl daemon-reload
    systemctl start snell
    
    echo -e "\n${Green_font_prefix}Snell Server 已成功升级到 ${VERSION}!${Font_color_suffix}\n"
    
    # 显示状态
    if systemctl is-active --quiet snell; then
        echo -e "${Info} 服务运行状态: ${Green_font_prefix}正常运行${Font_color_suffix}"
    else
        echo -e "${Error} 服务启动失败，正在回滚旧版本..."
        mv "${SNELL_BIN_FILE}.bak" "$SNELL_BIN_FILE"
        systemctl start snell
        echo -e "${Info} 已回滚到旧版本，请检查日志。"
    fi
}

# 卸载Snell
uninstall_snell(){
    if [ ! -f "$SNELL_BIN_FILE" ]; then
        echo -e "${Error} 未检测到 Snell Server 安装，无需卸载。"
        exit 1
    fi
    read -p "您确定要卸载 Snell Server 吗? [y/N]: " UNINSTALL_CONFIRM
    [[ ! "$UNINSTALL_CONFIRM" =~ ^[yY]$ ]] && echo -e "${Info} 用户取消了卸载操作。" && exit 0
    
    systemctl stop snell || true
    systemctl disable snell || true
    rm -f "$SNELL_SERVICE_FILE" "$SNELL_BIN_FILE" "${SNELL_BIN_FILE}.bak"
    rm -rf "$SNELL_CONFIG_DIR"
    systemctl daemon-reload
    echo -e "${Green_font_prefix}Snell Server 已成功卸载！${Font_color_suffix}"
}

# 查看配置信息
view_config_info(){
    if [ ! -f "$SNELL_CONFIG_FILE" ]; then
        echo -e "${Error} Snell 配置文件不存在，可能未安装。"
        exit 1
    fi
    local SNELL_PORT=$(grep "listen" "$SNELL_CONFIG_FILE" | awk -F'[:=]' '{print $NF}' | tr -d ' ')
    local SNELL_PSK=$(grep "psk" "$SNELL_CONFIG_FILE" | awk -F'[=]' '{print $2}' | tr -d ' ')
    local SNELL_IPV6=$(grep "ipv6" "$SNELL_CONFIG_FILE" | awk -F'[=]' '{print $2}' | tr -d ' ')

    echo -e "\n${Green_font_prefix}---------- Snell 配置信息 ----------${Font_color_suffix}"
    echo -e "  - ${Green_font_prefix}端口 (Port):${Font_color_suffix}  ${SNELL_PORT}"
    echo -e "  - ${Green_font_prefix}密钥 (PSK):${Font_color_suffix}   ${SNELL_PSK}"
    echo -e "  - ${Green_font_prefix}IPv6 支持:${Font_color_suffix}    ${SNELL_IPV6}"
    echo -e "  - ${Green_font_prefix}当前版本:${Font_color_suffix}     ${VERSION}"
    echo -e "${Green_font_prefix}------------------------------------${Font_color_suffix}\n"
    
    if systemctl is-active --quiet snell; then
        echo -e "${Info} Snell 服务正在 ${Green_font_prefix}运行中${Font_color_suffix}。"
    else
        echo -e "${Info} Snell 服务当前 ${Red_font_prefix}已停止${Font_color_suffix}。"
    fi
}

# 修改配置
modify_config(){
    if [ ! -f "$SNELL_CONFIG_FILE" ]; then
        echo -e "${Error} Snell 配置文件不存在，无法修改。请先安装。"
        exit 1
    fi

    local current_port=$(grep "listen" "$SNELL_CONFIG_FILE" | awk -F'[:=]' '{print $NF}' | tr -d ' ')
    local current_psk=$(grep "psk" "$SNELL_CONFIG_FILE" | awk -F'[=]' '{print $2}' | tr -d ' ')
    local current_ipv6=$(grep "ipv6" "$SNELL_CONFIG_FILE" | awk -F'[=]' '{print $2}' | tr -d ' ')

    echo -e "${Info} 开始修改配置。"
    read -p "请输入新的端口 [当前: ${current_port}] (直接回车保留, 输入 'rand' 随机生成): " new_port_input
    if [ -z "${new_port_input}" ]; then
        new_port="${current_port}"
    elif [[ "${new_port_input,,}" == "rand" ]]; then
        new_port=$(generate_random_port)
        echo -e "${Info} 已为您随机生成新端口: ${new_port}"
    else
        new_port="${new_port_input}"
    fi
    
    read -p "请输入新的PSK [当前: ${current_psk}] (直接回车进行下一步): " new_psk_input
    if [ -z "${new_psk_input}" ]; then
        read -p "您希望保留当前PSK还是生成新PSK? [1.保留(默认) 2.生成新的]: " psk_choice
        if [[ "$psk_choice" == "2" ]]; then
            new_psk=$(generate_strong_psk)
            echo -e "${Info} 已为您生成新的随机强密码。"
        else
            new_psk="${current_psk}"
        fi
    else
        new_psk="${new_psk_input}"
    fi

    read -p "是否开启 IPv6 支持? [当前: ${current_ipv6}] (y/N): " new_ipv6_enable
    if [[ "$new_ipv6_enable" =~ ^[yY]$ ]]; then
        new_ipv6="true"
    elif [[ "$new_ipv6_enable" =~ ^[nN]$ ]]; then
        new_ipv6="false"
    else
        new_ipv6="${current_ipv6}"
    fi

    # 写入新配置
    cat > "$SNELL_CONFIG_FILE" <<EOF
[snell-server]
listen = 0.0.0.0:${new_port}
psk = ${new_psk}
ipv6 = ${new_ipv6}
EOF
    
    echo -e "${Info} 配置已更新，正在重启 Snell 服务..."
    systemctl restart snell
    sleep 1 # 等待一秒确保服务状态更新

    if systemctl is-active --quiet snell; then
        echo -e "\n${Green_font_prefix}Snell 服务重启成功，新配置已生效!${Font_color_suffix}\n"
        view_config_info
    else
        echo -e "${Error} Snell 服务重启失败！请使用 'systemctl status snell' 命令检查错误日志。"
    fi
}


# --- 主菜单 ---
main_menu(){
    clear
    echo "================================================"
    echo "        Snell Server 一键管理脚本 (${VERSION})"
    echo "================================================"
    echo ""
    echo "  1. 安装 Snell Server"
    echo "  2. 卸载 Snell Server"
    echo "  3. 查看 Snell 配置"
    echo "  4. 修改 Snell 配置"
    echo "  5. 升级 Snell Server (升级到 ${VERSION})"
    echo ""
    echo "  0. 退出脚本"
    echo ""
    echo "================================================"
    read -p "请输入您的选择 [0-5]: " user_choice

    case $user_choice in
        1) install_snell ;;
        2) uninstall_snell ;;
        3) view_config_info ;;
        4) modify_config ;;
        5) update_snell ;;
        0) exit 0 ;;
        *)
            echo -e "${Error} 无效的输入，请输入正确的数字。"
            sleep 2
            main_menu
            ;;
    esac
}

# --- 脚本执行入口 ---
check_root
main_menu
