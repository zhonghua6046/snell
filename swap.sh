#!/bin/bash

SWAPFILE="/swapfile"

# 颜色输出
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m" # No Color

# 错误退出函数
error_exit() {
    echo -e "${RED}错误:${NC} $1"
    exit 1
}

# 检查是否是 root 用户
if [ "$(id -u)" != "0" ]; then
    error_exit "请使用 root 权限执行本脚本"
fi

# 检查当前 Swap 是否存在
swap_exists() {
    swapon --show | grep -q "$SWAPFILE"
}

# 添加或扩展 Swap
add_swap() {
    read -p "请输入 Swap 总大小（MB）： " size

    # 确保输入是正整数
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
        error_exit "请输入有效的 Swap 大小（单位：MB）"
    fi

    # 检查磁盘空间
    local free_space=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt "$size" ]; then
        error_exit "磁盘空间不足，可用空间：${free_space}MB，需求：${size}MB"
    fi

    # 如果 Swap 已存在，则扩展 Swap
    if swap_exists; then
        current_size=$(free -m | awk '/Swap:/ {print $2}')
        if [ "$size" -le "$current_size" ]; then
            echo -e "${YELLOW}当前 Swap 已为 ${current_size}MB，无需扩展${NC}"
            return
        fi

        echo -e "${YELLOW}正在扩展 Swap，从 ${current_size}MB 扩展到 ${size}MB${NC}"
        swapoff "$SWAPFILE"
        dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size" status=progress
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE"
        swapon "$SWAPFILE"

        echo -e "${GREEN}Swap 已成功扩展至 ${size}MB${NC}"
    else
        echo -e "${GREEN}正在创建 ${size}MB Swap 文件...${NC}"
        if command -v fallocate &>/dev/null; then
            fallocate -l "${size}M" "$SWAPFILE" || { echo "fallocate 失败，回退到 dd"; dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size" status=progress; }
        else
            dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size" status=progress
        fi

        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE"
        swapon "$SWAPFILE"

        # 持久化 Swap
        if ! grep -q "^$SWAPFILE" /etc/fstab; then
            echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
            echo -e "${GREEN}Swap 持久化成功！${NC} 已自动添加到 /etc/fstab"
        fi

        echo -e "${GREEN}Swap 已成功增加至 ${size}MB${NC}"
    fi

    show_status
}

# 删除 Swap
remove_swap() {
    if swap_exists; then
        echo -e "${YELLOW}正在关闭 Swap...${NC}"
        swapoff "$SWAPFILE" || error_exit "swapoff 失败"
    fi

    if [ -f "$SWAPFILE" ]; then
        rm -f "$SWAPFILE" || error_exit "删除 Swap 文件失败"
        echo -e "${GREEN}Swap 文件已删除${NC}"
        
        # 清理 fstab
        if grep -q "^$SWAPFILE" /etc/fstab; then
            sed -i "\|^$SWAPFILE|d" /etc/fstab
            echo -e "${GREEN}已从 /etc/fstab 中移除 Swap 条目${NC}"
        fi
    else
        echo -e "${YELLOW}未找到 Swap 文件${NC}"
    fi

    show_status
}

# 显示 Swap 状态
show_status() {
    echo -e "\n${GREEN}当前内存和 Swap 使用情况：${NC}"
    free -h
    swapon --show
}

# 交互式菜单
main_menu() {
    while true; do
        echo -e "\n${GREEN}===== Swap 管理菜单 =====${NC}"
        echo -e "1) 添加或扩展 Swap"
        echo -e "2) 删除 Swap"
        echo -e "3) 查看 Swap 状态"
        echo -e "0) 退出"
        read -p "请选择操作 [0-3]: " choice

        case "$choice" in
            1) add_swap ;;
            2) remove_swap ;;
            3) show_status ;;
            0) echo -e "${YELLOW}退出程序...${NC}"; exit 0 ;;
            *) echo -e "${RED}无效输入，请输入 0-3${NC}" ;;
        esac
    done
}

# 运行交互式菜单
main_menu