#!/usr/bin/env bash
#
# SS2022 一键安装脚本 (Shadowsocks 2022 - shadowsocks-rust)
# 支持自定义参数，适用于 Debian/Ubuntu 和 CentOS/RHEL 系统
#
# 用法:
#   chmod +x ss2022-install.sh
#   sudo ./ss2022-install.sh
#
# 可通过环境变量预设参数（跳过交互）:
#   SS_PORT=8388 SS_PASSWORD=auto SS_METHOD=2022-blake3-aes-256-gcm sudo -E ./ss2022-install.sh
#

set -euo pipefail

# ============================================================
# 默认参数（可在此处直接修改，或运行时交互输入）
# ============================================================
DEFAULT_PORT=8388
DEFAULT_METHOD="2022-blake3-aes-256-gcm"
# 留空则自动生成; 也可预填一个 Base64 密钥
DEFAULT_PASSWORD=""
# shadowsocks-rust 版本
SS_VERSION="${SS_VERSION:-1.21.2}"
# 安装目录
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"

# ============================================================
# 颜色输出
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ============================================================
# 前置检查
# ============================================================
check_root() {
    [[ $EUID -eq 0 ]] || error "请使用 root 用户或 sudo 运行此脚本"
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
        info "检测到系统: ${PRETTY_NAME}"
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

# ============================================================
# 生成符合 SS2022 要求的 Base64 密钥
# ============================================================
generate_password() {
    local method="$1"
    local key_len
    case "$method" in
        2022-blake3-aes-128-gcm)       key_len=16 ;;
        2022-blake3-aes-256-gcm)       key_len=32 ;;
        2022-blake3-chacha20-poly1305) key_len=32 ;;
        *) key_len=32 ;;
    esac
    openssl rand -base64 "$key_len"
}

# ============================================================
# 交互式参数收集
# ============================================================
collect_params() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}   Shadowsocks 2022 参数配置${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # 端口
    if [[ -n "${SS_PORT:-}" ]]; then
        PORT="$SS_PORT"
    else
        read -rp "$(echo -e "${GREEN}[1/3]${NC} 服务端口 [默认: ${DEFAULT_PORT}]: ")" PORT
        PORT="${PORT:-$DEFAULT_PORT}"
    fi
    # 端口校验
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        error "无效端口号: $PORT"
    fi

    # 加密方式
    echo ""
    echo "  可选加密方式 (SS2022):"
    echo "    1) 2022-blake3-aes-256-gcm      (推荐，安全性最高)"
    echo "    2) 2022-blake3-aes-128-gcm      (性能稍好)"
    echo "    3) 2022-blake3-chacha20-poly1305 (适合无 AES 硬件加速的设备)"
    echo ""
    if [[ -n "${SS_METHOD:-}" ]]; then
        METHOD="$SS_METHOD"
    else
        read -rp "$(echo -e "${GREEN}[2/3]${NC} 选择加密方式 [1/2/3, 默认: 1]: ")" method_choice
        case "${method_choice:-1}" in
            1) METHOD="2022-blake3-aes-256-gcm" ;;
            2) METHOD="2022-blake3-aes-128-gcm" ;;
            3) METHOD="2022-blake3-chacha20-poly1305" ;;
            *) METHOD="$DEFAULT_METHOD" ;;
        esac
    fi

    # 密码
    if [[ -n "${SS_PASSWORD:-}" && "${SS_PASSWORD}" != "auto" ]]; then
        PASSWORD="$SS_PASSWORD"
    elif [[ -n "$DEFAULT_PASSWORD" ]]; then
        PASSWORD="$DEFAULT_PASSWORD"
    else
        echo ""
        info "SS2022 要求使用 Base64 编码的密钥"
        read -rp "$(echo -e "${GREEN}[3/3]${NC} 密钥 [留空自动生成]: ")" PASSWORD
        if [[ -z "$PASSWORD" ]]; then
            PASSWORD=$(generate_password "$METHOD")
            info "已自动生成密钥: ${PASSWORD}"
        fi
    fi

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "  端口:     ${GREEN}${PORT}${NC}"
    echo -e "  加密:     ${GREEN}${METHOD}${NC}"
    echo -e "  密钥:     ${GREEN}${PASSWORD}${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    if [[ -z "${SS_PORT:-}" ]]; then
        read -rp "确认以上配置? [Y/n]: " confirm
        [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }
    fi
}

# ============================================================
# 安装依赖
# ============================================================
install_deps() {
    info "安装必要依赖..."
    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq curl wget tar openssl >/dev/null 2>&1
            ;;
        centos|rhel|rocky|alma|fedora)
            yum install -y -q curl wget tar openssl >/dev/null 2>&1
            ;;
        *)
            warn "未识别的包管理器，请确保已安装 curl, wget, tar, openssl"
            ;;
    esac
}

# ============================================================
# 下载并安装 shadowsocks-rust
# ============================================================
install_ssrust() {
    local arch
    arch=$(get_arch)
    local filename="shadowsocks-v${SS_VERSION}.${arch}.tar.xz"
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${SS_VERSION}/${filename}"

    info "下载 shadowsocks-rust v${SS_VERSION} (${arch})..."

    local tmp_dir
    tmp_dir=$(mktemp -d)
    cd "$tmp_dir"

    if ! wget -q --show-progress -O "$filename" "$url"; then
        error "下载失败，请检查网络或版本号: ${url}"
    fi

    info "解压安装..."
    tar -xf "$filename"

    # 安装二进制文件
    install -m 755 ssserver "${INSTALL_DIR}/ssserver"
    install -m 755 sslocal  "${INSTALL_DIR}/sslocal"  2>/dev/null || true
    install -m 755 ssurl    "${INSTALL_DIR}/ssurl"     2>/dev/null || true

    cd /
    rm -rf "$tmp_dir"

    info "ssserver 已安装到 ${INSTALL_DIR}/ssserver"
    "${INSTALL_DIR}/ssserver" --version
}

# ============================================================
# 生成配置文件
# ============================================================
create_config() {
    info "生成配置文件..."
    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "method": "${METHOD}",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "nameserver": "8.8.8.8",
    "ipv6_first": false
}
EOF

    chmod 600 "$CONFIG_FILE"
    info "配置文件: ${CONFIG_FILE}"
}

# ============================================================
# 创建 systemd 服务
# ============================================================
create_service() {
    info "配置 systemd 服务..."
    cat > /etc/systemd/system/shadowsocks-rust.service <<EOF
[Unit]
Description=Shadowsocks-Rust Server (SS2022)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/ssserver -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=51200

# 安全加固
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/
ReadWritePaths=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadowsocks-rust
    systemctl restart shadowsocks-rust

    if systemctl is-active --quiet shadowsocks-rust; then
        info "服务启动成功 ✓"
    else
        error "服务启动失败，请检查日志: journalctl -u shadowsocks-rust -n 50"
    fi
}

# ============================================================
# 配置防火墙
# ============================================================
configure_firewall() {
    info "配置防火墙规则..."

    # iptables
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld 规则已添加"
    fi

    # ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
        ufw allow "$PORT"/udp >/dev/null 2>&1 || true
        info "ufw 规则已添加"
    fi
}

# ============================================================
# 优化系统参数
# ============================================================
optimize_sysctl() {
    info "优化系统网络参数..."
    local sysctl_conf="/etc/sysctl.d/99-shadowsocks.conf"
    cat > "$sysctl_conf" <<'EOF'
# SS2022 网络优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65535
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
EOF
    sysctl -p "$sysctl_conf" >/dev/null 2>&1 || warn "部分 sysctl 参数未生效（可能需要更高版本内核）"
}

# ============================================================
# 打印连接信息
# ============================================================
show_result() {
    local server_ip
    server_ip=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "YOUR_SERVER_IP")

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Shadowsocks 2022 安装完成!                  ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  服务器:  ${GREEN}${server_ip}${NC}"
    echo -e "${CYAN}║${NC}  端口:    ${GREEN}${PORT}${NC}"
    echo -e "${CYAN}║${NC}  密钥:    ${GREEN}${PASSWORD}${NC}"
    echo -e "${CYAN}║${NC}  加密:    ${GREEN}${METHOD}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  配置文件: ${CONFIG_FILE}"
    echo -e "${CYAN}║${NC}  服务管理:"
    echo -e "${CYAN}║${NC}    启动:  systemctl start shadowsocks-rust"
    echo -e "${CYAN}║${NC}    停止:  systemctl stop shadowsocks-rust"
    echo -e "${CYAN}║${NC}    重启:  systemctl restart shadowsocks-rust"
    echo -e "${CYAN}║${NC}    状态:  systemctl status shadowsocks-rust"
    echo -e "${CYAN}║${NC}    日志:  journalctl -u shadowsocks-rust -f"
    echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  修改配置: vim ${CONFIG_FILE}"
    echo -e "${CYAN}║${NC}  改完重启: systemctl restart shadowsocks-rust"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    # 生成 SS URI (SIP008 格式)
    local userinfo
    userinfo=$(echo -n "${METHOD}:${PASSWORD}" | base64 -w0 2>/dev/null || echo -n "${METHOD}:${PASSWORD}" | base64)
    local ss_uri="ss://${userinfo}@${server_ip}:${PORT}#SS2022"
    echo -e "  ${YELLOW}SS 链接:${NC} ${ss_uri}"
    echo ""
}

# ============================================================
# 卸载功能
# ============================================================
uninstall() {
    echo ""
    warn "即将卸载 Shadowsocks 2022..."
    read -rp "确认卸载? [y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }

    systemctl stop shadowsocks-rust 2>/dev/null || true
    systemctl disable shadowsocks-rust 2>/dev/null || true
    rm -f /etc/systemd/system/shadowsocks-rust.service
    systemctl daemon-reload

    rm -f "${INSTALL_DIR}/ssserver"
    rm -f "${INSTALL_DIR}/sslocal"
    rm -f "${INSTALL_DIR}/ssurl"
    rm -rf "$CONFIG_DIR"
    rm -f /etc/sysctl.d/99-shadowsocks.conf
    sysctl --system >/dev/null 2>&1 || true

    info "卸载完成 ✓"
}

# ============================================================
# 主流程
# ============================================================
main() {
    case "${1:-}" in
        uninstall|remove)
            check_root
            uninstall
            exit 0
            ;;
        *)
            ;;
    esac

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Shadowsocks 2022 一键安装脚本          ║${NC}"
    echo -e "${CYAN}║  基于 shadowsocks-rust                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    check_os
    collect_params
    install_deps
    install_ssrust
    create_config
    create_service
    configure_firewall
    optimize_sysctl
    show_result
}

main "$@"
