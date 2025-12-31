#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心路径定义
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

# 检查是否为 Root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 1. 基础依赖检查与安装
install_dependencies() {
    echo -e "${GREEN}正在检查并安装系统依赖...${PLAIN}"
    if [[ -f /etc/debian_version ]]; then
        apt update -y || echo -e "${YELLOW}apt update 出现警告，尝试继续安装依赖...${PLAIN}"
        apt install -y curl wget unzip jq openssl
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y curl wget unzip jq openssl
    else
        echo -e "${RED}无法检测系统版本，请手动安装 curl, wget, unzip, jq, openssl${PLAIN}"
    fi
}

# 2. 安装/更新 Xray
install_xray() {
    echo -e "${GREEN}正在安装/更新 Xray...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
    
    if [[ ! -f "$XRAY_BIN" ]]; then
        echo -e "${RED}错误：Xray 安装失败，未找到 $XRAY_BIN 文件。${PLAIN}"
        echo -e "${RED}请检查网络连接或 Github 访问情况。${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}Xray 安装检查通过。${PLAIN}"
}

# 卸载 Xray
uninstall_xray() {
    echo -e "${YELLOW}正在卸载 Xray...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
    rm -rf /usr/local/etc/xray
    echo -e "${GREEN}Xray 卸载完成。${PLAIN}"
}

# 获取本机 IP
get_ip() {
    local ip=$(curl -s4m8 ip.sb)
    if [[ -z $ip ]]; then
        ip=$(curl -s4m8 ifconfig.me)
    fi
    echo $ip
}

# 生成随机端口
get_random_port() {
    local min=$1
    local max=65535
    echo $(shuf -i $min-$max -n 1)
}

# 生成 SS 密码 (智能匹配算法要求)
generate_ss_password() {
    local method=$1
    if [[ "$method" == "2022-blake3-aes-128-gcm" ]]; then
        # SS-2022 128位 必须严格 16 字节密钥
        openssl rand -base64 16
    elif [[ "$method" =~ "2022-blake3" ]]; then
        # SS-2022 其他 (256/chacha) 必须严格 32 字节密钥
        openssl rand -base64 32
    else
        # 经典 AEAD (aes-gcm/chacha20)，生成高强度随机密码 (24字节随机数转Base64)
        openssl rand -base64 24
    fi
}

# 配置生成主逻辑
configure_xray() {
    install_dependencies
    install_xray

    echo -e "${GREEN}请选择安装模式：${PLAIN}"
    echo "1. 仅安装 Reality"
    echo "2. 仅安装 Shadowsocks"
    echo "3. 安装 Reality + Shadowsocks (共存)"
    read -p "请输入选项 [1-3]: " install_mode

    # === 公共配置收集 ===
    
    # IPv4 询问
    force_ipv4=false
    read -p "是否强制所有流量走 IPv4? (y/n, 默认 n): " ipv4_choice
    if [[ "$ipv4_choice" == "y" || "$ipv4_choice" == "Y" ]]; then
        force_ipv4=true
    fi

    # === 命名询问 ===
    read -p "请输入节点名称备注 (默认: $(hostname)): " custom_node_name
    [[ -z "$custom_node_name" ]] && custom_node_name=$(hostname)

    # === Reality 配置生成 ===
    if [[ "$install_mode" == "1" || "$install_mode" == "3" ]]; then
        echo -e "${YELLOW}--- 配置 Reality ---${PLAIN}"
        
        # 外网端口 40000+
        read -p "请输入 Reality 外网端口 (默认随机 40000-65535): " reality_port
        [[ -z "$reality_port" ]] && reality_port=$(get_random_port 40000)
        
        # 内网端口 20000+
        reality_inner_port=$(get_random_port 20000)

        read -p "请输入回落域名 dest (默认 www.tesla.com): " reality_dest
        [[ -z "$reality_dest" ]] && reality_dest="www.tesla.com"
        if [[ "$reality_dest" != *":443" ]]; then
            reality_dest="${reality_dest}:443"
        fi

        read -p "请输入 SNI 域名 serverName (默认同 dest 域名部分): " reality_sni
        if [[ -z "$reality_sni" ]]; then
            reality_sni=$(echo $reality_dest | cut -d: -f1)
        fi

        # 密钥生成
        echo -e "${GREEN}正在生成 X25519 密钥...${PLAIN}"
        x25519_out=$($XRAY_BIN x25519)
        
        if [[ -z "$x25519_out" ]]; then
             echo -e "${RED}错误：无法运行 Xray 生成密钥！${PLAIN}"
             exit 1
        fi

        # 提取 Private Key
        reality_private_key=$(echo "$x25519_out" | grep -i "Private" | cut -d: -f2 | sed 's/ //g')
        # 提取 Public Key
        reality_public_key=$(echo "$x25519_out" | grep -E -i "Public|Password" | cut -d: -f2 | sed 's/ //g')
        
        reality_uuid=$($XRAY_BIN uuid)
        
        if [[ -z "$reality_private_key" || -z "$reality_uuid" ]]; then
            echo -e "${RED}错误：获取密钥或 UUID 失败。${PLAIN}"
            exit 1
        fi

        reality_shortid=$(openssl rand -hex 8)
    fi

    # === SS 配置生成 ===
    if [[ "$install_mode" == "2" || "$install_mode" == "3" ]]; then
        echo -e "${YELLOW}--- 配置 Shadowsocks ---${PLAIN}"
        
        # 外网端口 40000+
        read -p "请输入 SS 端口 (默认随机 40000-65535): " ss_port
        [[ -z "$ss_port" ]] && ss_port=$(get_random_port 40000)

        echo "请选择加密方式:"
        echo "--- 2022 新版协议 (性能好，但对时间敏感) ---"
        echo "1. 2022-blake3-aes-128-gcm"
        echo "2. 2022-blake3-aes-256-gcm (推荐)"
        echo "3. 2022-blake3-chacha20-poly1305"
        echo "--- 经典通用协议 (兼容性最好) ---"
        echo "4. aes-128-gcm"
        echo "5. aes-256-gcm (常用)"
        echo "6. chacha20-poly1305 (移动端推荐)"
        echo "7. xchacha20-poly1305"
        
        read -p "请选择 [1-7] (默认 2): " ss_method_choice
        case $ss_method_choice in
            1) ss_method="2022-blake3-aes-128-gcm" ;;
            2) ss_method="2022-blake3-aes-256-gcm" ;;
            3) ss_method="2022-blake3-chacha20-poly1305" ;;
            4) ss_method="aes-128-gcm" ;;
            5) ss_method="aes-256-gcm" ;;
            6) ss_method="chacha20-poly1305" ;;
            7) ss_method="xchacha20-poly1305" ;;
            *) ss_method="2022-blake3-aes-256-gcm" ;;
        esac

        read -p "请输入 SS 密码 (留空自动生成): " ss_password
        if [[ -z "$ss_password" ]]; then
            ss_password=$(generate_ss_password $ss_method)
        fi
    fi

    # === 写入 config.json ===
    echo -e "${GREEN}正在生成配置文件...${PLAIN}"

    cat > $CONFIG_FILE <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
EOF

    # 写入 Reality Inbounds
    if [[ "$install_mode" == "1" || "$install_mode" == "3" ]]; then
        cat >> $CONFIG_FILE <<EOF
        {
            "tag": "dokodemo-in",
            "port": $reality_port,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "127.0.0.1",
                "port": $reality_inner_port,
                "network": "tcp"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["tls"],
                "routeOnly": true
            }
        },
        {
            "listen": "127.0.0.1",
            "port": $reality_inner_port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$reality_uuid",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$reality_dest",
                    "serverNames": [
                        "$reality_sni"
                    ],
                    "privateKey": "$reality_private_key",
                    "shortIds": [
                        "$reality_shortid"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        }
EOF
    fi

    if [[ "$install_mode" == "3" ]]; then
        echo "," >> $CONFIG_FILE
    fi

    # 写入 SS Inbounds
    if [[ "$install_mode" == "2" || "$install_mode" == "3" ]]; then
        cat >> $CONFIG_FILE <<EOF
        {
            "port": $ss_port,
            "protocol": "shadowsocks",
            "settings": {
                "method": "$ss_method",
                "password": "$ss_password",
                "network": "tcp,udp"
            }
        }
EOF
    fi

    cat >> $CONFIG_FILE <<EOF
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
EOF

    if [[ "$force_ipv4" == true ]]; then
        cat >> $CONFIG_FILE <<EOF
        ,{
            "tag": "IP4_out",
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4"
            }
        }
EOF
    fi

    cat >> $CONFIG_FILE <<EOF
    ],
    "routing": {
        "rules": [
EOF

    if [[ "$install_mode" == "1" || "$install_mode" == "3" ]]; then
        cat >> $CONFIG_FILE <<EOF
            {
                "inboundTag": ["dokodemo-in"],
                "domain": ["$reality_sni"],
                "outboundTag": "direct"
            },
            {
                "inboundTag": ["dokodemo-in"],
                "outboundTag": "block"
            }
EOF
    fi

    if [[ "$force_ipv4" == true ]]; then
        if [[ "$install_mode" == "1" || "$install_mode" == "3" ]]; then
            echo "," >> $CONFIG_FILE
        fi
        
        cat >> $CONFIG_FILE <<EOF
            {
                "type": "field",
                "network": "tcp,udp",
                "outboundTag": "IP4_out"
            }
EOF
    fi

    cat >> $CONFIG_FILE <<EOF
        ]
    }
}
EOF

    systemctl restart xray
    echo -e "${GREEN}Xray 配置已更新并重启！${PLAIN}"
    
    # === 输出信息 ===
    local server_ip=$(get_ip)
    
    echo -e ""
    echo -e "${GREEN}================ 安装成功 ================${PLAIN}"
    echo -e "本机 IP: ${server_ip}"
    
    if [[ "$install_mode" == "1" || "$install_mode" == "3" ]]; then
        echo -e "\n${YELLOW}--- Reality 配置信息 ---${PLAIN}"
        echo -e "端口 (Port): ${reality_port}"
        echo -e "UUID: ${reality_uuid}"
        echo -e "SNI: ${reality_sni}"
        echo -e "公钥 (PBK): ${reality_public_key}"
        echo -e "ShortId: ${reality_shortid}"
        
        # 命名处理 (后缀修改为 -Reality)
        local alias="${custom_node_name}"
        if [[ "$install_mode" == "3" ]]; then
            alias="${custom_node_name}-Reality"
        fi
        
        local link="vless://${reality_uuid}@${server_ip}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_public_key}&sid=${reality_shortid}&type=tcp&headerType=none#${alias}"
        
        echo -e "${GREEN}VLESS 链接:${PLAIN}"
        echo -e "${link}"
    fi

    if [[ "$install_mode" == "2" || "$install_mode" == "3" ]]; then
        echo -e "\n${YELLOW}--- Shadowsocks 配置信息 ---${PLAIN}"
        echo -e "端口 (Port): ${ss_port}"
        echo -e "加密 (Method): ${ss_method}"
        echo -e "密码 (Password): ${ss_password}"
        
        # 命名处理 (后缀修改为 -SS)
        local ss_alias="${custom_node_name}"
        if [[ "$install_mode" == "3" ]]; then
            ss_alias="${custom_node_name}-SS"
        fi

        local user_pass="${ss_method}:${ss_password}"
        local b64_user_pass=$(echo -n "$user_pass" | base64 -w 0)
        local ss_link="ss://${b64_user_pass}@${server_ip}:${ss_port}#${ss_alias}"
        
        echo -e "${GREEN}SS 链接:${PLAIN}"
        echo -e "${ss_link}"
    fi
    echo -e "${GREEN}==========================================${PLAIN}"
}

echo -e "${GREEN}Xray 一键安装/管理脚本${PLAIN}"
echo "1. 安装/重置 Xray 配置 (Reality / SS)"
echo "2. 单独更新 Xray 内核"
echo "3. 卸载 Xray"
echo "0. 退出"

read -p "请选择: " choice

case $choice in
    1) configure_xray ;;
    2) install_xray; systemctl restart xray; echo "Xray 更新完成";;
    3) uninstall_xray ;;
    0) exit 0 ;;
    *) echo "无效选择"; exit 1 ;;
esac