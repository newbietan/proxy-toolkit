#!/bin/bash

# xray-setup: 极简 VLESS Reality 一键部署脚本
# 用法: bash xray-setup.sh [install|status|show|restart|uninstall|update]

set -e

# ==================== 常量 ====================
XRAY_DIR="/usr/local/bin"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_LOG="/var/log/xray"
SERVICE_NAME="xray"
GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
INSTALL_INFO="${XRAY_CONFIG_DIR}/install-info.conf"
PID_FILE="/var/run/xray.pid"

# ==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 工具函数 ====================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# 检测系统架构
get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64)   echo "64" ;;
        aarch64|arm64)   echo "arm64-v8a" ;;
        armv7l|armhf)    echo "arm32-v7a" ;;
        armv6l)          echo "arm32-v6" ;;
        s390x)           echo "s390x" ;;
        *)               log_error "不支持的架构: $arch"; exit 1 ;;
    esac
}

# 检测包管理器
get_pm() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v apk &>/dev/null; then
        echo "apk"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# 检测 init 系统
get_init_system() {
    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        echo "systemd"
    elif command -v rc-update &>/dev/null; then
        echo "openrc"
    elif [[ -f /etc/init.d/cron ]] && ! command -v systemctl &>/dev/null; then
        echo "sysvinit"
    else
        echo "other"
    fi
}

# 安装依赖
install_deps() {
    local pm=$(get_pm)
    log_info "安装依赖 (unzip curl jq)..."
    case $pm in
        apt)    apt-get update -qq && apt-get install -y -qq unzip curl jq ;;
        yum)    yum install -y -q unzip curl jq ;;
        dnf)    dnf install -y -q unzip curl jq ;;
        apk)    apk add --no-cache unzip curl jq ;;
        pacman) pacman -Sy --noconfirm unzip curl jq ;;
        *)      log_warn "未知包管理器，请确保已安装 unzip curl jq" ;;
    esac
}

# 检测端口占用并处理
check_port() {
    local port="${1:-443}"
    log_info "检查端口 ${port} 占用情况..."

    # 查找占用端口的进程
    local pid=""
    local process_name=""

    if command -v lsof &>/dev/null; then
        pid=$(lsof -ti:${port} 2>/dev/null | head -1)
    elif command -v ss &>/dev/null; then
        pid=$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
    elif command -v netstat &>/dev/null; then
        pid=$(netstat -tlnp 2>/dev/null | grep ":${port} " | awk '{print $7}' | cut -d'/' -f1 | head -1)
    fi

    if [[ -n "$pid" ]]; then
        process_name=$(ps -p ${pid} -o comm= 2>/dev/null || echo "unknown")
        log_warn "端口 ${port} 被进程 ${process_name} (PID: ${pid}) 占用"

        # 常见服务处理
        case "$process_name" in
            nginx|apache2|httpd|caddy|lighttpd)
                log_info "停止 ${process_name} 服务..."
                if command -v systemctl &>/dev/null; then
                    systemctl stop ${process_name} 2>/dev/null || true
                    systemctl disable ${process_name} 2>/dev/null || true
                elif command -v service &>/dev/null; then
                    service ${process_name} stop 2>/dev/null || true
                fi
                log_info "${process_name} 已停止"
                ;;
            xray)
                log_info "停止已运行的 Xray..."
                kill ${pid} 2>/dev/null || true
                sleep 1
                ;;
            *)
                read -p "是否终止进程 ${process_name} (PID: ${pid})? (y/N): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    kill ${pid} 2>/dev/null || true
                    sleep 1
                    log_info "进程已终止"
                else
                    log_error "端口 ${port} 被占用，请手动处理或修改配置使用其他端口"
                    exit 1
                fi
                ;;
        esac
    else
        log_info "端口 ${port} 可用"
    fi
}

# 生成 UUID
generate_uuid() {
    if [[ -f ${XRAY_DIR}/xray ]]; then
        ${XRAY_DIR}/xray uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || \
        python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
        echo "$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 8 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 12 | head -n 1)"
    fi
}

# 生成 x25519 密钥对
generate_keys() {
    ${XRAY_DIR}/xray x25519
}

# 生成 short_id
generate_short_id() {
    openssl rand -hex 8
}

# 选择部署模式
select_mode() {
    echo "" >&2
    echo -e "${CYAN}============================================${NC}" >&2
    echo -e "${GREEN}  选择部署模式${NC}" >&2
    echo -e "${CYAN}============================================${NC}" >&2
    echo "" >&2
    echo -e "  ${BLUE}1)${NC} 直连模式 (VLESS + Reality)" >&2
    echo -e "     - 速度快、延迟低、伪装强" >&2
    echo -e "     - 需要服务器 IP 稳定" >&2
    echo "" >&2
    echo -e "  ${BLUE}2)${NC} CDN 模式 (VLESS + WebSocket + Cloudflare)" >&2
    echo -e "     - 隐藏源站 IP、抗封锁" >&2
    echo -e "     - 速度稍慢、需要域名" >&2
    echo "" >&2
    echo -e "  ${BLUE}3)${NC} 双模式 (同时部署直连 + CDN)" >&2
    echo -e "     - 两种方式都支持" >&2
    echo -e "     - 推荐：主用直连，CDN 备用" >&2
    echo "" >&2
    echo -n "请选择模式 [1/2/3]: " >&2
    read mode_choice

    case "$mode_choice" in
        1) echo "direct" ;;
        2) echo "cdn" ;;
        3) echo "both" ;;
        *) echo "direct" ;;
    esac
}

# 获取域名（CDN 模式用）
get_domain() {
    echo "" >&2
    echo -e "${CYAN}--------------------------------------------${NC}" >&2
    echo -e "${GREEN}  CDN 模式配置${NC}" >&2
    echo -e "${CYAN}--------------------------------------------${NC}" >&2
    echo "" >&2
    echo -e "${YELLOW}请确保已完成以下步骤：${NC}" >&2
    echo -e "  1. 拥有一个域名（如 example.com）" >&2
    echo -e "  2. 域名 NS 已切换到 Cloudflare" >&2
    echo -e "  3. 在 Cloudflare 添加了 A 记录指向本机 IP" >&2
    echo "" >&2
    echo -n "请输入你的域名 (如 proxy.example.com): " >&2
    read domain

    if [[ -z "$domain" ]]; then
        log_error "域名不能为空" >&2
        exit 1
    fi

    echo "$domain"
}

# ==================== 服务管理 ====================

# 安装 systemd 服务
install_systemd_service() {
    log_info "安装 systemd 服务..."

    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_DIR}/xray run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    systemctl start ${SERVICE_NAME}

    log_info "systemd 服务启动完成"
}

# 安装 OpenRC 服务
install_openrc_service() {
    log_info "安装 OpenRC 服务..."

    cat > /etc/init.d/${SERVICE_NAME} <<'SCRIPT'
#!/sbin/openrc-run

name="xray"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background=true
pidfile="/var/run/${RC_SVCNAME}.pid"
start_stop_daemon_args="--background --make-pidfile"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory /var/run
}
SCRIPT

    chmod +x /etc/init.d/${SERVICE_NAME}
    rc-update add ${SERVICE_NAME} default 2>/dev/null || true
    rc-service ${SERVICE_NAME} start

    log_info "OpenRC 服务启动完成"
}

# 使用 nohup 启动（兼容方案）
install_nohup_service() {
    log_info "使用 nohup 启动服务..."

    nohup ${XRAY_DIR}/xray run -config ${XRAY_CONFIG} > ${XRAY_LOG}/xray.log 2>&1 &
    echo $! > ${PID_FILE}

    log_info "服务已启动 (PID: $(cat ${PID_FILE}))"

    # 创建启动脚本
    cat > /usr/local/bin/xray-start <<EOF
#!/bin/bash
nohup ${XRAY_DIR}/xray run -config ${XRAY_CONFIG} > ${XRAY_LOG}/xray.log 2>&1 &
echo \$! > ${PID_FILE}
echo "Xray started (PID: \$(cat ${PID_FILE}))"
EOF

    cat > /usr/local/bin/xray-stop <<EOF
#!/bin/bash
if [[ -f ${PID_FILE} ]]; then
    kill \$(cat ${PID_FILE}) 2>/dev/null
    rm -f ${PID_FILE}
    echo "Xray stopped"
else
    echo "Xray is not running"
fi
EOF

    chmod +x /usr/local/bin/xray-start /usr/local/bin/xray-stop

    # 添加到 rc.local 开机启动
    if [[ -f /etc/rc.local ]]; then
        if ! grep -q "xray-start" /etc/rc.local; then
            sed -i '/^exit 0/i \/usr/local/bin/xray-start' /etc/rc.local
        fi
    fi
}

# 安装服务（自动选择）
install_service() {
    local init_system=$(get_init_system)
    log_info "检测到 init 系统: ${init_system}"

    case ${init_system} in
        systemd)
            install_systemd_service
            ;;
        openrc)
            install_openrc_service
            ;;
        *)
            install_nohup_service
            ;;
    esac
}

# 停止服务
stop_service() {
    local init_system=$(get_init_system)

    case ${init_system} in
        systemd)
            systemctl stop ${SERVICE_NAME} 2>/dev/null || true
            ;;
        openrc)
            rc-service ${SERVICE_NAME} stop 2>/dev/null || true
            ;;
        *)
            if [[ -f ${PID_FILE} ]]; then
                kill $(cat ${PID_FILE}) 2>/dev/null || true
                rm -f ${PID_FILE}
            fi
            ;;
    esac
}

# 启动服务
start_service() {
    local init_system=$(get_init_system)

    case ${init_system} in
        systemd)
            systemctl start ${SERVICE_NAME} 2>/dev/null || true
            ;;
        openrc)
            rc-service ${SERVICE_NAME} start 2>/dev/null || true
            ;;
        *)
            nohup ${XRAY_DIR}/xray run -config ${XRAY_CONFIG} > ${XRAY_LOG}/xray.log 2>&1 &
            echo $! > ${PID_FILE}
            ;;
    esac
}

# 检查服务状态
is_running() {
    local init_system=$(get_init_system)

    case ${init_system} in
        systemd)
            systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null
            ;;
        openrc)
            rc-service ${SERVICE_NAME} status 2>/dev/null | grep -q "started"
            ;;
        *)
            if [[ -f ${PID_FILE} ]]; then
                kill -0 $(cat ${PID_FILE}) 2>/dev/null
            else
                return 1
            fi
            ;;
    esac
}

# ==================== 系统优化 ====================

# 开启 BBR
enable_bbr() {
    log_info "配置 BBR 拥塞控制..."

    # 检查内核版本
    local kernel_ver=$(uname -r | cut -d. -f1,2)
    local major=$(echo $kernel_ver | cut -d. -f1)
    local minor=$(echo $kernel_ver | cut -d. -f2)

    if [[ $major -lt 4 ]] || [[ $major -eq 4 && $minor -lt 9 ]]; then
        log_warn "内核版本 ${kernel_ver} 不支持 BBR，需要 >= 4.9"
        return 1
    fi

    # 检查当前状态
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        log_info "BBR 已启用"
        return 0
    fi

    # 检查 BBR 模块是否可用
    if ! modprobe tcp_bbr 2>/dev/null; then
        log_warn "BBR 模块不可用"
        return 1
    fi

    # 配置 BBR
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1

    # 验证
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        log_info "BBR 启用成功"
        return 0
    else
        log_warn "BBR 启用失败"
        return 1
    fi
}

# 开启 ICMP (允许 ping)
enable_icmp() {
    log_info "配置 ICMP (允许 ping)..."

    local current=$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null)
    if [[ "$current" == "0" ]]; then
        log_info "ICMP 已启用"
        return 0
    fi

    # 开启 ICMP
    echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all

    # 持久化
    cat > /etc/sysctl.d/99-icmp.conf <<EOF
net.ipv4.icmp_echo_ignore_all = 0
EOF

    sysctl -p /etc/sysctl.d/99-icmp.conf >/dev/null 2>&1

    log_info "ICMP 启用成功"
    return 0
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙..."

    # 检测防火墙类型
    if command -v ufw &>/dev/null; then
        # Ubuntu/Debian ufw
        log_info "检测到 ufw 防火墙"
        ufw allow 22/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
        log_info "ufw 已放行 22 和 443 端口"
    elif command -v firewall-cmd &>/dev/null; then
        # CentOS/RHEL firewalld
        log_info "检测到 firewalld 防火墙"
        firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_info "firewalld 已放行 22 和 443 端口"
    elif command -v iptables &>/dev/null; then
        # 通用 iptables
        log_info "检测到 iptables 防火墙"
        iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport 22 -j ACCEPT
        iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport 443 -j ACCEPT
        # 尝试持久化
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        fi
        log_info "iptables 已放行 22 和 443 端口"
    else
        log_warn "未检测到防火墙，跳过配置"
    fi

    return 0
}

# ==================== 核心功能 ====================

# 安装 Xray-core
install_xray() {
    log_info "检测系统架构..."
    local arch=$(get_arch)
    log_info "架构: ${arch}"

    # 获取最新版本
    log_info "获取最新版本信息..."
    local latest_ver=$(curl -s ${GITHUB_API} | grep '"tag_name"' | head -1 | awk -F '"' '{print $4}')
    if [[ -z "$latest_ver" ]]; then
        log_warn "获取版本失败，使用默认版本 v25.6.8"
        latest_ver="v25.6.8"
    fi
    log_info "最新版本: ${latest_ver}"

    # 下载
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_ver}/Xray-linux-${arch}.zip"
    log_info "下载: ${download_url}"

    local tmp_dir=$(mktemp -d)
    curl -L -o "${tmp_dir}/xray.zip" "${download_url}" || {
        log_error "下载失败，请检查网络连接或使用代理"
        rm -rf "${tmp_dir}"
        exit 1
    }

    # 安装
    log_info "安装 Xray-core..."
    unzip -o "${tmp_dir}/xray.zip" -d "${tmp_dir}" >/dev/null
    mv -f "${tmp_dir}/xray" "${XRAY_DIR}/xray"
    chmod +x "${XRAY_DIR}/xray"
    rm -rf "${tmp_dir}"

    log_info "Xray-core ${latest_ver} 安装完成"
    mkdir -p "${XRAY_CONFIG_DIR}"
    echo "$latest_ver" > "${XRAY_CONFIG_DIR}/version.txt" 2>/dev/null || true
}

# 生成配置
generate_config() {
    local mode="${1:-direct}"
    local domain="${2:-}"

    log_info "生成配置..."

    mkdir -p "${XRAY_CONFIG_DIR}"
    mkdir -p "${XRAY_LOG}"

    # 生成密钥
    local uuid=$(generate_uuid)
    local keys=$(generate_keys)
    local private_key=$(echo "$keys" | grep "Private" | awk '{print $NF}')
    local public_key=$(echo "$keys" | grep "Public" | awk '{print $NF}')
    local short_id=$(generate_short_id)

    # 获取服务器 IP
    local server_ip=$(curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
                      curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                      curl -s4 --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null)
    if [[ -z "$server_ip" ]]; then
        server_ip="<YOUR_SERVER_IP>"
        log_warn "无法自动获取服务器 IP，请手动替换配置中的 <YOUR_SERVER_IP>"
    fi

    # 根据模式生成配置
    local inbounds=""

    # 直连模式 (Reality)
    if [[ "$mode" == "direct" || "$mode" == "both" ]]; then
        inbounds="${inbounds}
        {
            \"listen\": \"0.0.0.0\",
            \"port\": 443,
            \"protocol\": \"vless\",
            \"settings\": {
                \"clients\": [
                    {
                        \"id\": \"${uuid}\",
                        \"flow\": \"xtls-rprx-vision\"
                    }
                ],
                \"decryption\": \"none\"
            },
            \"streamSettings\": {
                \"network\": \"tcp\",
                \"security\": \"reality\",
                \"realitySettings\": {
                    \"show\": false,
                    \"dest\": \"www.microsoft.com:443\",
                    \"xver\": 0,
                    \"serverNames\": [
                        \"www.microsoft.com\"
                    ],
                    \"privateKey\": \"${private_key}\",
                    \"shortIds\": [
                        \"${short_id}\"
                    ]
                }
            },
            \"sniffing\": {
                \"enabled\": true,
                \"destOverride\": [
                    \"http\",
                    \"tls\",
                    \"quic\"
                ]
            }
        }"
    fi

    # CDN 模式 (WebSocket)
    if [[ "$mode" == "cdn" || "$mode" == "both" ]]; then
        local ws_port=8080
        if [[ "$mode" == "cdn" ]]; then
            ws_port=443
        fi

        if [[ -n "$inbounds" ]]; then
            inbounds="${inbounds},"
        fi

        inbounds="${inbounds}
        {
            \"listen\": \"127.0.0.1\",
            \"port\": ${ws_port},
            \"protocol\": \"vless\",
            \"settings\": {
                \"clients\": [
                    {
                        \"id\": \"${uuid}\"
                    }
                ],
                \"decryption\": \"none\"
            },
            \"streamSettings\": {
                \"network\": \"ws\",
                \"wsSettings\": {
                    \"path\": \"/vless\"
                }
            },
            \"sniffing\": {
                \"enabled\": true,
                \"destOverride\": [
                    \"http\",
                    \"tls\",
                    \"quic\"
                ]
            }
        }"
    fi

    # 生成配置文件
    cat > "${XRAY_CONFIG}" <<EOF
{
    "log": {
        "loglevel": "warning",
        "access": "${XRAY_LOG}/access.log",
        "error": "${XRAY_LOG}/error.log"
    },
    "inbounds": [
        ${inbounds}
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "blocked"
        }
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "outboundTag": "blocked",
                "protocol": ["bittorrent"]
            }
        ]
    }
}
EOF

    # 保存安装信息
    cat > "${INSTALL_INFO}" <<EOF
DEPLOY_MODE=${mode}
UUID=${uuid}
PRIVATE_KEY=${private_key}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
SERVER_IP=${server_ip}
SNI=www.microsoft.com
DOMAIN=${domain}
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

    log_info "配置生成完成"
}

# 卸载
uninstall_xray() {
    log_warn "即将卸载 Xray-core..."
    read -p "确认卸载? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "取消卸载"
        return
    fi

    # 停止服务
    stop_service

    # 删除服务文件
    local init_system=$(get_init_system)
    case ${init_system} in
        systemd)
            rm -f /etc/systemd/system/${SERVICE_NAME}.service
            systemctl daemon-reload 2>/dev/null || true
            ;;
        openrc)
            rc-update del ${SERVICE_NAME} 2>/dev/null || true
            rm -f /etc/init.d/${SERVICE_NAME}
            ;;
        *)
            rm -f /usr/local/bin/xray-start /usr/local/bin/xray-stop
            rm -f ${PID_FILE}
            ;;
    esac

    # 删除文件
    rm -f ${XRAY_DIR}/xray
    rm -rf ${XRAY_CONFIG_DIR}
    rm -rf ${XRAY_LOG}

    log_info "卸载完成"
}

# 更新
update_xray() {
    if [[ ! -f ${XRAY_DIR}/xray ]]; then
        log_error "Xray-core 未安装"
        exit 1
    fi

    local current_ver=$(${XRAY_DIR}/xray version 2>/dev/null | head -1 | awk '{print $2}')
    local latest_ver=$(curl -s ${GITHUB_API} | grep '"tag_name"' | head -1 | awk -F '"' '{print $4}')

    log_info "当前版本: ${current_ver}"
    log_info "最新版本: ${latest_ver}"

    if [[ "$current_ver" == "$latest_ver" ]]; then
        log_info "已是最新版本"
        return
    fi

    log_info "更新中..."
    stop_service
    install_xray
    start_service
    log_info "更新完成"
}

# 查看状态
show_status() {
    echo ""
    echo -e "${CYAN}========== Xray 服务状态 ==========${NC}"

    local init_system=$(get_init_system)
    log_info "Init 系统: ${init_system}"

    if is_running; then
        echo -e "  状态: ${GREEN}运行中${NC}"
    else
        echo -e "  状态: ${RED}未运行${NC}"
    fi

    if [[ -f "${XRAY_CONFIG_DIR}/version.txt" ]]; then
        echo -e "  版本: $(cat ${XRAY_CONFIG_DIR}/version.txt)"
    fi

    if [[ -f "${INSTALL_INFO}" ]]; then
        source "${INSTALL_INFO}"
        echo -e "  安装时间: ${INSTALL_DATE}"
    fi

    echo ""
}

# 显示连接信息
show_info() {
    if [[ ! -f "${INSTALL_INFO}" ]]; then
        log_error "未找到安装信息，请先安装"
        exit 1
    fi

    source "${INSTALL_INFO}"
    local mode="${DEPLOY_MODE:-direct}"

    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${GREEN}  Xray VLESS 节点信息${NC}"
    echo -e "${CYAN}============================================${NC}"

    # 直连模式信息
    if [[ "$mode" == "direct" || "$mode" == "both" ]]; then
        local reality_link="vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Xray-Reality"

        echo ""
        echo -e "${GREEN}[直连模式 - VLESS + Reality]${NC}"
        echo ""
        echo -e "  ${BLUE}地址:${NC}   ${SERVER_IP}"
        echo -e "  ${BLUE}端口:${NC}   443"
        echo -e "  ${BLUE}UUID:${NC}   ${UUID}"
        echo -e "  ${BLUE}密钥:${NC}   ${PUBLIC_KEY}"
        echo -e "  ${BLUE}SNI:${NC}    ${SNI}"
        echo -e "  ${BLUE}Flow:${NC}   xtls-rprx-vision"
        echo -e "  ${BLUE}SID:${NC}    ${SHORT_ID}"
        echo ""
        echo -e "${CYAN}--------------------------------------------${NC}"
        echo -e "${GREEN}直连分享链接:${NC}"
        echo ""
        echo -e "${reality_link}"
        echo ""

        # 生成二维码（如果 qrencode 可用）
        if command -v qrencode &>/dev/null; then
            echo -e "${CYAN}--------------------------------------------${NC}"
            echo -e "${GREEN}直连二维码:${NC}"
            echo ""
            qrencode -t ANSIUTF8 "${reality_link}"
        fi
    fi

    # CDN 模式信息
    if [[ "$mode" == "cdn" || "$mode" == "both" ]]; then
        local cdn_address="${DOMAIN:-<YOUR_DOMAIN>}"
        local ws_port=443
        if [[ "$mode" == "both" ]]; then
            ws_port=8080
        fi
        local ws_link="vless://${UUID}@${cdn_address}:443?encryption=none&security=tls&sni=${cdn_address}&fp=chrome&type=ws&host=${cdn_address}&path=%2Fvless#Xray-CDN"

        echo ""
        echo -e "${GREEN}[CDN 模式 - VLESS + WebSocket + Cloudflare]${NC}"
        echo ""
        echo -e "  ${BLUE}地址:${NC}   ${cdn_address}"
        echo -e "  ${BLUE}端口:${NC}   443"
        echo -e "  ${BLUE}UUID:${NC}   ${UUID}"
        echo -e "  ${BLUE}传输:${NC}   ws"
        echo -e "  ${BLUE}路径:${NC}   /vless"
        echo -e "  ${BLUE}TLS:${NC}    开启"
        echo -e "  ${BLUE}SNI:${NC}    ${cdn_address}"
        echo ""
        echo -e "${YELLOW}Cloudflare 配置:${NC}"
        echo -e "  1. 添加 A 记录指向 ${SERVER_IP}"
        echo -e "  2. 开启橙色云朵（代理）"
        echo -e "  3. SSL/TLS 设置为 Full"
        if [[ "$mode" == "both" ]]; then
            echo -e "  4. 回源端口: ${ws_port}"
        fi
        echo ""
        echo -e "${CYAN}--------------------------------------------${NC}"
        echo -e "${GREEN}CDN 分享链接:${NC}"
        echo ""
        echo -e "${ws_link}"
        echo ""

        # 生成二维码（如果 qrencode 可用）
        if command -v qrencode &>/dev/null; then
            echo -e "${CYAN}--------------------------------------------${NC}"
            echo -e "${GREEN}CDN 二维码:${NC}"
            echo ""
            qrencode -t ANSIUTF8 "${ws_link}"
        fi
    fi

    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${YELLOW}提示: 安装 qrencode 可显示二维码${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
}

# 重启服务
restart_service() {
    log_info "重启 Xray 服务..."
    stop_service
    sleep 1
    start_service
    log_info "重启完成"
}

# ==================== 主流程 ====================

show_usage() {
    echo ""
    echo -e "${CYAN}xray-setup${NC} - 极简 VLESS 一键部署"
    echo ""
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  install     安装 Xray-core 并生成配置"
    echo "              支持三种模式："
    echo "                1. 直连模式 (VLESS + Reality)"
    echo "                2. CDN 模式 (VLESS + WebSocket + Cloudflare)"
    echo "                3. 双模式 (同时部署直连 + CDN)"
    echo "  uninstall   卸载 Xray-core"
    echo "  status      查看服务状态"
    echo "  show        显示节点信息和分享链接"
    echo "  restart     重启服务"
    echo "  update      更新 Xray-core"
    echo "  bbr         开启 BBR 拥塞控制"
    echo "  icmp        开启 ICMP (允许 ping)"
    echo "  help        显示此帮助信息"
    echo ""
}

main() {
    local cmd="${1:-help}"

    case "$cmd" in
        install)
            check_root
            echo ""
            echo -e "${CYAN}============================================${NC}"
            echo -e "${GREEN}  Xray VLESS 一键安装${NC}"
            echo -e "${CYAN}============================================${NC}"
            echo ""

            # 选择部署模式
            local mode=$(select_mode)
            local domain=""

            # CDN 模式需要域名
            if [[ "$mode" == "cdn" || "$mode" == "both" ]]; then
                domain=$(get_domain)
            fi

            install_deps
            enable_bbr
            enable_icmp

            # 检查端口
            check_port 443
            if [[ "$mode" == "both" ]]; then
                check_port 8080
            fi

            install_xray
            generate_config "$mode" "$domain"
            install_service
            configure_firewall
            show_info
            ;;
        bbr)
            check_root
            enable_bbr
            ;;
        icmp)
            check_root
            enable_icmp
            ;;
        uninstall)
            check_root
            uninstall_xray
            ;;
        status)
            show_status
            ;;
        show)
            show_info
            ;;
        restart)
            check_root
            restart_service
            ;;
        update)
            check_root
            update_xray
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "未知命令: $cmd"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
