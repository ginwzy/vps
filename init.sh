#!/bin/bash

#===============================================================================
# VPS 初始化脚本
# 适用于 Ubuntu/Debian 系统
# 功能：系统配置、安全加固、软件安装、网络优化
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志文件
LOG_FILE="/var/log/vps-init.log"

#===============================================================================
# 工具函数
#===============================================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${GREEN}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1"
    echo -e "${YELLOW}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "${RED}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行"
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            error "此脚本仅支持 Ubuntu/Debian 系统"
            exit 1
        fi
        log "检测到系统: $PRETTY_NAME"
    else
        error "无法检测操作系统"
        exit 1
    fi
}

press_enter() {
    echo ""
    read -p "按 Enter 键继续..."
}

#===============================================================================
# 模块1: 系统更新
#===============================================================================

update_system() {
    log "开始更新系统..."
    apt update
    apt upgrade -y
    apt autoremove -y
    log "系统更新完成"
}

#===============================================================================
# 模块2: 时区设置
#===============================================================================

set_timezone() {
    log "设置时区为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai
    log "当前时间: $(date)"
}

#===============================================================================
# 模块3: Swap 配置
#===============================================================================

configure_swap() {
    local swap_size

    # 检查是否已有 swap
    if swapon --show | grep -q '/swapfile'; then
        warn "Swap 已存在"
        swapon --show
        return
    fi

    # 获取内存大小，自动计算推荐 swap 大小
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $mem_total -le 1024 ]]; then
        swap_size="2G"
    elif [[ $mem_total -le 2048 ]]; then
        swap_size="2G"
    else
        swap_size="4G"
    fi

    read -p "请输入 Swap 大小 [默认: $swap_size]: " input_size
    swap_size=${input_size:-$swap_size}

    log "创建 ${swap_size} Swap..."
    fallocate -l "$swap_size" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # 持久化
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # 优化 swappiness
    sysctl vm.swappiness=10
    if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi

    log "Swap 配置完成"
    free -h
}

#===============================================================================
# 模块4: 创建用户
#===============================================================================

create_user() {
    local username
    read -p "请输入新用户名: " username

    if [[ -z "$username" ]]; then
        error "用户名不能为空"
        return 1
    fi

    if id "$username" &>/dev/null; then
        warn "用户 $username 已存在"
        return
    fi

    log "创建用户 $username..."
    adduser --gecos "" "$username"
    usermod -aG sudo "$username"

    # 配置 SSH 目录
    local ssh_dir="/home/$username/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    chown -R "$username:$username" "$ssh_dir"

    log "用户 $username 创建完成，已添加到 sudo 组"

    # 询问是否添加 SSH 公钥
    read -p "是否现在添加 SSH 公钥? [y/N]: " add_key
    if [[ "$add_key" =~ ^[Yy]$ ]]; then
        echo "请粘贴你的 SSH 公钥 (以 ssh-rsa 或 ssh-ed25519 开头):"
        read -r pubkey
        if [[ -n "$pubkey" ]]; then
            echo "$pubkey" >> "$ssh_dir/authorized_keys"
            log "SSH 公钥已添加"
        fi
    fi
}

#===============================================================================
# 模块5: SSH 安全配置
#===============================================================================

configure_ssh() {
    local ssh_port
    local sshd_config="/etc/ssh/sshd_config"

    # 备份原配置
    if [[ ! -f "${sshd_config}.bak" ]]; then
        cp "$sshd_config" "${sshd_config}.bak"
        log "已备份 SSH 配置"
    fi

    # 修改端口
    read -p "请输入新的 SSH 端口 [默认: 22]: " ssh_port
    ssh_port=${ssh_port:-22}

    log "配置 SSH 安全选项..."

    # 使用 sed 修改配置
    sed -i "s/^#\?Port .*/Port $ssh_port/" "$sshd_config"
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" "$sshd_config"
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$sshd_config"
    sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$sshd_config"
    sed -i "s/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/" "$sshd_config"

    # 确保配置存在
    grep -q "^Port " "$sshd_config" || echo "Port $ssh_port" >> "$sshd_config"
    grep -q "^PermitRootLogin " "$sshd_config" || echo "PermitRootLogin prohibit-password" >> "$sshd_config"
    grep -q "^PasswordAuthentication " "$sshd_config" || echo "PasswordAuthentication no" >> "$sshd_config"

    # 重启 SSH
    systemctl restart sshd

    log "SSH 配置完成，端口: $ssh_port"
    warn "请确保已添加 SSH 公钥，否则可能无法登录！"
    warn "请确保防火墙已开放端口 $ssh_port"
}

#===============================================================================
# 模块6: UFW 防火墙
#===============================================================================

configure_ufw() {
    log "配置 UFW 防火墙..."

    # 安装 UFW
    apt install -y ufw

    # 获取当前 SSH 端口
    local ssh_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    ssh_port=${ssh_port:-22}

    # 默认策略
    ufw default deny incoming
    ufw default allow outgoing

    # 开放 SSH 端口
    ufw allow "$ssh_port/tcp" comment 'SSH'

    # 询问是否开放其他端口
    read -p "是否开放 HTTP (80) 端口? [y/N]: " open_http
    [[ "$open_http" =~ ^[Yy]$ ]] && ufw allow 80/tcp comment 'HTTP'

    read -p "是否开放 HTTPS (443) 端口? [y/N]: " open_https
    [[ "$open_https" =~ ^[Yy]$ ]] && ufw allow 443/tcp comment 'HTTPS'

    read -p "是否开放其他端口? (多个端口用空格分隔，直接回车跳过): " other_ports
    for port in $other_ports; do
        ufw allow "$port" comment 'Custom'
    done

    # 启用防火墙
    echo "y" | ufw enable

    log "UFW 配置完成"
    ufw status verbose
}

#===============================================================================
# 模块7: Fail2ban
#===============================================================================

install_fail2ban() {
    log "安装配置 Fail2ban..."

    apt install -y fail2ban

    # 获取 SSH 端口
    local ssh_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    ssh_port=${ssh_port:-22}

    # 检测防火墙后端
    local ban_action="ufw"
    if command -v nft &>/dev/null; then
        ban_action="nftables-multiport"
        log "检测到 nftables，使用 nftables 作为封禁后端"
    elif command -v ufw &>/dev/null; then
        ban_action="ufw"
        log "使用 UFW 作为封禁后端"
    fi

    # 创建本地配置
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# 忽略本机地址，防止误封自己
ignoreip = 127.0.0.1/8 ::1

# 封禁 1 天
bantime  = 1d

# 在 10 分钟内累计失败即触发
findtime = 10m

# 触发封禁的失败次数阈值
maxretry = 3

# 防火墙后端
banaction = $ban_action
banaction_allports = ${ban_action/multiport/allports}

[sshd]
enabled  = true
port     = $ssh_port
backend  = systemd
mode     = aggressive
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban

    # 等待服务完全启动
    sleep 2

    log "Fail2ban 配置完成"
    fail2ban-client status
    fail2ban-client status sshd
}

#===============================================================================
# 模块8: BBR 网络优化
#===============================================================================

enable_bbr() {
    log "启用 BBR 拥塞控制..."

    # 检查是否已启用
    if lsmod | grep -q bbr; then
        warn "BBR 已启用"
        return
    fi

    # 检查内核版本
    local kernel_version=$(uname -r | cut -d. -f1-2)
    if [[ $(echo "$kernel_version >= 4.9" | bc) -eq 0 ]]; then
        error "内核版本过低，需要 4.9 以上才支持 BBR"
        return 1
    fi

    # 启用 BBR
    cat >> /etc/sysctl.conf << EOF

# BBR 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -p

    log "BBR 启用完成"
    sysctl net.ipv4.tcp_congestion_control
}

#===============================================================================
# 模块9: 安装基础工具
#===============================================================================

install_basic_tools() {
    log "安装基础工具..."

    apt install -y \
        git \
        wget \
        curl \
        vim \
        tmux \
        unzip \
        htop \
        btop \
        net-tools \
        dnsutils \
        tree \
        jq \
        ncdu \
        iftop \
        iotop

    log "基础工具安装完成"
}

#===============================================================================
# 辅助函数: 添加用户到 docker 组
#===============================================================================

add_user_to_docker_group() {
    # 列出可用的普通用户
    local users=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd)

    if [[ -z "$users" ]]; then
        warn "未找到普通用户，跳过 docker 组配置"
        return
    fi

    echo "可用的用户："
    echo "$users" | nl

    read -p "请输入要加入 docker 组的用户名 (直接回车跳过): " docker_user

    if [[ -z "$docker_user" ]]; then
        log "跳过 docker 组配置"
        return
    fi

    if ! id "$docker_user" &>/dev/null; then
        error "用户 $docker_user 不存在"
        return 1
    fi

    usermod -aG docker "$docker_user"
    log "已将用户 $docker_user 添加到 docker 组"
    warn "用户需要重新登录后才能免 sudo 使用 docker"
}

#===============================================================================
# 模块10: Docker 安装
#===============================================================================

install_docker() {
    log "安装 Docker..."

    # 检查是否已安装
    if command -v docker &>/dev/null; then
        warn "Docker 已安装"
        docker --version
        return
    fi

    # 安装依赖
    apt install -y ca-certificates curl gnupg

    # 添加 Docker GPG 密钥
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # 添加仓库
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    # 安装 Docker
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # 启动服务
    systemctl enable docker
    systemctl start docker

    # 添加用户到 docker 组
    add_user_to_docker_group

    log "Docker 安装完成"
    docker --version
    docker compose version
}

#===============================================================================
# 模块11: 一键全部配置
#===============================================================================

run_all() {
    log "开始执行全部配置..."

    update_system
    press_enter

    set_timezone
    press_enter

    configure_swap
    press_enter

    create_user
    press_enter

    configure_ssh
    press_enter

    configure_ufw
    press_enter

    install_fail2ban
    press_enter

    enable_bbr
    press_enter

    install_basic_tools
    press_enter

    install_docker

    log "全部配置完成！"
}

#===============================================================================
# 主菜单
#===============================================================================

show_menu() {
    clear
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              VPS 初始化配置脚本 v1.0                         ║"
    echo "║              适用于 Ubuntu/Debian 系统                       ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  1. 更新系统软件包                                           ║"
    echo "║  2. 设置时区 (Asia/Shanghai)                                 ║"
    echo "║  3. 配置 Swap                                                ║"
    echo "║  4. 创建新用户 (sudo)                                        ║"
    echo "║  5. SSH 安全配置 (端口/密钥认证)                             ║"
    echo "║  6. 配置 UFW 防火墙                                          ║"
    echo "║  7. 安装 Fail2ban                                            ║"
    echo "║  8. 启用 BBR 网络优化                                        ║"
    echo "║  9. 安装基础工具                                             ║"
    echo "║ 10. 安装 Docker                                              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  0. 一键执行全部配置                                         ║"
    echo "║  q. 退出                                                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main() {
    check_root
    check_os

    # 创建日志文件
    touch "$LOG_FILE"

    while true; do
        show_menu
        read -p "请选择操作 [0-10/q]: " choice

        case $choice in
            1) update_system; press_enter ;;
            2) set_timezone; press_enter ;;
            3) configure_swap; press_enter ;;
            4) create_user; press_enter ;;
            5) configure_ssh; press_enter ;;
            6) configure_ufw; press_enter ;;
            7) install_fail2ban; press_enter ;;
            8) enable_bbr; press_enter ;;
            9) install_basic_tools; press_enter ;;
            10) install_docker; press_enter ;;
            0) run_all; press_enter ;;
            q|Q) log "退出脚本"; exit 0 ;;
            *) error "无效选项"; press_enter ;;
        esac
    done
}

# 运行主程序
main "$@"
