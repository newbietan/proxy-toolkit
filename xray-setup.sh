#!/bin/bash

# xray-setup: 极简 VLESS 一键部署脚本
# 用法: bash xray-setup.sh [install|status|show|restart|uninstall|update]

# ==================== 常量 ====================
XRAY_DIR="/usr/local/bin"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_LOG="/var/log/xray"
SERVICE_NAME="xray"
GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
GITHUB_LATEST_URL="https://github.com/XTLS/Xray-core/releases/latest"
INSTALL_INFO="${XRAY_CONFIG_DIR}/install-info.conf"
PID_FILE="/var/run/xray.pid"

HYSTERIA_DIR="/usr/local/bin"
HYSTERIA_CONFIG_DIR="/etc/hysteria"
HYSTERIA_CONFIG="${HYSTERIA_CONFIG_DIR}/config.yaml"
HYSTERIA_LOG="/var/log/hysteria"
HYSTERIA_SERVICE_NAME="hysteria-server"
HYSTERIA_PID_FILE="/var/run/hysteria.pid"
HYSTERIA_GITHUB_API="https://api.github.com/repos/apernet/hysteria/releases/latest"
HYSTERIA_LATEST_URL="https://github.com/apernet/hysteria/releases/latest"

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

# JSON 字符串转义（纯 bash 实现，不依赖 jq，兼容 Alpine/busybox）
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    printf '%s' "$s"
}

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
    x86_64 | amd64) echo "64" ;;
    aarch64 | arm64) echo "arm64-v8a" ;;
    armv7l | armhf) echo "arm32-v7a" ;;
    armv6l) echo "arm32-v6" ;;
    s390x) echo "s390x" ;;
    *)
        log_error "不支持的架构: $arch"
        exit 1
        ;;
    esac
}

# 检测 Hysteria 系统架构
get_hysteria_arch() {
    local arch=$(uname -m)
    case $arch in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    armv7l | armhf) echo "arm" ;;
    s390x) echo "s390x" ;;
    *)
        log_error "Hysteria 2 不支持的系统架构: $arch"
        exit 1
        ;;
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

# 确保 Alpine community 仓库已启用（qrencode 位于 community 仓库）
ensure_alpine_community_repo() {
    if grep -q "community" /etc/apk/repositories 2>/dev/null; then
        return 0
    fi

    local ver=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1,2)
    if [[ -z "$ver" ]]; then
        ver=$(awk -F. '/^[0-9]+\.[0-9]+/{print $1"."$2; exit}' /etc/os-release 2>/dev/null)
    fi

    if [[ -n "$ver" ]]; then
        echo "https://dl-cdn.alpinelinux.org/alpine/v${ver}/community" >>/etc/apk/repositories
        apk update >/dev/null 2>&1 || true
        log_info "已启用 Alpine community 仓库 (v${ver})"
    else
        log_warn "无法确定 Alpine 版本，跳过 community 仓库配置"
    fi
}

# 安装软件包
# apk 逐个安装：避免某个包（如 qrencode）安装失败导致 jq 等必需包整体失败
install_packages() {
    local pm="$1"
    shift
    local pkgs="$*"

    case $pm in
    apt) apt-get update -qq && apt-get install -y -qq $pkgs ;;
    yum) yum install -y -q $pkgs ;;
    dnf) dnf install -y -q $pkgs ;;
    apk)
        for p in $pkgs; do
            if ! apk add --no-cache "$p" >/dev/null 2>&1; then
                log_warn "依赖安装失败: ${p}"
            fi
        done
        ;;
    pacman) pacman -Sy --noconfirm $pkgs ;;
    *) log_warn "未知包管理器，请确保已安装:${pkgs}" ;;
    esac
}

# 安装依赖
install_deps() {
    local pm=$(get_pm)

    # Alpine: 启用 community 仓库（qrencode 在 community 中）
    if [[ "$pm" == "apk" ]]; then
        ensure_alpine_community_repo
    fi

    # 逐个检查并安装缺失依赖
    local pkgs=""
    command -v unzip &>/dev/null || pkgs="$pkgs unzip"
    command -v curl &>/dev/null || pkgs="$pkgs curl"
    command -v jq &>/dev/null || pkgs="$pkgs jq"
    command -v openssl &>/dev/null || pkgs="$pkgs openssl"
    command -v qrencode &>/dev/null || pkgs="$pkgs qrencode"

    if [[ -z "$pkgs" ]]; then
        log_info "依赖已就绪"
    else
        log_info "安装缺失依赖:${pkgs}..."
        install_packages "$pm" "$pkgs"
    fi

    # 验证关键依赖（unzip/curl/openssl 必需；jq/qrencode 可选）
    local critical_missing=""
    command -v unzip &>/dev/null || critical_missing="$critical_missing unzip"
    command -v curl &>/dev/null || critical_missing="$critical_missing curl"
    command -v openssl &>/dev/null || critical_missing="$critical_missing openssl"
    if [[ -n "$critical_missing" ]]; then
        log_error "关键依赖安装失败:${critical_missing}"
        log_error "请检查网络连接和软件源配置后重试"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        log_warn "jq 不可用，配置将使用内置生成逻辑（不依赖 jq）"
    fi

    # 安装端口检测工具
    install_port_tools

    # 安装防火墙
    install_firewall
}

# 安装端口检测工具
install_port_tools() {
    local pm=$(get_pm)
    case $pm in
    apt) apt-get install -y -qq iproute2 net-tools lsof >/dev/null 2>&1 || true ;;
    yum) yum install -y -q iproute net-tools lsof >/dev/null 2>&1 || true ;;
    dnf) dnf install -y -q iproute net-tools lsof >/dev/null 2>&1 || true ;;
    apk) apk add --no-cache iproute2 net-tools lsof >/dev/null 2>&1 || true ;;
    pacman) pacman -Sy --noconfirm iproute2 net-tools lsof >/dev/null 2>&1 || true ;;
    esac
}

# 安装防火墙
install_firewall() {
    # 已有防火墙则跳过
    if command -v ufw &>/dev/null || command -v firewall-cmd &>/dev/null || command -v iptables &>/dev/null; then
        return 0
    fi

    local pm=$(get_pm)
    log_info "未检测到防火墙，正在安装..."
    case $pm in
    apt) apt-get install -y -qq ufw >/dev/null 2>&1 ;;
    yum) yum install -y -q firewalld >/dev/null 2>&1 ;;
    dnf) dnf install -y -q firewalld >/dev/null 2>&1 ;;
    apk) apk add --no-cache iptables >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm ufw >/dev/null 2>&1 ;;
    *) log_warn "未知包管理器，请手动安装防火墙" ;;
    esac

    # 验证安装结果
    if ! command -v ufw &>/dev/null && ! command -v firewall-cmd &>/dev/null && ! command -v iptables &>/dev/null; then
        log_warn "防火墙安装失败，请手动安装"
    fi
}

# 检测端口占用并处理
check_port() {
    local port="${1:-443}"
    local proto="${2:-tcp}"
    log_info "检查端口 ${port}/${proto} 占用情况..."

    local pid=""
    local process_name=""

    if [[ "$proto" == "udp" ]]; then
        # UDP 检查
        if command -v lsof &>/dev/null; then
            pid=$(lsof -tiUDP:${port} 2>/dev/null | grep -v "^1$" | head -1)
        elif command -v ss &>/dev/null; then
            local ss_output=$(ss -ulnp 2>/dev/null | grep ":${port} " || true)
            if [[ -n "$ss_output" ]]; then
                pid=$(echo "$ss_output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | grep -v "^1$" | head -1)
            fi
        elif command -v netstat &>/dev/null; then
            pid=$(netstat -ulnp 2>/dev/null | grep ":${port} " | awk '{print $7}' | cut -d'/' -f1 | grep -v "^1$" | head -1)
        fi
        if [[ -z "$pid" ]] && command -v fuser &>/dev/null; then
            pid=$(fuser "${port}/udp" 2>/dev/null | tr -d ' ' | grep -v "^1$" | head -1)
        fi
    else
        # TCP 检查
        if command -v lsof &>/dev/null; then
            pid=$(lsof -tiTCP:${port} -sTCP:LISTEN 2>/dev/null | grep -v "^1$" | head -1)
            [[ -z "$pid" ]] && pid=$(lsof -ti:${port} 2>/dev/null | grep -v "^1$" | head -1)
        elif command -v ss &>/dev/null; then
            local ss_output=$(ss -tlnp 2>/dev/null | grep ":${port} " || true)
            if [[ -n "$ss_output" ]]; then
                pid=$(echo "$ss_output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | grep -v "^1$" | head -1)
            fi
        elif command -v netstat &>/dev/null; then
            pid=$(netstat -tlnp 2>/dev/null | grep ":${port} " | awk '{print $7}' | cut -d'/' -f1 | grep -v "^1$" | head -1)
        fi
        if [[ -z "$pid" ]] && command -v fuser &>/dev/null; then
            pid=$(fuser "${port}/tcp" 2>/dev/null | tr -d ' ' | grep -v "^1$" | head -1)
        fi
        if [[ -z "$pid" ]] && command -v nc &>/dev/null; then
            if nc -z -w1 127.0.0.1 "${port}" 2>/dev/null; then
                log_warn "端口 ${port} 已被占用，但无法获取占用进程信息"
                log_error "请手动检查端口占用: lsof -i:${port} 或 ss -tlnp | grep :${port}"
                exit 1
            fi
        fi
    fi

    if [[ -n "$pid" ]]; then
        process_name=$(ps -p ${pid} -o comm= 2>/dev/null || echo "unknown")
        log_warn "端口 ${port}/${proto} 被进程 ${process_name} (PID: ${pid}) 占用"

        case "$process_name" in
        nginx | apache2 | httpd | caddy | lighttpd)
            log_info "停止 ${process_name} 服务..."
            if command -v systemctl &>/dev/null; then
                systemctl stop ${process_name} 2>/dev/null || true
                systemctl disable ${process_name} 2>/dev/null || true
            elif command -v service &>/dev/null; then
                service ${process_name} stop 2>/dev/null || true
            fi
            log_info "${process_name} 已停止"
            ;;
        xray | hysteria)
            log_info "停止已运行的 ${process_name}..."
            kill ${pid} 2>/dev/null || true
            sleep 1
            ;;
        *)
            read -r -p "是否终止进程 ${process_name} (PID: ${pid})? (y/N): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                kill ${pid} 2>/dev/null || true
                sleep 1
                log_info "进程已终止"
            else
                log_error "端口 ${port}/${proto} 被占用，请手动处理或修改配置使用其他端口"
                exit 1
            fi
            ;;
        esac
    else
        log_info "端口 ${port}/${proto} 可用"
    fi
}

# 生成 UUID
generate_uuid() {
    if [[ -f ${XRAY_DIR}/xray ]]; then
        ${XRAY_DIR}/xray uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null ||
            python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null ||
            echo "$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 8 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 12 | head -n 1)"
    fi
}

# 生成 x25519 密钥对
generate_keys() {
    ${XRAY_DIR}/xray x25519
}

# 生成 short_id
generate_short_id() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 8
    else
        cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 16 | head -n 1
    fi
}

# 获取 Cloudflare Origin 证书内容
get_cert_content() {
    local domain="$1"
    local cert_dir="${XRAY_CONFIG_DIR}/certs"

    mkdir -p "${cert_dir}"

    echo "" >&2
    echo -e "${CYAN}--------------------------------------------${NC}" >&2
    echo -e "${GREEN}  配置 TLS 证书${NC}" >&2
    echo -e "${CYAN}--------------------------------------------${NC}" >&2
    echo "" >&2
    echo -e "${YELLOW}请先申请 Cloudflare Origin 证书：${NC}" >&2
    echo "" >&2
    echo -e "  1. 登录 Cloudflare Dashboard" >&2
    echo -e "  2. 进入域名 → SSL/TLS → 源服务器" >&2
    echo -e "  3. 点击「创建证书」" >&2
    echo -e "  4. 保持默认设置，点击「创建」" >&2
    echo -e "  5. 复制证书和私钥内容" >&2
    echo "" >&2
    echo -e "${CYAN}--------------------------------------------${NC}" >&2
    echo "" >&2

    # 获取证书内容
    echo -e "${GREEN}请粘贴证书内容（以 -----BEGIN CERTIFICATE----- 开头）：${NC}" >&2
    echo -e "${YELLOW}输入完成后按 Ctrl+D 结束${NC}" >&2
    echo "" >&2
    cert_content=$(cat)

    if [[ -z "$cert_content" ]]; then
        log_error "证书内容不能为空" >&2
        exit 1
    fi

    # 保存证书
    echo "$cert_content" >"${cert_dir}/cert.pem"
    log_info "证书已保存到 ${cert_dir}/cert.pem" >&2

    echo "" >&2
    echo -e "${GREEN}请粘贴私钥内容（以 -----BEGIN PRIVATE KEY----- 开头）：${NC}" >&2
    echo -e "${YELLOW}输入完成后按 Ctrl+D 结束${NC}" >&2
    echo "" >&2
    key_content=$(cat)

    if [[ -z "$key_content" ]]; then
        log_error "私钥内容不能为空" >&2
        exit 1
    fi

    # 保存私钥
    echo "$key_content" >"${cert_dir}/private.key"
    log_info "私钥已保存到 ${cert_dir}/private.key" >&2

    echo "${cert_dir}/cert.pem|${cert_dir}/private.key"
}

# 选择部署模式
select_mode() {
    echo "" >&2
    echo -e "${CYAN}============================================${NC}" >&2
    echo -e "${GREEN}  选择部署模式${NC}" >&2
    echo -e "${CYAN}============================================${NC}" >&2
    echo "" >&2
    echo -e "  ${BLUE}1)${NC} 直连模式 (VLESS + Reality) - TCP" >&2
    echo -e "     - 速度快、延迟低、伪装强、无需域名" >&2
    echo -e "     - 默认监听标准 HTTPS 端口 443 (可自定义)" >&2
    echo "" >&2
    echo -e "  ${BLUE}2)${NC} 极速抗封锁模式 (Hysteria 2) - UDP" >&2
    echo -e "     - 基于魔改 QUIC，暴力抗丢包，弱网加速效果拔群" >&2
    echo -e "     - 支持端口跳跃 (Port Hopping)，有效突破单一 UDP 端口封锁与限速" >&2
    echo -e "     - 自动签发伪装证书，无需域名" >&2
    echo "" >&2
    echo -e "  ${BLUE}3)${NC} CDN 模式 (VLESS + XHTTP + Cloudflare)" >&2
    echo -e "     - 隐藏源站 IP、抗封锁兜底" >&2
    echo -e "     - 需自备域名并接入 Cloudflare CDN" >&2
    echo "" >&2
    echo -n "请选择模式 [1/2/3, 默认 1]: " >&2
    read -r mode_choice

    case "$mode_choice" in
    1) echo "direct" ;;
    2) echo "hysteria" ;;
    3) echo "cdn" ;;
    *) echo "direct" ;;
    esac
}

# 获取服务器公网 IPv4
get_server_ip() {
    local ip=""
    ip=$(curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null ||
        curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
        curl -s4 --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip="<YOUR_SERVER_IP>"
        log_warn "无法自动获取服务器 IPv4，请手动替换配置中的 <YOUR_SERVER_IP>" >&2
    fi
    echo "$ip"
}

# 获取 Hysteria 2 配置参数
get_hysteria_settings() {
    echo "" >&2
    echo -e "${CYAN}--------------------------------------------${NC}" >&2
    echo -e "${GREEN}  Hysteria 2 节点配置${NC}" >&2
    echo -e "${CYAN}--------------------------------------------${NC}" >&2

    # 1. 端口设置
    local port=""
    while true; do
        echo -n "请输入 Hysteria 2 监听端口 [默认: 8443]: " >&2
        read -r port
        port="${port:-8443}"
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            break
        else
            log_warn "端口无效，请输入 1-65535 之间的数字" >&2
        fi
    done

    # 2. 端口跳跃
    local enable_hop="false"
    local hop_start=""
    local hop_end=""
    echo "" >&2
    echo -e "${YELLOW}端口跳跃 (Port Hopping) 说明:${NC}" >&2
    echo -e "  通过将大范围 UDP 端口转发至主端口，客户端可在多个端口间跳跃，" >&2
    echo -e "  能有效瓦解运营商针对单一 UDP 端口的 QoS 限速与阻断。" >&2
    echo -n "是否启用端口跳跃? (Y/n) [默认: Y]: " >&2
    read -r hop_choice
    hop_choice="${hop_choice:-Y}"

    if [[ "$hop_choice" == "y" || "$hop_choice" == "Y" ]]; then
        enable_hop="true"
        while true; do
            echo -n "请输入端口跳跃范围 [默认: 20000-50000]: " >&2
            read -r hop_range
            hop_range="${hop_range:-20000-50000}"
            if [[ "$hop_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                hop_start="${BASH_REMATCH[1]}"
                hop_end="${BASH_REMATCH[2]}"
                if [ "$hop_start" -ge 1 ] && [ "$hop_end" -le 65535 ] && [ "$hop_start" -lt "$hop_end" ]; then
                    break
                fi
            fi
            log_warn "端口范围格式有误，格式应为 起始端口-结束端口 (如 20000-50000)" >&2
        done
    fi

    # 3. 密码设置
    echo "" >&2
    echo -n "请输入认证密码 [直接回车随机生成]: " >&2
    read -r password
    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 16 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
        [[ -z "$password" ]] && password=$(generate_uuid | tr -d '-')
        log_info "已生成随机密码: ${password}" >&2
    fi

    # 4. SNI 伪装域名
    echo "" >&2
    echo -n "请输入伪装 SNI 域名 [默认: www.bing.com]: " >&2
    read -r sni
    sni="${sni:-www.bing.com}"

    echo "${port}|${enable_hop}|${hop_start}|${hop_end}|${password}|${sni}"
}

# 获取 Reality 端口（直连模式用）
get_reality_port() {
    local port=""
    while true; do
        echo "" >&2
        echo -e "${CYAN}--------------------------------------------${NC}" >&2
        echo -e "${GREEN}  Reality 端口设置${NC}" >&2
        echo -e "${CYAN}--------------------------------------------${NC}" >&2
        echo -e "提示: 443 为标准 HTTPS 端口，隐蔽性与伪装效果最佳；如本地网络限制可输入其他端口。" >&2
        echo -n "请输入 Reality 监听端口 [默认: 443]: " >&2
        read -r port
        port="${port:-443}"
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            echo "$port"
            return 0
        else
            log_warn "端口无效，请输入 1-65535 之间的数字" >&2
        fi
    done
}

# 获取服务器地理位置与 ASN 信息
# 返回格式: countryCode|asn|isp
get_server_profile() {
    local ip="$1"
    local country_code=""
    local asn=""
    local isp=""

    # 优先使用 ip-api.com
    local info_json=""
    if [[ -n "$ip" && "$ip" != "<YOUR_SERVER_IP>" ]]; then
        info_json=$(curl -s --connect-timeout 3 -m 4 "http://ip-api.com/json/${ip}?fields=status,country,countryCode,as,isp" 2>/dev/null)
    fi

    if [[ -n "$info_json" ]] && echo "$info_json" | grep -q '"status":"success"'; then
        country_code=$(echo "$info_json" | grep -o '"countryCode":"[^"]*"' | head -1 | cut -d'"' -f4)
        asn=$(echo "$info_json" | grep -o '"as":"[^"]*"' | head -1 | cut -d'"' -f4 | grep -oE 'AS[0-9]+' | head -1)
        isp=$(echo "$info_json" | grep -o '"isp":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    # 备用方案: ipinfo.io
    if [[ -z "$country_code" ]]; then
        local ipinfo_org=""
        country_code=$(curl -s --connect-timeout 3 -m 4 "https://ipinfo.io/country" 2>/dev/null | tr -d ' \n\r' | grep -E '^[A-Z]{2}$')
        ipinfo_org=$(curl -s --connect-timeout 3 -m 4 "https://ipinfo.io/org" 2>/dev/null)
        asn=$(echo "$ipinfo_org" | grep -oE 'AS[0-9]+' | head -1)
        isp=$(echo "$ipinfo_org" | sed -E 's/^AS[0-9]+ //' | tr -d '\n\r')
    fi

    country_code="${country_code:-US}"
    asn="${asn:-UNKNOWN}"
    isp="${isp:-Unknown ISP}"

    echo "${country_code}|${asn}|${isp}"
}

# 根据 ASN 和地理位置生成候选 Reality 伪装域名
get_reality_candidates() {
    local country="$1"
    local asn="$2"
    local list=()

    # 1. 根据 ASN 优先匹配同机房/同运营商源站（网络拓扑与流量归属极其自然）
    case "$asn" in
    AS31898 | AS17012 | AS20940) # Oracle Cloud
        list+=("www.oracle.com")
        ;;
    AS16509 | AS14618) # Amazon AWS
        list+=("aws.amazon.com" "docs.aws.amazon.com")
        ;;
    AS8075) # Microsoft Azure
        list+=("learn.microsoft.com")
        ;;
    AS14061) # DigitalOcean
        list+=("cloud.digitalocean.com")
        ;;
    AS24940) # Hetzner
        list+=("www.hetzner.com")
        ;;
    AS16276) # OVH
        list+=("www.ovhcloud.com")
        ;;
    esac

    # 2. 根据国家/地区匹配当地高信誉教育/本土非 CDN 站点 (经过实测均支持 TLS 1.3 + ALPN h2)
    case "$country" in
    US)
        list+=("www.stanford.edu" "www.berkeley.edu" "www.usc.edu" "www.nvidia.com" "gateway.icloud.com")
        ;;
    JP)
        list+=("www.kyoto-u.ac.jp" "www.linefriends.jp" "gateway.icloud.com")
        ;;
    HK)
        list+=("www.ust.hk" "www.hku.hk" "www.cuhk.edu.hk")
        ;;
    SG)
        list+=("www.ntu.edu.sg" "www.singtel.com" "www.nus.edu.sg")
        ;;
    DE | FR | GB | NL | EU)
        list+=("www.ox.ac.uk" "www.cam.ac.uk" "www.kernel.org" "www.tum.de")
        ;;
    *)
        list+=("gateway.icloud.com" "itunes.apple.com" "swdist.apple.com" "www.nvidia.com")
        ;;
    esac

    # 3. 兜底保障
    list+=("gateway.icloud.com" "itunes.apple.com")

    # 去重输出
    printf "%s\n" "${list[@]}" | awk '!seen[$0]++'
}

# 本地轻量探针：验证目标域名是否满足 Reality 要求并测算延迟与得分
# 输出: score|latency|status
probe_reality_domain() {
    local domain="$1"
    local is_same_asn="${2:-0}"

    local curl_out
    curl_out=$(curl -sIv --connect-timeout 2 -m 3 "https://${domain}" 2>&1)
    local curl_exit=$?

    if [[ $curl_exit -ne 0 ]] && ! echo "$curl_out" | grep -qi "Connected to"; then
        echo "0|9999|连接失败"
        return
    fi

    # 验证 TLS 1.3
    local is_tls13=0
    if echo "$curl_out" | grep -qiE "SSL connection using TLSv1\.3|SSL connection using TLS 1\.3"; then
        is_tls13=1
    elif command -v openssl &>/dev/null; then
        local ssl_out
        ssl_out=$(echo -n | openssl s_client -connect "${domain}:443" -servername "${domain}" -tls1_3 2>&1)
        if echo "$ssl_out" | grep -qi "Protocol.*TLSv1\.3" && ! echo "$ssl_out" | grep -qiE "Cipher is \(NONE\)|no peer certificate available"; then
            is_tls13=1
        fi
    fi

    if [[ $is_tls13 -eq 0 ]]; then
        echo "0|9999|不支持 TLS 1.3"
        return
    fi

    # 验证 ALPN h2
    local is_h2=0
    if echo "$curl_out" | grep -qiE "ALPN.*accepted.*h2|server accepted h2|using HTTP/2|HTTP/2 [0-9]{3}"; then
        is_h2=1
    fi

    if [[ $is_h2 -eq 0 ]]; then
        echo "0|9999|不支持 ALPN h2"
        return
    fi

    # 测量握手延迟
    local time_conn
    time_conn=$(curl -o /dev/null -s -w "%{time_connect}\n" --connect-timeout 2 "https://${domain}" 2>/dev/null)
    local latency=999
    if [[ -n "$time_conn" && "$time_conn" != "0.000" && "$time_conn" != "0" ]]; then
        latency=$(awk "BEGIN {printf \"%d\", $time_conn * 1000}")
    fi

    # 计算推荐分
    local score=100
    if [[ "$is_same_asn" -eq 1 ]]; then
        score=$((score + 50))
    fi
    local penalty=$((latency / 3))
    score=$((score - penalty))
    if [[ $score -lt 10 ]]; then
        score=10
    fi

    echo "${score}|${latency}|OK"
}

# 交互式获取并确认最优 Reality 伪装域名
get_reality_domain() {
    local server_ip="$1"

    echo "" >&2
    echo -e "${CYAN}--------------------------------------------${NC}" >&2
    echo -e "${GREEN}  Reality 伪装域名设置 (智能环境感知)${NC}" >&2
    echo -e "${CYAN}--------------------------------------------${NC}" >&2

    echo -e "正在分析服务器网络画像..." >&2
    local profile
    profile=$(get_server_profile "$server_ip")
    local country
    local asn
    local isp
    country=$(echo "$profile" | cut -d'|' -f1)
    asn=$(echo "$profile" | cut -d'|' -f2)
    isp=$(echo "$profile" | cut -d'|' -f3)

    echo -e "  • 服务器 IP:   ${CYAN}${server_ip}${NC}" >&2
    echo -e "  • 地理位置:    ${CYAN}${country}${NC}" >&2
    echo -e "  • 所属网络:    ${CYAN}${asn} (${isp})${NC}" >&2
    echo "" >&2
    echo -e "正在本地并发探测优质候选站点 (TLS 1.3 / ALPN h2 / RTT 握手耗时)..." >&2

    local candidates=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && candidates+=("$line")
    done < <(get_reality_candidates "$country" "$asn")

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=()

    for d in "${candidates[@]}"; do
        local is_same_asn=0
        if [[ "$asn" =~ AS31898|AS17012|AS20940 ]] && [[ "$d" =~ oracle ]]; then
            is_same_asn=1
        elif [[ "$asn" =~ AS16509|AS14618 ]] && [[ "$d" =~ amazon ]]; then
            is_same_asn=1
        elif [[ "$asn" =~ AS8075 ]] && [[ "$d" =~ microsoft ]]; then
            is_same_asn=1
        elif [[ "$asn" =~ AS14061 ]] && [[ "$d" =~ digitalocean ]]; then
            is_same_asn=1
        elif [[ "$asn" =~ AS24940 ]] && [[ "$d" =~ hetzner ]]; then
            is_same_asn=1
        elif [[ "$asn" =~ AS16276 ]] && [[ "$d" =~ ovhcloud ]]; then
            is_same_asn=1
        fi

        (
            local res
            res=$(probe_reality_domain "$d" "$is_same_asn")
            echo "${d}|${res}|${is_same_asn}" >"${tmp_dir}/${d}.txt"
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    local valid_list=()
    for f in "${tmp_dir}"/*.txt; do
        [[ -f "$f" ]] || continue
        local line
        line=$(cat "$f")
        local d
        local sc
        local lat
        local st
        local same
        d=$(echo "$line" | cut -d'|' -f1)
        sc=$(echo "$line" | cut -d'|' -f2)
        lat=$(echo "$line" | cut -d'|' -f3)
        st=$(echo "$line" | cut -d'|' -f4)
        same=$(echo "$line" | cut -d'|' -f5)

        if [[ "$sc" -gt 0 && "$st" == "OK" ]]; then
            valid_list+=("${sc}|${lat}|${d}|${same}")
        fi
    done
    rm -rf "${tmp_dir}"

    local sorted_list=()
    if [[ ${#valid_list[@]} -gt 0 ]]; then
        while IFS= read -r l; do
            [[ -n "$l" ]] && sorted_list+=("$l")
        done < <(printf '%s\n' "${valid_list[@]}" | sort -t'|' -k1,1nr -k2,2n)
    fi

    # 打印检测通过的域名
    local best_domain="gateway.icloud.com"
    local idx=1
    for item in "${sorted_list[@]}"; do
        local sc=$(echo "$item" | cut -d'|' -f1)
        local lat=$(echo "$item" | cut -d'|' -f2)
        local d=$(echo "$item" | cut -d'|' -f3)
        local same=$(echo "$item" | cut -d'|' -f4)

        local tag=""
        if [[ "$same" -eq 1 ]]; then
            tag=" [同机房/ASN 推荐]"
        fi

        printf "  ${GREEN}[✓]${NC} %-25s 延迟: %4sms%b\n" "$d" "$lat" "${CYAN}${tag}${NC}" >&2
        if [[ $idx -eq 1 ]]; then
            best_domain="$d"
        fi
        ((idx++))
    done

    if [[ ${#sorted_list[@]} -eq 0 ]]; then
        log_warn "候选站点探测均未达标，采用安全兜底域名: ${best_domain}" >&2
    fi

    echo "" >&2
    echo -e "系统推荐最优伪装域名: ${GREEN}${best_domain}${NC}" >&2
    echo -e "  ${BLUE}1)${NC} 使用系统推荐最优域名 [默认: ${best_domain}]" >&2
    echo -e "  ${BLUE}2)${NC} 从检测合格列表中选择" >&2
    echo -e "  ${BLUE}3)${NC} 手动输入自定义伪装域名 (自动合规性检测)" >&2
    echo -n "请选择 [1/2/3, 默认 1]: " >&2
    local choice
    read -r choice
    choice="${choice:-1}"

    local final_domain="${best_domain}"
    case "$choice" in
    2)
        if [[ ${#sorted_list[@]} -gt 0 ]]; then
            echo "" >&2
            local i=1
            for item in "${sorted_list[@]}"; do
                local lat=$(echo "$item" | cut -d'|' -f2)
                local d=$(echo "$item" | cut -d'|' -f3)
                echo -e "  ${BLUE}${i})${NC} ${d} (${lat}ms)" >&2
                ((i++))
            done
            echo -n "请输入选择序号 [1-${#sorted_list[@]}]: " >&2
            local num
            read -r num
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#sorted_list[@]}" ]; then
                final_domain=$(echo "${sorted_list[$((num - 1))]}" | cut -d'|' -f3)
            else
                log_warn "输入无效，已使用系统推荐域名: ${best_domain}" >&2
            fi
        else
            log_warn "无可用列表，已使用系统推荐域名: ${best_domain}" >&2
        fi
        ;;
    3)
        while true; do
            echo "" >&2
            echo -n "请输入自定义伪装域名 (如 www.apple.com): " >&2
            local custom_d
            read -r custom_d
            if [[ -z "$custom_d" ]]; then
                echo -e "${YELLOW}输入为空，使用推荐域名: ${final_domain}${NC}" >&2
                break
            fi
            echo -e "正在对 ${custom_d} 进行 TLS 1.3 / ALPN h2 合规性检测..." >&2
            local check
            check=$(probe_reality_domain "$custom_d" 0)
            local sc=$(echo "$check" | cut -d'|' -f1)
            local lat=$(echo "$check" | cut -d'|' -f2)
            local err=$(echo "$check" | cut -d'|' -f3)
            if [[ "$sc" -gt 0 && "$err" == "OK" ]]; then
                echo -e "${GREEN}[✓] 检测通过! 延迟: ${lat}ms，支持 TLS 1.3 及 ALPN h2${NC}" >&2
                final_domain="$custom_d"
                break
            else
                echo -e "${RED}[✗] 检测未通过: ${err}${NC}" >&2
                echo -e "${YELLOW}提示: 该域名作为 Reality 伪装可能导致客户端连接失败 (reality verification failed)。${NC}" >&2
                echo -n "是否仍要强制使用此域名？[y/N]: " >&2
                local force_use
                read -r force_use
                if [[ "$force_use" =~ ^[Yy]$ ]]; then
                    final_domain="$custom_d"
                    break
                fi
            fi
        done
        ;;
    *)
        final_domain="${best_domain}"
        ;;
    esac

    log_info "已选定 Reality 伪装域名: ${final_domain}" >&2
    echo "$final_domain"
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

# 解析当前安装的服务类型与变量
resolve_service_vars() {
    if [[ -f "${INSTALL_INFO}" ]]; then
        # shellcheck disable=SC1090
        source "${INSTALL_INFO}"
    fi
    if [[ "${CORE_TYPE:-}" == "hysteria" || "${DEPLOY_MODE:-}" == "hysteria" ]]; then
        SERVICE_NAME="${HYSTERIA_SERVICE_NAME}"
        PID_FILE="${HYSTERIA_PID_FILE}"
        CORE_TYPE="hysteria"
    else
        SERVICE_NAME="xray"
        PID_FILE="/var/run/xray.pid"
        CORE_TYPE="xray"
    fi
}

# 安装 Xray systemd 服务
install_systemd_service() {
    log_info "安装 systemd 服务..."

    cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
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

# 安装 Hysteria systemd 服务
install_hysteria_systemd_service() {
    log_info "安装 Hysteria systemd 服务..."

    cat >/etc/systemd/system/${HYSTERIA_SERVICE_NAME}.service <<EOF
[Unit]
Description=Hysteria 2 Server Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${HYSTERIA_CONFIG_DIR}
ExecStart=${HYSTERIA_DIR}/hysteria server -c ${HYSTERIA_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${HYSTERIA_SERVICE_NAME} >/dev/null 2>&1
    systemctl start ${HYSTERIA_SERVICE_NAME}

    log_info "Hysteria systemd 服务启动完成"
}

# 安装 OpenRC 服务
install_openrc_service() {
    log_info "安装 OpenRC 服务..."

    # 创建 PID 文件目录
    mkdir -p /run

    cat >/etc/init.d/${SERVICE_NAME} <<'SCRIPT'
#!/sbin/openrc-run

name="xray"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
start_stop_daemon_args="--background --make-pidfile"

depend() {
    need net
    after firewall
}

start_pre() {
    # 确保 /run 目录存在
    if [ ! -d /run ]; then
        mkdir -p /run
    fi
    return 0
}
SCRIPT

    chmod +x /etc/init.d/${SERVICE_NAME}
    rc-update add ${SERVICE_NAME} default 2>/dev/null || true
    rc-service ${SERVICE_NAME} start

    log_info "OpenRC 服务启动完成"
}

# 安装 Hysteria OpenRC 服务
install_hysteria_openrc_service() {
    log_info "安装 Hysteria OpenRC 服务..."
    mkdir -p /run
    mkdir -p "${HYSTERIA_LOG}"

    cat >/etc/init.d/${HYSTERIA_SERVICE_NAME} <<EOF
#!/sbin/openrc-run

name="hysteria"
command="${HYSTERIA_DIR}/hysteria"
command_args="server -c ${HYSTERIA_CONFIG}"
command_background=true
pidfile="${HYSTERIA_PID_FILE}"
start_stop_daemon_args="--background --make-pidfile"
output_log="${HYSTERIA_LOG}/access.log"
error_log="${HYSTERIA_LOG}/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -d /run ]; then
        mkdir -p /run
    fi
    return 0
}
EOF

    chmod +x /etc/init.d/${HYSTERIA_SERVICE_NAME}
    rc-update add ${HYSTERIA_SERVICE_NAME} default 2>/dev/null || true
    rc-service ${HYSTERIA_SERVICE_NAME} start

    log_info "Hysteria OpenRC 服务启动完成"
}

# 使用 nohup 启动（兼容方案）
install_nohup_service() {
    # 检查是否已有进程在运行
    if [[ -f ${PID_FILE} ]] && kill -0 $(cat ${PID_FILE}) 2>/dev/null; then
        log_warn "Xray 已在运行 (PID: $(cat ${PID_FILE}))，先停止旧进程..."
        kill $(cat ${PID_FILE}) 2>/dev/null || true
        sleep 1
        rm -f ${PID_FILE}
    fi
    # 兜底: 检查是否有残留 xray 进程占用端口
    local old_pid=$(pgrep -x xray 2>/dev/null | head -1)
    if [[ -n "$old_pid" ]]; then
        log_warn "发现残留 Xray 进程 (PID: ${old_pid})，正在停止..."
        kill ${old_pid} 2>/dev/null || true
        sleep 1
    fi

    log_info "使用 nohup 启动服务..."

    nohup ${XRAY_DIR}/xray run -config ${XRAY_CONFIG} >${XRAY_LOG}/xray.log 2>&1 &
    echo $! >${PID_FILE}

    log_info "服务已启动 (PID: $(cat ${PID_FILE}))"

    # 创建启动脚本
    cat >/usr/local/bin/xray-start <<EOF
#!/bin/bash
nohup ${XRAY_DIR}/xray run -config ${XRAY_CONFIG} > ${XRAY_LOG}/xray.log 2>&1 &
echo \$! > ${PID_FILE}
echo "Xray started (PID: \$(cat ${PID_FILE}))"
EOF

    cat >/usr/local/bin/xray-stop <<EOF
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

# 安装 Hysteria nohup 服务
install_hysteria_nohup_service() {
    log_info "配置 Hysteria nohup 运行模式..."
    mkdir -p "${HYSTERIA_LOG}"

    cat >/usr/local/bin/hysteria-start <<EOF
#!/bin/bash
if [[ -f ${HYSTERIA_PID_FILE} ]] && kill -0 \$(cat ${HYSTERIA_PID_FILE}) 2>/dev/null; then
    echo "Hysteria is already running"
    exit 0
fi
mkdir -p ${HYSTERIA_LOG}
nohup ${HYSTERIA_DIR}/hysteria server -c ${HYSTERIA_CONFIG} >${HYSTERIA_LOG}/hysteria.log 2>&1 &
echo \$! >${HYSTERIA_PID_FILE}
echo "Hysteria started with PID \$(cat ${HYSTERIA_PID_FILE})"
EOF

    cat >/usr/local/bin/hysteria-stop <<EOF
#!/bin/bash
if [[ -f ${HYSTERIA_PID_FILE} ]]; then
    kill \$(cat ${HYSTERIA_PID_FILE}) 2>/dev/null
    rm -f ${HYSTERIA_PID_FILE}
    echo "Hysteria stopped"
else
    echo "Hysteria is not running"
fi
EOF

    chmod +x /usr/local/bin/hysteria-start /usr/local/bin/hysteria-stop

    if [[ -f /etc/rc.local ]]; then
        if ! grep -q "hysteria-start" /etc/rc.local; then
            sed -i '/^exit 0/i \/usr/local/bin/hysteria-start' /etc/rc.local
        fi
    fi

    /usr/local/bin/hysteria-start
}

# 安装服务（自动选择）
install_service() {
    local init_system
    init_system=$(get_init_system)
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

    check_service_health
}

# 安装 Hysteria 服务（自动选择）
install_hysteria_service() {
    local init_system
    init_system=$(get_init_system)
    log_info "检测到 init 系统: ${init_system}"

    case ${init_system} in
    systemd)
        install_hysteria_systemd_service
        ;;
    openrc)
        install_hysteria_openrc_service
        ;;
    *)
        install_hysteria_nohup_service
        ;;
    esac

    check_service_health
}

# 停止服务
stop_service() {
    resolve_service_vars
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
        local proc_name="xray"
        [[ "${CORE_TYPE}" == "hysteria" ]] && proc_name="hysteria"
        local residual_pid=$(pgrep -x "${proc_name}" 2>/dev/null | head -1)
        if [[ -n "$residual_pid" ]]; then
            kill ${residual_pid} 2>/dev/null || true
        fi
        ;;
    esac
}

# 启动服务
start_service() {
    resolve_service_vars
    local init_system=$(get_init_system)

    case ${init_system} in
    systemd)
        systemctl start ${SERVICE_NAME} 2>/dev/null || true
        ;;
    openrc)
        rc-service ${SERVICE_NAME} start 2>/dev/null || true
        ;;
    *)
        if [[ "${CORE_TYPE}" == "hysteria" ]]; then
            mkdir -p "${HYSTERIA_LOG}"
            nohup ${HYSTERIA_DIR}/hysteria server -c ${HYSTERIA_CONFIG} >${HYSTERIA_LOG}/hysteria.log 2>&1 &
            echo $! >${PID_FILE}
        else
            mkdir -p "${XRAY_LOG}"
            nohup ${XRAY_DIR}/xray run -config ${XRAY_CONFIG} >${XRAY_LOG}/xray.log 2>&1 &
            echo $! >${PID_FILE}
        fi
        ;;
    esac
}

# 检查服务状态
is_running() {
    resolve_service_vars
    local init_system
    init_system=$(get_init_system)

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

# 服务健康检查与故障自诊断
check_service_health() {
    resolve_service_vars
    sleep 1

    if is_running; then
        log_info "${SERVICE_NAME} 服务运行正常"
        return 0
    fi

    echo "" >&2
    log_error "${SERVICE_NAME} 服务未能成功运行！" >&2
    echo -e "${YELLOW}------------------- 故障诊断日志 -------------------${NC}" >&2

    local init_system
    init_system=$(get_init_system)

    if [[ "$init_system" == "systemd" ]]; then
        journalctl -u "${SERVICE_NAME}" -n 15 --no-pager 2>/dev/null || true
    elif [[ -f "${XRAY_LOG}/error.log" && -s "${XRAY_LOG}/error.log" ]]; then
        tail -n 15 "${XRAY_LOG}/error.log" 2>/dev/null || true
    elif [[ -f "${HYSTERIA_LOG}/error.log" && -s "${HYSTERIA_LOG}/error.log" ]]; then
        tail -n 15 "${HYSTERIA_LOG}/error.log" 2>/dev/null || true
    elif [[ -f "${XRAY_LOG}/xray.log" && -s "${XRAY_LOG}/xray.log" ]]; then
        tail -n 15 "${XRAY_LOG}/xray.log" 2>/dev/null || true
    elif [[ -f "${HYSTERIA_LOG}/hysteria.log" && -s "${HYSTERIA_LOG}/hysteria.log" ]]; then
        tail -n 15 "${HYSTERIA_LOG}/hysteria.log" 2>/dev/null || true
    fi

    echo -e "${YELLOW}----------------------------------------------------${NC}" >&2
    log_warn "服务未能成功启动，请根据上述日志排查端口冲突或环境配置问题" >&2
    exit 1
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

    # 尝试加载 BBR 模块（容器中可能无法加载但模块已可用）
    modprobe tcp_bbr 2>/dev/null || true

    # 配置 BBR
    cat >/etc/sysctl.d/99-bbr.conf <<EOF
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
    echo 0 >/proc/sys/net/ipv4/icmp_echo_ignore_all

    # 持久化
    cat >/etc/sysctl.d/99-icmp.conf <<EOF
net.ipv4.icmp_echo_ignore_all = 0
EOF

    sysctl -p /etc/sysctl.d/99-icmp.conf >/dev/null 2>&1

    log_info "ICMP 启用成功"
    return 0
}

# 配置防火墙（遵循最小侵入与增量放行原则）
configure_firewall() {
    local port="${1:-443}"
    local proto="${2:-tcp}"
    log_info "配置防火墙，放行服务端口 (${port}/${proto})..."

    # 规范化端口表示：firewalld 端口范围使用 '-'，ufw/iptables 使用 ':'
    local port_dash="${port/:/-}"
    local port_colon="${port/-/:}"

    # 检测防火墙类型
    if command -v ufw &>/dev/null; then
        local ufw_active=false
        if ufw status 2>/dev/null | grep -qw "active"; then
            ufw_active=true
        fi

        if [[ "$ufw_active" == "true" ]]; then
            # 原有防火墙运行中：严格遵循最小侵入原则，仅增量追加服务端口，不修改原有策略
            ufw allow "${port_colon}/${proto}" >/dev/null 2>&1 || true
            ufw reload >/dev/null 2>&1 || true
            log_info "ufw 已增量放行服务端口: ${port_colon}/${proto}"
        else
            # 原有防火墙未激活：初次配置兜底放行基础管理端口 (22/tcp) 与本服务端口
            ufw allow 22/tcp >/dev/null 2>&1 || true
            ufw allow "${port_colon}/${proto}" >/dev/null 2>&1 || true
            log_info "ufw 已配置必要端口: 22/tcp, ${port_colon}/${proto}"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        local fw_running=false
        if firewall-cmd --state 2>/dev/null | grep -qw "running"; then
            fw_running=true
        fi

        if [[ "$fw_running" == "true" ]]; then
            # 原有防火墙运行中：仅增量放行服务端口
            firewall-cmd --permanent --add-port="${port_dash}/${proto}" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            log_info "firewalld 已增量放行服务端口: ${port_dash}/${proto}"
        else
            # 原有防火墙未运行：初次配置放行基础管理端口 (22/tcp) 与本服务端口
            firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-port="${port_dash}/${proto}" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            log_info "firewalld 已配置必要端口: 22/tcp, ${port_dash}/${proto}"
        fi
    elif command -v iptables &>/dev/null; then
        # 仅增量放行当前服务端口
        iptables -C INPUT -p "${proto}" --dport "${port_colon}" -j ACCEPT 2>/dev/null ||
            iptables -I INPUT -p "${proto}" --dport "${port_colon}" -j ACCEPT

        # 若 INPUT 链存在默认 DROP 规则，确保 22 端口具备保底访问权限
        if iptables -S INPUT 2>/dev/null | grep -q -- "-P INPUT DROP"; then
            iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null ||
                iptables -I INPUT -p tcp --dport 22 -j ACCEPT
        fi

        # 持久化
        if command -v iptables-save &>/dev/null; then
            iptables-save >/etc/iptables.rules 2>/dev/null || true
        fi
        if [[ -d /etc/network/if-pre-up.d ]]; then
            cat >/etc/network/if-pre-up.d/iptables-restore <<'RESTORE'
#!/bin/sh
iptables-restore < /etc/iptables.rules 2>/dev/null
RESTORE
            chmod +x /etc/network/if-pre-up.d/iptables-restore 2>/dev/null || true
        fi
        log_info "iptables 已放行服务端口: ${port_colon}/${proto}"
    else
        log_warn "未检测到活跃的防火墙工具，已跳过防火墙端口放行"
    fi

    return 0
}

# 配置端口跳跃 (Port Hopping) iptables 重定向
configure_port_hopping() {
    local target_port="$1"
    local hop_start="$2"
    local hop_end="$3"

    log_info "配置 iptables UDP 端口跳跃转发: ${hop_start}:${hop_end} -> ${target_port}..."
    if command -v iptables &>/dev/null; then
        iptables -t nat -C PREROUTING -p udp --dport "${hop_start}:${hop_end}" -j REDIRECT --to-ports "${target_port}" 2>/dev/null ||
            iptables -t nat -A PREROUTING -p udp --dport "${hop_start}:${hop_end}" -j REDIRECT --to-ports "${target_port}"

        if command -v iptables-save &>/dev/null; then
            iptables-save >/etc/iptables.rules 2>/dev/null || true
        fi
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
        log_info "iptables 端口跳跃规则配置完成"
    else
        log_warn "未检测到 iptables，端口跳跃重定向可能需要手动配置"
    fi
}

# 清理端口跳跃规则
cleanup_port_hopping() {
    local target_port="$1"
    local hop_start="$2"
    local hop_end="$3"

    if [[ -n "$target_port" && -n "$hop_start" && -n "$hop_end" ]] && command -v iptables &>/dev/null; then
        log_info "清理 iptables 端口跳跃规则: ${hop_start}:${hop_end} -> ${target_port}..."
        iptables -t nat -D PREROUTING -p udp --dport "${hop_start}:${hop_end}" -j REDIRECT --to-ports "${target_port}" 2>/dev/null || true

        if command -v iptables-save &>/dev/null; then
            iptables-save >/etc/iptables.rules 2>/dev/null || true
        fi
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi
}

# ==================== 核心功能 ====================

# 获取 Xray-core 最新版本号
get_latest_version() {
    local latest_ver=""

    # 方法1: 从 GitHub 重定向获取版本号
    latest_ver=$(curl -sI -o /dev/null -w '%{redirect_url}' "${GITHUB_LATEST_URL}" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    # 方法2: 如果重定向失败，尝试 API
    if [[ -z "$latest_ver" ]]; then
        local api_response=$(curl -s ${GITHUB_API} 2>/dev/null)
        if command -v jq &>/dev/null; then
            latest_ver=$(echo "$api_response" | jq -r '.tag_name // empty' 2>/dev/null)
        fi
        if [[ -z "$latest_ver" ]]; then
            latest_ver=$(echo "$api_response" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)
        fi
    fi

    # 方法3: 使用默认版本
    if [[ -z "$latest_ver" ]]; then
        log_warn "获取版本失败，使用默认版本 v25.6.8"
        latest_ver="v25.6.8"
    fi

    echo "$latest_ver"
}

# 安装 Xray-core
install_xray() {
    log_info "检测系统架构..."
    local arch=$(get_arch)
    log_info "架构: ${arch}"

    log_info "获取最新版本信息..."
    local latest_ver=$(get_latest_version)
    log_info "最新版本: ${latest_ver}"

    # 下载
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_ver}/Xray-linux-${arch}.zip"
    log_info "下载: ${download_url}"

    local tmp_dir=$(mktemp -d)
    if ! curl -fsSL -L --connect-timeout 10 -o "${tmp_dir}/xray.zip" "${download_url}"; then
        log_error "下载 Xray-core 失败，请检查网络连接"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    # 安装
    log_info "解压并安装 Xray-core..."
    if ! unzip -qo "${tmp_dir}/xray.zip" -d "${tmp_dir}" 2>/dev/null; then
        log_error "解压 Xray-core 压缩包失败，可能下载文件不完整"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    if [[ ! -f "${tmp_dir}/xray" ]]; then
        log_error "未在压缩包中找到 xray 可执行文件"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    mv -f "${tmp_dir}/xray" "${XRAY_DIR}/xray"
    chmod +x "${XRAY_DIR}/xray"
    rm -rf "${tmp_dir}"

    log_info "Xray-core ${latest_ver} 安装完成"
    mkdir -p "${XRAY_CONFIG_DIR}"
    echo "$latest_ver" >"${XRAY_CONFIG_DIR}/version.txt" 2>/dev/null || true
}

# 获取 Hysteria 2 最新版本号
get_latest_hysteria_version() {
    local latest_ver=""

    # 方法1: 从 GitHub 重定向获取版本号
    latest_ver=$(curl -sI -o /dev/null -w '%{redirect_url}' "${HYSTERIA_LATEST_URL}" 2>/dev/null | grep -oE '(app/)?v[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    # 方法2: 如果重定向失败，尝试 API
    if [[ -z "$latest_ver" ]]; then
        local api_response=$(curl -s "${HYSTERIA_GITHUB_API}" 2>/dev/null)
        if command -v jq &>/dev/null; then
            latest_ver=$(echo "$api_response" | jq -r '.tag_name // empty' 2>/dev/null)
        fi
        if [[ -z "$latest_ver" ]]; then
            latest_ver=$(echo "$api_response" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)
        fi
    fi

    # 方法3: 默认版本兜底
    if [[ -z "$latest_ver" ]]; then
        latest_ver="app/v2.12.2"
    fi

    echo "$latest_ver"
}

# 安装 Hysteria 2
install_hysteria() {
    log_info "检测系统架构..."
    local arch=$(get_hysteria_arch)
    log_info "Hysteria 架构: ${arch}"

    log_info "获取最新版本信息..."
    local latest_ver=$(get_latest_hysteria_version)
    log_info "最新版本: ${latest_ver}"

    # 下载 (优先使用 latest 下载链接，若失败则尝试 tag 链接)
    local download_url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
    log_info "下载 Hysteria 2: ${download_url}"

    local tmp_file=$(mktemp)
    if ! curl -fsSL -L -o "${tmp_file}" "${download_url}"; then
        download_url="https://github.com/apernet/hysteria/releases/download/${latest_ver}/hysteria-linux-${arch}"
        log_warn "从 latest 下载失败，尝试从 tag 下载: ${download_url}"
        if ! curl -fsSL -L -o "${tmp_file}" "${download_url}"; then
            log_error "Hysteria 2 下载失败，请检查网络连接或使用代理"
            rm -f "${tmp_file}"
            exit 1
        fi
    fi

    mkdir -p "${HYSTERIA_DIR}"
    if [[ ! -s "${tmp_file}" ]] || [[ $(wc -c <"${tmp_file}" 2>/dev/null || echo 0) -lt 102400 ]]; then
        log_error "Hysteria 2 二进制文件损坏或不完整"
        rm -f "${tmp_file}"
        exit 1
    fi
    mv -f "${tmp_file}" "${HYSTERIA_DIR}/hysteria"
    chmod +x "${HYSTERIA_DIR}/hysteria"

    log_info "Hysteria 2 安装完成: $("${HYSTERIA_DIR}/hysteria" version 2>/dev/null | head -1)"
}

# 更新 Hysteria 2
update_hysteria() {
    if [[ ! -f ${HYSTERIA_DIR}/hysteria ]]; then
        log_error "Hysteria 2 未安装"
        exit 1
    fi

    local current_ver=$(${HYSTERIA_DIR}/hysteria version 2>/dev/null | head -1 | awk '{print $NF}')
    local latest_ver=$(get_latest_hysteria_version)

    log_info "当前版本: ${current_ver}"
    log_info "最新版本: ${latest_ver}"

    if [[ -n "$current_ver" && "$current_ver" == "$latest_ver" ]]; then
        log_info "已是最新版本"
        return
    fi

    log_info "更新中..."
    stop_service
    install_hysteria
    start_service
    log_info "更新完成"
}

# 生成配置
generate_config() {
    local mode="${1:-direct}"
    local domain="${2:-}"
    local port="${3:-443}"
    local reality_sni="${4:-gateway.icloud.com}"

    log_info "生成配置..."

    mkdir -p "${XRAY_CONFIG_DIR}"
    mkdir -p "${XRAY_LOG}"

    # 备份已有配置
    if [[ -f "${XRAY_CONFIG}" ]]; then
        cp "${XRAY_CONFIG}" "${XRAY_CONFIG}.bak"
        log_info "已备份旧配置到 ${XRAY_CONFIG}.bak"
    fi

    # 生成密钥
    local uuid=$(generate_uuid)
    local keys=$(generate_keys)
    local private_key=$(echo "$keys" | grep -i "Private" | awk '{print $NF}')
    local public_key=$(echo "$keys" | grep -i "Public" | awk '{print $NF}')
    local short_id=$(generate_short_id)

    if [[ -z "$uuid" ]]; then
        log_error "生成 UUID 失败，请检查系统环境"
        exit 1
    fi

    if [[ "$mode" == "direct" ]]; then
        if [[ -z "$private_key" || -z "$public_key" ]]; then
            log_error "生成 x25519 密钥对失败，请检查 Xray 是否具备执行权限"
            exit 1
        fi
        if [[ -z "$short_id" ]]; then
            log_error "生成 Short ID 失败"
            exit 1
        fi
    fi

    # 获取服务器 IPv4
    local server_ip
    server_ip=$(get_server_ip)

    # 根据模式生成配置（内置 JSON 生成，不依赖 jq，兼容 Alpine）
    local inbound_json=""

    # 直连模式 (Reality)
    if [[ "$mode" == "direct" ]]; then
        inbound_json=$(
            cat <<EOF
{
  "listen": "0.0.0.0",
  "port": ${port},
  "protocol": "vless",
  "settings": {
    "clients": [{"id": "$(json_escape "$uuid")", "flow": "xtls-rprx-vision"}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "${reality_sni}:443",
      "xver": 0,
      "serverNames": ["${reality_sni}"],
      "privateKey": "$(json_escape "$private_key")",
      "shortIds": ["$(json_escape "$short_id")"]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": true
  }
}
EOF
        )
    fi

    # CDN 模式 (XHTTP + TLS)
    if [[ "$mode" == "cdn" ]]; then
        local cdn_port=443

        local cert_paths=$(get_cert_content "${domain}")
        local cert_file=$(echo "$cert_paths" | cut -d'|' -f1)
        local key_file=$(echo "$cert_paths" | cut -d'|' -f2)

        inbound_json=$(
            cat <<EOF
{
  "listen": "0.0.0.0",
  "port": ${cdn_port},
  "protocol": "vless",
  "settings": {
    "clients": [{"id": "$(json_escape "$uuid")"}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "certificates": [{
        "certificateFile": "$(json_escape "$cert_file")",
        "keyFile": "$(json_escape "$key_file")"
      }]
    },
    "xhttpSettings": {
      "path": "/vless-xhttp"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": true
  }
}
EOF
        )
    fi

    # 生成配置文件
    cat >"${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$(json_escape "${XRAY_LOG}/access.log")",
    "error": "$(json_escape "${XRAY_LOG}/error.log")"
  },
  "inbounds": [${inbound_json}],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [{
      "type": "field",
      "outboundTag": "blocked",
      "protocol": ["bittorrent"]
    }]
  }
}
EOF

    # 验证生成的配置
    local config_ok=1
    if command -v jq &>/dev/null; then
        jq . "${XRAY_CONFIG}" >/dev/null 2>&1 && config_ok=0
    else
        # jq 不可用时的简易校验（兼容 Alpine/busybox）
        if [[ -s "${XRAY_CONFIG}" ]] && grep -q '"inbounds"' "${XRAY_CONFIG}"; then
            config_ok=0
        fi
    fi
    if [[ $config_ok -ne 0 ]]; then
        log_error "生成的配置 JSON 格式有误，请检查"
        if [[ -f "${XRAY_CONFIG}.bak" ]]; then
            cp "${XRAY_CONFIG}.bak" "${XRAY_CONFIG}"
            log_info "已恢复备份配置"
        fi
        exit 1
    fi
    if command -v ${XRAY_DIR}/xray &>/dev/null; then
        if ! ${XRAY_DIR}/xray run -test -config "${XRAY_CONFIG}" >/dev/null 2>&1; then
            log_warn "Xray 配置验证未通过，服务可能无法正常启动"
        fi
    fi

    # 保存安装信息
    local saved_sni="www.cloudflare.com"
    if [[ "$mode" == "direct" ]]; then
        saved_sni="${reality_sni}"
    fi

    cat >"${INSTALL_INFO}" <<EOF
DEPLOY_MODE=${mode}
CORE_TYPE=xray
PORT=${port}
UUID=${uuid}
PRIVATE_KEY=${private_key}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
SERVER_IP=${server_ip}
SNI=${saved_sni}
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

    # CDN 模式额外保存域名和证书信息
    if [[ "$mode" == "cdn" ]]; then
        cat >>"${INSTALL_INFO}" <<EOF
DOMAIN=${domain}
CERT_FILE=${cert_file}
KEY_FILE=${key_file}
EOF
    fi

    log_info "配置生成完成"
}

# 生成 Hysteria 2 自签名证书 (包含标准 SAN 扩展与合规有效期)
generate_hysteria_cert() {
    local sni="${1:-www.bing.com}"
    mkdir -p "${HYSTERIA_CONFIG_DIR}"
    log_info "生成 EC (prime256v1) 自签名证书 (SNI: ${sni}, 带 SAN 扩展)..."
    openssl ecparam -genkey -name prime256v1 -out "${HYSTERIA_CONFIG_DIR}/server.key" 2>/dev/null

    # 优先尝试使用 -addext 生成带 SAN 扩展的证书 (有效期限设为标准的 365 天)
    if ! openssl req -new -x509 -days 365 \
        -key "${HYSTERIA_CONFIG_DIR}/server.key" \
        -out "${HYSTERIA_CONFIG_DIR}/server.crt" \
        -subj "/CN=${sni}" \
        -addext "subjectAltName = DNS:${sni}" 2>/dev/null; then
        # 兼容旧版本 openssl
        openssl req -new -x509 -days 365 \
            -key "${HYSTERIA_CONFIG_DIR}/server.key" \
            -out "${HYSTERIA_CONFIG_DIR}/server.crt" \
            -subj "/CN=${sni}" 2>/dev/null
    fi

    chmod 600 "${HYSTERIA_CONFIG_DIR}/server.key"
    chmod 644 "${HYSTERIA_CONFIG_DIR}/server.crt"
    log_info "Hysteria 2 自签名证书生成完成"
}

# 生成 Hysteria 2 配置
generate_hysteria_config() {
    local port="$1"
    local password="$2"
    local sni="$3"

    log_info "生成 Hysteria 2 配置..."
    mkdir -p "${HYSTERIA_CONFIG_DIR}"
    mkdir -p "${HYSTERIA_LOG}"

    # 备份已有配置
    if [[ -f "${HYSTERIA_CONFIG}" ]]; then
        cp "${HYSTERIA_CONFIG}" "${HYSTERIA_CONFIG}.bak"
        log_info "已备份旧配置到 ${HYSTERIA_CONFIG}.bak"
    fi

    cat >"${HYSTERIA_CONFIG}" <<EOF
listen: :${port}

tls:
  cert: ${HYSTERIA_CONFIG_DIR}/server.crt
  key: ${HYSTERIA_CONFIG_DIR}/server.key

auth:
  type: password
  password: "${password}"

masquerade:
  type: proxy
  proxy:
    url: https://${sni}/
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF
    chmod 600 "${HYSTERIA_CONFIG}"
    log_info "Hysteria 2 配置生成完成"
}

# 保存 Hysteria 2 安装信息
save_hysteria_info() {
    local port="$1"
    local enable_hop="$2"
    local hop_start="$3"
    local hop_end="$4"
    local password="$5"
    local sni="$6"
    local server_ip="$7"

    mkdir -p "${XRAY_CONFIG_DIR}"
    cat >"${INSTALL_INFO}" <<EOF
DEPLOY_MODE=hysteria
CORE_TYPE=hysteria
PORT=${port}
HOPPING_ENABLED=${enable_hop}
HOP_START=${hop_start}
HOP_END=${hop_end}
PASSWORD=${password}
SNI=${sni}
SERVER_IP=${server_ip}
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    log_info "Hysteria 2 安装信息已保存"
}

# 卸载节点服务
uninstall_node() {
    resolve_service_vars
    log_warn "即将卸载当前节点服务 (${CORE_TYPE:-xray})..."
    local confirm=""
    read -r -p "确认卸载? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "取消卸载"
        return
    fi

    # 停止服务
    stop_service

    # 删除服务文件
    local init_system
    init_system=$(get_init_system)
    case ${init_system} in
    systemd)
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload 2>/dev/null || true
        ;;
    openrc)
        rc-update del "${SERVICE_NAME}" 2>/dev/null || true
        rm -f "/etc/init.d/${SERVICE_NAME}"
        ;;
    *)
        rm -f "/usr/local/bin/${CORE_TYPE}-start" "/usr/local/bin/${CORE_TYPE}-stop"
        rm -f "${PID_FILE}"
        ;;
    esac

    # 删除文件
    if [[ "${CORE_TYPE}" == "hysteria" ]]; then
        if [[ "${HOPPING_ENABLED:-false}" == "true" && -n "${PORT:-}" && -n "${HOP_START:-}" && -n "${HOP_END:-}" ]]; then
            cleanup_port_hopping "${PORT}" "${HOP_START}" "${HOP_END}"
        fi
        rm -f "${HYSTERIA_DIR}/hysteria"
        rm -rf "${HYSTERIA_CONFIG_DIR}"
        rm -rf "${HYSTERIA_LOG}"
    else
        rm -f "${XRAY_DIR}/xray"
        rm -rf "${XRAY_CONFIG_DIR}"
        rm -rf "${XRAY_LOG}"
    fi

    rm -f "${INSTALL_INFO}"
    log_info "卸载完成"
}

# 兼容旧函数名
uninstall_xray() {
    uninstall_node
}

# 更新节点
update_node() {
    resolve_service_vars
    if [[ "${CORE_TYPE}" == "hysteria" ]]; then
        update_hysteria
    else
        update_xray
    fi
}

# 更新
update_xray() {
    if [[ ! -f ${XRAY_DIR}/xray ]]; then
        log_error "Xray-core 未安装"
        exit 1
    fi

    local current_ver=$(${XRAY_DIR}/xray version 2>/dev/null | head -1 | awk '{print $2}')
    local latest_ver=$(get_latest_version)

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
    resolve_service_vars
    echo ""
    if [[ "${CORE_TYPE}" == "hysteria" ]]; then
        echo -e "${CYAN}========== Hysteria 2 服务状态 ==========${NC}"
    else
        echo -e "${CYAN}========== Xray 服务状态 ==========${NC}"
    fi

    local init_system
    init_system=$(get_init_system)
    log_info "Init 系统: ${init_system}"

    if is_running; then
        echo -e "  状态: ${GREEN}运行中${NC}"
    else
        echo -e "  状态: ${RED}未运行${NC}"
    fi

    if [[ "${CORE_TYPE}" == "hysteria" ]]; then
        if [[ -x "${HYSTERIA_DIR}/hysteria" ]]; then
            echo -e "  版本: $(${HYSTERIA_DIR}/hysteria version 2>/dev/null | head -1)"
        fi
    else
        if [[ -f "${XRAY_CONFIG_DIR}/version.txt" ]]; then
            echo -e "  版本: $(cat "${XRAY_CONFIG_DIR}/version.txt")"
        fi
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
    if [[ "$mode" == "hysteria" ]]; then
        echo -e "${GREEN}  Hysteria 2 节点信息${NC}"
    else
        echo -e "${GREEN}  Xray VLESS 节点信息${NC}"
    fi
    echo -e "${CYAN}============================================${NC}"

    # 直连模式信息
    if [[ "$mode" == "direct" ]]; then
        local port="${PORT:-${SERVER_PORT:-443}}"
        local reality_link="vless://${UUID}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Xray-Reality"

        echo ""
        echo -e "${GREEN}[直连模式 - VLESS + Reality (TCP)]${NC}"
        echo ""
        echo -e "  ${BLUE}地址:${NC}   ${SERVER_IP}"
        echo -e "  ${BLUE}端口:${NC}   ${port}"
        echo -e "  ${BLUE}UUID:${NC}   ${UUID}"
        echo -e "  ${BLUE}密钥:${NC}   ${PUBLIC_KEY}"
        echo -e "  ${BLUE}SNI:${NC}    ${SNI}"
        echo -e "  ${BLUE}Flow:${NC}   xtls-rprx-vision"
        echo -e "  ${BLUE}SID:${NC}    ${SHORT_ID}"
        echo ""
        echo -e "${CYAN}--------------------------------------------${NC}"
        echo -e "${GREEN}分享链接:${NC}"
        echo ""
        echo -e "${reality_link}"
        echo ""

        # 生成二维码（如果 qrencode 可用）
        if command -v qrencode &>/dev/null; then
            echo -e "${CYAN}--------------------------------------------${NC}"
            echo -e "${GREEN}二维码:${NC}"
            echo ""
            qrencode -t ANSIUTF8 "${reality_link}"
        fi
    fi

    # 极速抗封锁模式 (Hysteria 2)
    if [[ "$mode" == "hysteria" ]]; then
        local port="${PORT:-8443}"
        local sni="${SNI:-www.bing.com}"
        local mport_param=""
        local hop_desc="未启用"

        if [[ "${HOPPING_ENABLED:-false}" == "true" && -n "${HOP_START:-}" && -n "${HOP_END:-}" ]]; then
            mport_param="&mport=${HOP_START}-${HOP_END}"
            hop_desc="${HOP_START}-${HOP_END}"
        fi

        local hy2_link="hysteria2://${PASSWORD}@${SERVER_IP}:${port}/?insecure=1&sni=${sni}${mport_param}#Hysteria2"

        echo ""
        echo -e "${GREEN}[极速抗封锁模式 - Hysteria 2 (UDP)]${NC}"
        echo ""
        echo -e "  ${BLUE}地址:${NC}       ${SERVER_IP}"
        echo -e "  ${BLUE}主端口:${NC}     ${port} (UDP)"
        echo -e "  ${BLUE}端口跳跃:${NC}   ${hop_desc}"
        echo -e "  ${BLUE}认证密码:${NC}   ${PASSWORD}"
        echo -e "  ${BLUE}伪装 SNI:${NC}   ${sni}"
        echo -e "  ${BLUE}传输协议:${NC}   UDP / QUIC"
        echo -e "  ${BLUE}证书校验:${NC}   允许不安全 (Insecure / Skip-cert-verify: true)"
        echo ""
        echo -e "${CYAN}--------------------------------------------${NC}"
        echo -e "${GREEN}分享链接:${NC}"
        echo ""
        echo -e "${hy2_link}"
        echo ""

        # 生成二维码（如果 qrencode 可用）
        if command -v qrencode &>/dev/null; then
            echo -e "${CYAN}--------------------------------------------${NC}"
            echo -e "${GREEN}二维码:${NC}"
            echo ""
            qrencode -t ANSIUTF8 "${hy2_link}"
        fi
    fi

    # CDN 模式信息
    if [[ "$mode" == "cdn" ]]; then
        local cdn_address="${DOMAIN:-<YOUR_DOMAIN>}"
        local cdn_link="vless://${UUID}@${cdn_address}:443?encryption=none&security=tls&sni=${cdn_address}&fp=chrome&type=xhttp&host=${cdn_address}&path=%2Fvless-xhttp#Xray-CDN"

        echo ""
        echo -e "${GREEN}[CDN 模式 - VLESS + XHTTP + Cloudflare]${NC}"
        echo ""
        echo -e "  ${BLUE}地址:${NC}   ${cdn_address}"
        echo -e "  ${BLUE}端口:${NC}   443"
        echo -e "  ${BLUE}UUID:${NC}   ${UUID}"
        echo -e "  ${BLUE}传输:${NC}   xhttp"
        echo -e "  ${BLUE}路径:${NC}   /vless-xhttp"
        echo -e "  ${BLUE}TLS:${NC}    开启"
        echo -e "  ${BLUE}SNI:${NC}    ${cdn_address}"
        echo -e "  ${BLUE}证书:${NC}   ${CERT_FILE}"
        echo -e "  ${BLUE}私钥:${NC}   ${KEY_FILE}"
        echo ""
        echo -e "${YELLOW}Cloudflare 配置:${NC}"
        echo -e "  1. 添加 A 记录指向 ${SERVER_IP}"
        echo -e "  2. 开启橙色云朵（代理）"
        echo -e "  3. SSL/TLS 设置为 Full（不选 Strict）"
        echo ""
        echo -e "${CYAN}--------------------------------------------${NC}"
        echo -e "${GREEN}CDN 分享链接:${NC}"
        echo ""
        echo -e "${cdn_link}"
        echo ""

        # 生成二维码（如果 qrencode 可用）
        if command -v qrencode &>/dev/null; then
            echo -e "${CYAN}--------------------------------------------${NC}"
            echo -e "${GREEN}CDN 二维码:${NC}"
            echo ""
            qrencode -t ANSIUTF8 "${cdn_link}"
        fi
    fi

    echo ""
    if ! command -v qrencode &>/dev/null; then
        echo -e "${CYAN}============================================${NC}"
        echo -e "${YELLOW}提示: 安装 qrencode 可显示二维码${NC}"
        echo -e "${CYAN}============================================${NC}"
        echo ""
    fi
}

# 重启服务
restart_service() {
    resolve_service_vars
    log_info "重启 ${SERVICE_NAME} 服务..."
    stop_service
    sleep 1
    start_service
    check_service_health
    log_info "重启完成"
}

# ==================== 主流程 ====================

# 交互式管理控制台
show_menu() {
    resolve_service_vars

    local status_text="${RED}未运行${NC}"
    if is_running; then
        status_text="${GREEN}● 运行中${NC}"
    fi

    local core_name="未安装"
    local mode_name="无"
    local port_info="无"
    local dest_info="无"

    if [[ -f "${INSTALL_INFO}" ]]; then
        # shellcheck disable=SC1090
        source "${INSTALL_INFO}"
        if [[ "${DEPLOY_MODE:-}" == "hysteria" ]]; then
            core_name="Hysteria 2"
            mode_name="极速模式 (UDP/QUIC)"
            port_info="${PORT:-8443}"
            dest_info="${SNI:-www.bing.com}"
        elif [[ "${DEPLOY_MODE:-}" == "cdn" ]]; then
            core_name="Xray-core"
            mode_name="CDN 模式 (VLESS+XHTTP)"
            port_info="443"
            dest_info="${DOMAIN:-}"
        else
            core_name="Xray-core"
            mode_name="直连模式 (VLESS+Reality)"
            port_info="${PORT:-443}"
            dest_info="${SNI:-}"
        fi
    fi

    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${GREEN}      Proxy-Toolkit 节点管理控制台${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo -e "  服务状态: [ ${status_text} ]"
    echo -e "  核心程序: ${CYAN}${core_name}${NC}"
    echo -e "  部署模式: ${CYAN}${mode_name}${NC}"
    echo -e "  监听端口: ${CYAN}${port_info}${NC}"
    [[ -n "$dest_info" && "$dest_info" != "无" ]] && echo -e "  伪装目标: ${CYAN}${dest_info}${NC}"
    echo -e "${CYAN}--------------------------------------------${NC}"
    echo -e "  ${BLUE}1)${NC} 安装 / 重建节点服务"
    echo -e "  ${BLUE}2)${NC} 查看当前节点信息与分享链接"
    echo -e "  ${BLUE}3)${NC} 重启服务"
    echo -e "  ${BLUE}4)${NC} 停止服务"
    echo -e "  ${BLUE}5)${NC} 更新核心程序 (Xray / Hysteria 2)"
    echo -e "  ${BLUE}6)${NC} 开启 BBR 拥塞控制"
    echo -e "  ${BLUE}7)${NC} 开启 ICMP (允许 Ping)"
    echo -e "  ${BLUE}8)${NC} 卸载节点服务"
    echo -e "  ${BLUE}0)${NC} 退出面板"
    echo -e "${CYAN}--------------------------------------------${NC}"
    echo -n "请输入选项 [0-8, 默认 2]: "
    local opt
    read -r opt
    opt="${opt:-2}"

    case "$opt" in
    1) main install ;;
    2) main show ;;
    3) main restart ;;
    4)
        check_root
        stop_service
        log_info "服务已停止"
        ;;
    5) main update ;;
    6) main bbr ;;
    7) main icmp ;;
    8) main uninstall ;;
    0) exit 0 ;;
    *)
        log_warn "无效选项"
        ;;
    esac
}

show_usage() {
    echo ""
    echo -e "${CYAN}proxy-toolkit / xray-setup${NC} - 极简代理一键部署脚本"
    echo ""
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  install     安装节点服务并生成配置"
    echo "              支持三种模式："
    echo "                1. 直连模式 (VLESS + Reality) - TCP 极简伪装"
    echo "                2. 极速模式 (Hysteria 2) - UDP 弱网加速/端口跳跃"
    echo "                3. CDN 模式 (VLESS + XHTTP + Cloudflare) - 隐藏 IP 防封"
    echo "  uninstall   卸载当前节点服务"
    echo "  status      查看服务状态"
    echo "  show        显示节点信息和分享链接"
    echo "  restart     重启服务"
    echo "  update      更新核心程序"
    echo "  bbr         开启 BBR 拥塞控制"
    echo "  icmp        开启 ICMP (允许 ping)"
    echo "  help        显示此帮助信息"
    echo ""
}

main() {
    local cmd="${1:-}"

    if [[ -z "$cmd" ]]; then
        show_menu
        return
    fi

    case "$cmd" in
    install)
        check_root
        echo ""
        echo -e "${CYAN}============================================${NC}"
        echo -e "${GREEN}  Proxy-Toolkit 节点一键安装${NC}"
        echo -e "${CYAN}============================================${NC}"
        echo ""

        # 选择部署模式
        local mode
        mode=$(select_mode)

        # 停止可能正在运行的旧服务，避免端口冲突
        resolve_service_vars
        stop_service 2>/dev/null || true

        install_deps
        enable_bbr
        enable_icmp

        if [[ "$mode" == "direct" ]]; then
            local port
            port=$(get_reality_port)
            check_port "$port" "tcp"
            local server_ip
            server_ip=$(get_server_ip)
            local reality_sni
            reality_sni=$(get_reality_domain "$server_ip")
            install_xray
            generate_config "$mode" "" "$port" "$reality_sni"
            configure_firewall "$port" "tcp"
            install_service
            show_info
        elif [[ "$mode" == "hysteria" ]]; then
            local hy_settings
            hy_settings=$(get_hysteria_settings)
            local port
            local enable_hop
            local hop_start
            local hop_end
            local password
            local sni
            local server_ip

            port=$(echo "$hy_settings" | cut -d'|' -f1)
            enable_hop=$(echo "$hy_settings" | cut -d'|' -f2)
            hop_start=$(echo "$hy_settings" | cut -d'|' -f3)
            hop_end=$(echo "$hy_settings" | cut -d'|' -f4)
            password=$(echo "$hy_settings" | cut -d'|' -f5)
            sni=$(echo "$hy_settings" | cut -d'|' -f6)
            server_ip=$(get_server_ip)

            check_port "$port" "udp"
            install_hysteria
            generate_hysteria_cert "$sni"
            generate_hysteria_config "$port" "$password" "$sni"
            configure_firewall "$port" "udp"

            if [[ "$enable_hop" == "true" && -n "$hop_start" && -n "$hop_end" ]]; then
                configure_port_hopping "$port" "$hop_start" "$hop_end"
                configure_firewall "${hop_start}:${hop_end}" "udp"
            fi

            install_hysteria_service
            save_hysteria_info "$port" "$enable_hop" "$hop_start" "$hop_end" "$password" "$sni" "$server_ip"
            show_info
        elif [[ "$mode" == "cdn" ]]; then
            local domain
            domain=$(get_domain)
            local port="443"
            check_port "$port" "tcp"
            install_xray
            generate_config "$mode" "$domain" "$port"
            configure_firewall "$port" "tcp"
            install_service
            show_info
        fi
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
        uninstall_node
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
        update_node
        ;;
    help | --help | -h)
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
