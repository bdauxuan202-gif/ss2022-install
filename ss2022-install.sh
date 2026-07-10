#!/usr/bin/env bash
#
# SS2022 一键安装/管理脚本 (Shadowsocks 2022 - shadowsocks-rust)
# 支持自定义参数、菜单管理、更新、查看信息、改配置、卸载
#
# 用法:
#   chmod +x ss2022-install.sh
#   sudo ./ss2022-install.sh              # 菜单模式
#   sudo ./ss2022-install.sh install      # 直接安装
#   sudo ./ss2022-install.sh update       # 更新内核
#   sudo ./ss2022-install.sh info         # 查看连接信息
#   sudo ./ss2022-install.sh config       # 修改配置
#   sudo ./ss2022-install.sh uninstall    # 卸载
#
# 非交互安装:
#   SS_PORT=8388 SS_METHOD=2022-blake3-aes-256-gcm SS_PASSWORD=auto \
#     sudo -E ./ss2022-install.sh install
#

set -euo pipefail

# ============================================================
# 默认参数（可在此处直接修改）
# ============================================================
DEFAULT_PORT=8388
DEFAULT_METHOD="2022-blake3-aes-256-gcm"
DEFAULT_PASSWORD=""
# 版本: latest 自动拉取 GitHub 最新版，也可写死如 1.24.0
SS_VERSION="${SS_VERSION:-latest}"
# 是否启用 IPv6 监听 (true/false)
ENABLE_IPV6="${ENABLE_IPV6:-false}"
# 下载加速镜像前缀，国内机器可改: https://ghfast.top/
MIRROR_PREFIX="${MIRROR_PREFIX:-}"
# 路径
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
INFO_FILE="${CONFIG_DIR}/client-info.txt"
SERVICE_NAME="shadowsocks-rust"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSCTL_FILE="/etc/sysctl.d/99-shadowsocks.conf"
GITHUB_API="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
GITHUB_RELEASE="https://github.com/shadowsocks/shadowsocks-rust/releases/download"

# ============================================================
# 颜色 / 日志
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }

# ============================================================
# 基础工具
# ============================================================
check_root() {
    [[ $EUID -eq 0 ]] || error "请使用 root 或 sudo 运行此脚本"
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID:-}"
        info "系统: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    else
        error "无法识别操作系统"
    fi
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "x86_64-unknown-linux-gnu" ;;
        aarch64|arm64)  echo "aarch64-unknown-linux-gnu" ;;
        armv7l)         echo "armv7-unknown-linux-gnueabihf" ;;
        *)              error "不支持的架构: $arch" ;;
    esac
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

is_installed() {
    [[ -x "${INSTALL_DIR}/ssserver" ]] && [[ -f "$CONFIG_FILE" ]]
}

is_running() {
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

# ============================================================
# 版本获取
# ============================================================
resolve_version() {
    if [[ "$SS_VERSION" != "latest" ]]; then
        echo "$SS_VERSION"
        return
    fi
    info "正在获取 shadowsocks-rust 最新版本..."
    local ver
    ver=$(curl -fsSL --connect-timeout 10 "$GITHUB_API" 2>/dev/null \
        | grep -oE '"tag_name":\s*"v[^"]+"' | head -1 | sed 's/.*"v//;s/"//') || true
    if [[ -z "$ver" ]]; then
        warn "无法获取最新版本，回退到 1.24.0"
        ver="1.24.0"
    fi
    echo "$ver"
}

installed_version() {
    if [[ -x "${INSTALL_DIR}/ssserver" ]]; then
        "${INSTALL_DIR}/ssserver" --version 2>/dev/null | head -1 || echo "unknown"
    else
        echo "未安装"
    fi
}

# ============================================================
# 密钥生成 / 校验
# ============================================================
key_len_for_method() {
    case "$1" in
        2022-blake3-aes-128-gcm) echo 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) echo 32 ;;
        *) echo 32 ;;
    esac
}

generate_password() {
    local method="$1"
    local key_len
    key_len=$(key_len_for_method "$method")
    openssl rand -base64 "$key_len" | tr -d '\n'
}

validate_password() {
    local method="$1" password="$2"
    local expected_len decoded
    expected_len=$(key_len_for_method "$method")
    # SS2022 密码应为 base64，解码后长度 = expected_len
    if ! decoded=$(echo -n "$password" | base64 -d 2>/dev/null | wc -c); then
        return 1
    fi
    # 允许部分客户端对 base64 做 padding 差异，按解码字节数判断
    [[ "$decoded" -eq "$expected_len" ]]
}

# ============================================================
# 端口检测
# ============================================================
port_in_use() {
    local port="$1"
    if command_exists ss; then
        ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$" && return 0
    fi
    if command_exists netstat; then
        netstat -lntu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
    fi
    return 1
}

# ============================================================
# 公网 IP
# ============================================================
get_public_ip() {
    local ip
    for url in "https://ifconfig.me" "https://ip.sb" "https://api.ipify.org" "https://icanhazip.com"; do
        ip=$(curl -fsS4 --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    # 本机网卡兜底
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-YOUR_SERVER_IP}"
}

# ============================================================
# 依赖
# ============================================================
install_deps() {
    info "检查并安装依赖..."
    case "$OS_ID" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq curl wget tar openssl ca-certificates coreutils >/dev/null 2>&1
            # 可选: 二维码
            apt-get install -y -qq qrencode >/dev/null 2>&1 || true
            ;;
        centos|rhel|rocky|alma|fedora|amzn)
            if command_exists dnf; then
                dnf install -y -q curl wget tar openssl ca-certificates >/dev/null 2>&1
                dnf install -y -q qrencode >/dev/null 2>&1 || true
            else
                yum install -y -q curl wget tar openssl ca-certificates >/dev/null 2>&1
                yum install -y -q qrencode >/dev/null 2>&1 || true
            fi
            ;;
        alpine)
            apk add --no-cache curl wget tar openssl ca-certificates >/dev/null 2>&1
            apk add --no-cache libqrencode-tools >/dev/null 2>&1 || true
            ;;
        *)
            warn "未识别包管理器，请确保已安装: curl wget tar openssl"
            ;;
    esac
    for bin in curl tar openssl; do
        command_exists "$bin" || error "缺少依赖: $bin"
    done
    ok "依赖就绪"
}

# ============================================================
# 下载安装二进制
# ============================================================
download_and_install() {
    local version arch filename url tmp_dir
    version=$(resolve_version)
    SS_VERSION="$version"
    arch=$(get_arch)
    filename="shadowsocks-v${version}.${arch}.tar.xz"
    url="${MIRROR_PREFIX}${GITHUB_RELEASE}/v${version}/${filename}"

    info "下载 shadowsocks-rust v${version} (${arch})..."
    info "URL: ${url}"

    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" RETURN
    cd "$tmp_dir"

    if ! curl -fL --connect-timeout 15 --retry 3 -o "$filename" "$url"; then
        # 无镜像时尝试 ghproxy 等备用
        local alt_url="https://ghfast.top/${GITHUB_RELEASE}/v${version}/${filename}"
        warn "主链接失败，尝试镜像: $alt_url"
        if ! curl -fL --connect-timeout 15 --retry 3 -o "$filename" "$alt_url"; then
            error "下载失败，请检查网络/版本: v${version}"
        fi
    fi

    info "解压安装..."
    tar -xf "$filename"
    # 兼容压缩包内是否有子目录
    local bin_dir="."
    if [[ -d "shadowsocks-v${version}.${arch}" ]]; then
        bin_dir="shadowsocks-v${version}.${arch}"
    fi

    install -m 755 "${bin_dir}/ssserver" "${INSTALL_DIR}/ssserver"
    [[ -f "${bin_dir}/sslocal" ]] && install -m 755 "${bin_dir}/sslocal" "${INSTALL_DIR}/sslocal" || true
    [[ -f "${bin_dir}/ssurl" ]]   && install -m 755 "${bin_dir}/ssurl"   "${INSTALL_DIR}/ssurl"   || true
    [[ -f "${bin_dir}/ssmanager" ]] && install -m 755 "${bin_dir}/ssmanager" "${INSTALL_DIR}/ssmanager" || true
    [[ -f "${bin_dir}/ssservice" ]] && install -m 755 "${bin_dir}/ssservice" "${INSTALL_DIR}/ssservice" || true

    ok "已安装: $("${INSTALL_DIR}/ssserver" --version | head -1)"
}

# ============================================================
# 参数收集
# ============================================================
collect_params() {
    echo ""
    echo -e "${CYAN}${BOLD}======== SS2022 参数配置 ========${NC}"
    echo ""

    # 端口
    if [[ -n "${SS_PORT:-}" ]]; then
        PORT="$SS_PORT"
    else
        read -rp "$(echo -e "${GREEN}[1/4]${NC} 服务端口 [默认 ${DEFAULT_PORT}]: ")" PORT
        PORT="${PORT:-$DEFAULT_PORT}"
    fi
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        error "无效端口: $PORT"
    fi
    if port_in_use "$PORT"; then
        # 若是自己服务占用则放过
        if is_running && grep -q "\"server_port\": ${PORT}" "$CONFIG_FILE" 2>/dev/null; then
            info "端口 ${PORT} 已由本服务占用，将复用"
        else
            warn "端口 ${PORT} 似乎已被占用，安装后可能启动失败"
            if [[ -z "${SS_PORT:-}" ]]; then
                read -rp "仍要使用该端口? [y/N]: " c
                [[ "${c:-N}" =~ ^[Yy]$ ]] || error "已取消，请换端口"
            fi
        fi
    fi

    # 加密
    if [[ -n "${SS_METHOD:-}" ]]; then
        METHOD="$SS_METHOD"
    else
        echo ""
        echo "  加密方式:"
        echo "    1) 2022-blake3-aes-256-gcm       (推荐)"
        echo "    2) 2022-blake3-aes-128-gcm"
        echo "    3) 2022-blake3-chacha20-poly1305"
        read -rp "$(echo -e "${GREEN}[2/4]${NC} 选择 [1/2/3, 默认 1]: ")" method_choice
        case "${method_choice:-1}" in
            1) METHOD="2022-blake3-aes-256-gcm" ;;
            2) METHOD="2022-blake3-aes-128-gcm" ;;
            3) METHOD="2022-blake3-chacha20-poly1305" ;;
            *) METHOD="$DEFAULT_METHOD" ;;
        esac
    fi

    # 密钥
    if [[ -n "${SS_PASSWORD:-}" && "${SS_PASSWORD}" != "auto" ]]; then
        PASSWORD="$SS_PASSWORD"
        if ! validate_password "$METHOD" "$PASSWORD"; then
            warn "提供的密钥长度可能不符合 ${METHOD} 要求 (期望解码后 $(key_len_for_method "$METHOD") 字节)"
        fi
    elif [[ -n "$DEFAULT_PASSWORD" ]]; then
        PASSWORD="$DEFAULT_PASSWORD"
    else
        echo ""
        info "SS2022 密钥必须是 Base64，解码后长度: AES-128=16 / AES-256&ChaCha=32 字节"
        if [[ -z "${SS_PASSWORD:-}" ]]; then
            read -rp "$(echo -e "${GREEN}[3/4]${NC} 密钥 [留空自动生成]: ")" PASSWORD
        else
            PASSWORD=""
        fi
        if [[ -z "$PASSWORD" || "$PASSWORD" == "auto" ]]; then
            PASSWORD=$(generate_password "$METHOD")
            info "已自动生成密钥: ${PASSWORD}"
        elif ! validate_password "$METHOD" "$PASSWORD"; then
            warn "密钥可能不符合规范，仍将写入配置"
        fi
    fi

    # IPv6
    if [[ -n "${ENABLE_IPV6:-}" && "${ENABLE_IPV6}" != "false" && "${ENABLE_IPV6}" != "true" ]]; then
        :
    fi
    if [[ -z "${SS_PORT:-}" ]]; then
        read -rp "$(echo -e "${GREEN}[4/4]${NC} 启用 IPv6 监听? [y/N]: ")" v6
        if [[ "${v6:-N}" =~ ^[Yy]$ ]]; then
            ENABLE_IPV6="true"
        else
            ENABLE_IPV6="false"
        fi
    fi

    echo ""
    echo -e "${CYAN}--------------------------------${NC}"
    echo -e "  端口:  ${GREEN}${PORT}${NC}"
    echo -e "  加密:  ${GREEN}${METHOD}${NC}"
    echo -e "  密钥:  ${GREEN}${PASSWORD}${NC}"
    echo -e "  IPv6:  ${GREEN}${ENABLE_IPV6}${NC}"
    echo -e "${CYAN}--------------------------------${NC}"
    echo ""

    if [[ -z "${SS_PORT:-}" && -z "${SS_PASSWORD:-}" ]]; then
        read -rp "确认安装? [Y/n]: " confirm
        [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }
    fi
}

# ============================================================
# 配置文件
# ============================================================
create_config() {
    info "写入配置: ${CONFIG_FILE}"
    mkdir -p "$CONFIG_DIR"
    # 备份旧配置
    if [[ -f "$CONFIG_FILE" ]]; then
        cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        info "已备份旧配置"
    fi

    local server_bind='["0.0.0.0"]'
    if [[ "${ENABLE_IPV6}" == "true" ]]; then
        server_bind='["0.0.0.0","::"]'
    fi

    cat > "$CONFIG_FILE" <<EOF
{
    "servers": [
        {
            "server": ${server_bind},
            "server_port": ${PORT},
            "password": "${PASSWORD}",
            "method": "${METHOD}",
            "timeout": 300,
            "mode": "tcp_and_udp"
        }
    ],
    "mode": "tcp_and_udp",
    "nofile": 51200,
    "ipv6_first": false,
    "fast_open": true
}
EOF
    chmod 600 "$CONFIG_FILE"
    ok "配置已生成"
}

# 兼容旧单服务器 JSON 的读取
load_config_vars() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "未找到配置: $CONFIG_FILE"
    fi
    PORT=""; METHOD=""; PASSWORD=""
    if command_exists python3; then
        local parsed
        parsed=$(python3 -c "
import json
with open('${CONFIG_FILE}') as f:
    c = json.load(f)
s = c['servers'][0] if isinstance(c.get('servers'), list) and c['servers'] else c
print(s.get('server_port') or s.get('port') or '')
print(s.get('method') or '')
print(s.get('password') or '')
" 2>/dev/null) || true
        if [[ -n "$parsed" ]]; then
            PORT=$(echo "$parsed" | sed -n '1p')
            METHOD=$(echo "$parsed" | sed -n '2p')
            PASSWORD=$(echo "$parsed" | sed -n '3p')
        fi
    fi
    if [[ -z "${PORT}" || -z "${METHOD}" || -z "${PASSWORD}" ]]; then
        PORT=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' "$CONFIG_FILE" | head -1 | grep -oE '[0-9]+')
        METHOD=$(grep -oE '"method"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
        PASSWORD=$(grep -oE '"password"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    fi
    [[ -n "${PORT}" && -n "${METHOD}" && -n "${PASSWORD}" ]] || error "解析配置失败"
}

# ============================================================
# systemd
# ============================================================
create_service() {
    info "配置 systemd 服务..."
    if ! command_exists systemctl; then
        warn "无 systemctl，请手动运行: ${INSTALL_DIR}/ssserver -c ${CONFIG_FILE}"
        return
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Shadowsocks-Rust Server (SS2022)
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/ssserver -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=51200
# 安全加固
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if is_running; then
        ok "服务已启动"
    else
        warn "服务启动失败，查看日志:"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
        error "请检查配置后: systemctl restart ${SERVICE_NAME}"
    fi
}

# ============================================================
# 防火墙
# ============================================================
configure_firewall() {
    info "配置防火墙放行端口 ${PORT}/tcp+udp..."
    local done=0

    if command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld 已放行"
        done=1
    fi

    if command_exists ufw && ufw status 2>/dev/null | grep -qi "active"; then
        ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
        info "ufw 已放行"
        done=1
    fi

    if command_exists iptables; then
        # 避免重复插入：简单检查
        if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        fi
        if ! iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        fi
        done=1
    fi

    if [[ $done -eq 0 ]]; then
        warn "未检测到防火墙，请手动放行 ${PORT}"
    else
        ok "防火墙处理完成"
    fi
    warn "若使用云厂商安全组，请在控制台放行 TCP/UDP ${PORT}"
}

# ============================================================
# BBR / 内核优化
# ============================================================
optimize_sysctl() {
    info "写入网络优化参数..."
    cat > "$SYSCTL_FILE" <<'EOF'
# Shadowsocks / SS2022
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65535
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 16384
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "部分 sysctl 未生效（内核可能不支持 BBR）"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        ok "BBR 已启用"
    else
        warn "BBR 未启用，可升级内核后再试"
    fi
}

# ============================================================
# 连接信息 / SS 链接
# ============================================================
build_ss_uri() {
    local server_ip="${1}"
    local userinfo
    userinfo=$(printf '%s' "${METHOD}:${PASSWORD}" | base64 -w0 2>/dev/null \
        || printf '%s' "${METHOD}:${PASSWORD}" | base64 | tr -d '\n')
    # 去掉 base64 中的换行
    userinfo=$(echo -n "$userinfo" | tr -d '\n')
    printf 'ss://%s@%s:%s#SS2022-%s' "$userinfo" "$server_ip" "$PORT" "$PORT"
}

save_and_show_info() {
    local server_ip ss_uri
    server_ip=$(get_public_ip)
    ss_uri=$(build_ss_uri "$server_ip")
    local ver
    ver=$(installed_version)

    mkdir -p "$CONFIG_DIR"
    cat > "$INFO_FILE" <<EOF
======== Shadowsocks 2022 客户端信息 ========
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
服务端版本: ${ver}

服务器地址: ${server_ip}
端口:       ${PORT}
密钥:       ${PASSWORD}
加密方式:   ${METHOD}
协议:       Shadowsocks 2022
传输:       TCP + UDP

SS 链接:
${ss_uri}

服务管理:
  systemctl status ${SERVICE_NAME}
  systemctl restart ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f

配置文件: ${CONFIG_FILE}
客户端信息: ${INFO_FILE}
============================================
EOF
    chmod 600 "$INFO_FILE"

    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║          Shadowsocks 2022 就绪                    ║${NC}"
    echo -e "${CYAN}${BOLD}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  地址:   ${GREEN}${server_ip}${NC}"
    echo -e "${CYAN}║${NC}  端口:   ${GREEN}${PORT}${NC}"
    echo -e "${CYAN}║${NC}  密钥:   ${GREEN}${PASSWORD}${NC}"
    echo -e "${CYAN}║${NC}  加密:   ${GREEN}${METHOD}${NC}"
    echo -e "${CYAN}║${NC}  版本:   ${GREEN}${ver}${NC}"
    echo -e "${CYAN}${BOLD}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  配置:   ${CONFIG_FILE}"
    echo -e "${CYAN}║${NC}  信息:   ${INFO_FILE}"
    echo -e "${CYAN}║${NC}  状态:   systemctl status ${SERVICE_NAME}"
    echo -e "${CYAN}║${NC}  日志:   journalctl -u ${SERVICE_NAME} -f"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}SS 链接:${NC}"
    echo "$ss_uri"
    echo ""

    if command_exists qrencode; then
        echo -e "${YELLOW}二维码 (扫码导入):${NC}"
        qrencode -t ANSIUTF8 "$ss_uri" 2>/dev/null || true
        echo ""
    fi
}

# ============================================================
# 子命令: install / update / info / config / restart / uninstall
# ============================================================
do_install() {
    check_root
    check_os
    if is_installed; then
        warn "检测到已安装: $(installed_version)"
        if [[ -z "${SS_PORT:-}" ]]; then
            read -rp "重新安装会覆盖配置，继续? [y/N]: " c
            [[ "${c:-N}" =~ ^[Yy]$ ]] || { info "已取消"; return; }
        fi
    fi
    collect_params
    install_deps
    download_and_install
    create_config
    create_service
    configure_firewall
    optimize_sysctl
    save_and_show_info
}

do_update() {
    check_root
    is_installed || error "尚未安装，请先 install"
    check_os
    install_deps
    local old new
    old=$(installed_version)
    download_and_install
    new=$(installed_version)
    systemctl restart "$SERVICE_NAME" 2>/dev/null || true
    sleep 1
    if is_running; then
        ok "更新完成: ${old} -> ${new}"
    else
        error "更新后服务未启动，请检查日志"
    fi
}

do_info() {
    is_installed || error "尚未安装"
    load_config_vars
    save_and_show_info
}

do_config() {
    check_root
    is_installed || error "尚未安装"
    load_config_vars
    info "当前: 端口=${PORT} 加密=${METHOD}"
    echo ""
    echo "  1) 修改端口"
    echo "  2) 修改加密方式"
    echo "  3) 重新生成密钥"
    echo "  4) 手动输入密钥"
    echo "  5) 切换 IPv6"
    echo "  0) 返回"
    read -rp "选择: " choice
    case "$choice" in
        1)
            read -rp "新端口: " new_port
            [[ "$new_port" =~ ^[0-9]+$ ]] || error "端口无效"
            PORT="$new_port"
            ;;
        2)
            echo "1) aes-256  2) aes-128  3) chacha20"
            read -rp "选择: " m
            case "$m" in
                1) METHOD="2022-blake3-aes-256-gcm" ;;
                2) METHOD="2022-blake3-aes-128-gcm" ;;
                3) METHOD="2022-blake3-chacha20-poly1305" ;;
                *) error "无效选项" ;;
            esac
            PASSWORD=$(generate_password "$METHOD")
            info "加密变更，已重新生成密钥: $PASSWORD"
            ;;
        3)
            PASSWORD=$(generate_password "$METHOD")
            info "新密钥: $PASSWORD"
            ;;
        4)
            read -rp "新密钥(Base64): " PASSWORD
            [[ -n "$PASSWORD" ]] || error "密钥不能为空"
            ;;
        5)
            read -rp "启用 IPv6? [y/N]: " v6
            ENABLE_IPV6=$([[ "${v6:-N}" =~ ^[Yy]$ ]] && echo true || echo false)
            ;;
        0) return ;;
        *) error "无效选项" ;;
    esac
    create_config
    configure_firewall
    systemctl restart "$SERVICE_NAME"
    sleep 1
    is_running && ok "配置已生效" || error "重启失败"
    save_and_show_info
}

do_restart() {
    check_root
    is_installed || error "尚未安装"
    systemctl restart "$SERVICE_NAME"
    sleep 1
    is_running && ok "已重启" || error "重启失败，查看: journalctl -u ${SERVICE_NAME} -n 50"
}

do_status() {
    if ! is_installed; then
        warn "未安装"
        return
    fi
    echo "二进制: $(installed_version)"
    echo "配置:   $CONFIG_FILE"
    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || true
}

do_uninstall() {
    check_root
    echo ""
    warn "将删除服务、二进制、配置目录"
    read -rp "确认卸载? [y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { info "已取消"; return; }

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true

    rm -f "${INSTALL_DIR}/ssserver" "${INSTALL_DIR}/sslocal" "${INSTALL_DIR}/ssurl" \
          "${INSTALL_DIR}/ssmanager" "${INSTALL_DIR}/ssservice"
    rm -rf "$CONFIG_DIR"
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
    ok "卸载完成"
}

# ============================================================
# 菜单
# ============================================================
show_menu() {
    clear 2>/dev/null || true
    local status_str ver_str
    if is_installed; then
        ver_str=$(installed_version)
        if is_running; then
            status_str="${GREEN}运行中${NC} | ${ver_str}"
        else
            status_str="${RED}已停止${NC} | ${ver_str}"
        fi
    else
        status_str="${YELLOW}未安装${NC}"
    fi

    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   SS2022 管理脚本 (shadowsocks-rust) ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  状态: ${status_str}"
    echo ""
    echo "  1) 安装 / 重装"
    echo "  2) 更新内核"
    echo "  3) 查看连接信息 / 二维码"
    echo "  4) 修改配置"
    echo "  5) 重启服务"
    echo "  6) 服务状态"
    echo "  7) 卸载"
    echo "  0) 退出"
    echo ""
    read -rp "请选择 [0-7]: " op
    case "$op" in
        1) do_install ;;
        2) do_update ;;
        3) do_info ;;
        4) do_config ;;
        5) do_restart ;;
        6) do_status ;;
        7) do_uninstall ;;
        0) exit 0 ;;
        *) warn "无效选项"; sleep 1 ;;
    esac
    echo ""
    read -rp "按回车返回菜单..." _
}

print_help() {
    cat <<'EOF'
SS2022 一键安装/管理脚本

用法:
  sudo ./ss2022-install.sh              # 交互菜单
  sudo ./ss2022-install.sh install      # 安装
  sudo ./ss2022-install.sh update       # 更新
  sudo ./ss2022-install.sh info         # 连接信息
  sudo ./ss2022-install.sh config       # 改配置
  sudo ./ss2022-install.sh restart      # 重启
  sudo ./ss2022-install.sh status       # 状态
  sudo ./ss2022-install.sh uninstall    # 卸载
  ./ss2022-install.sh help              # 帮助

环境变量 (非交互安装):
  SS_PORT=8388
  SS_METHOD=2022-blake3-aes-256-gcm
  SS_PASSWORD=auto|你的Base64密钥
  SS_VERSION=latest|1.24.0
  ENABLE_IPV6=true|false
  MIRROR_PREFIX=https://ghfast.top/     # 下载加速

示例:
  SS_PORT=443 SS_PASSWORD=auto sudo -E ./ss2022-install.sh install
EOF
}

# ============================================================
# 入口
# ============================================================
main() {
    case "${1:-}" in
        install|i)     do_install ;;
        update|u)      do_update ;;
        info|show)     do_info ;;
        config|cfg)    do_config ;;
        restart)       do_restart ;;
        status)        do_status ;;
        uninstall|remove|rm) do_uninstall ;;
        help|-h|--help) print_help ;;
        "")
            check_root
            while true; do show_menu; done
            ;;
        *)
            warn "未知命令: $1"
            print_help
            exit 1
            ;;
    esac
}

main "$@"
