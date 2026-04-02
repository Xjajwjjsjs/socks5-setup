#!/usr/bin/env bash
#
# SOCKS5 一键部署脚本
# https://github.com/Xjajwjjsjs/socks5-setup
#
# 用法:
#   安装:   bash <(curl -fsSL https://raw.githubusercontent.com/Xjajwjjsjs/socks5-setup/main/install.sh)
#   卸载:   socks5 uninstall
#   状态:   socks5 status
#   添加用户: socks5 add
#   删除用户: socks5 del
#   用户列表: socks5 list
#   重启服务: socks5 restart
#   查看信息: socks5 info

set -euo pipefail

# ============ 颜色 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============ 常量 ============
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/socks5"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
USERS_FILE="${CONFIG_DIR}/users.txt"
SERVICE_NAME="socks5-proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GOST_BIN="${INSTALL_DIR}/gost"
SOCKS5_CMD="${INSTALL_DIR}/socks5"
GOST_VERSION="3.0.0-rc10"
GOST_REPO="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}"

# ============ 工具函数 ============
msg()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info()  { echo -e "${CYAN}[i]${NC} $*"; }

check_root() {
    [[ $EUID -eq 0 ]] || err "请使用 root 权限运行此脚本 (sudo bash ...)"
}

# ============ 系统检测 ============
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID,,}"
        OS_VERSION="${VERSION_ID:-unknown}"
    elif command -v lsb_release &>/dev/null; then
        OS_ID="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
        OS_VERSION="$(lsb_release -sr)"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="centos"
        OS_VERSION="$(grep -oP '[0-9]+' /etc/redhat-release | head -1)"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
    fi

    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop) PKG_MGR="apt" ;;
        centos|rhel|rocky|alma|fedora|ol) PKG_MGR="yum" ;;
        alpine) PKG_MGR="apk" ;;
        arch|manjaro) PKG_MGR="pacman" ;;
        opensuse*|sles) PKG_MGR="zypper" ;;
        *) PKG_MGR="unknown" ;;
    esac

    info "检测到系统: ${OS_ID} ${OS_VERSION} (包管理器: ${PKG_MGR})"
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7*|armhf)  ARCH="armv7" ;;
        i686|i386)     ARCH="386" ;;
        *) err "不支持的架构: $arch" ;;
    esac
    info "检测到架构: ${ARCH}"
}

# ============ 依赖安装 ============
install_deps() {
    info "安装必要依赖..."
    case "$PKG_MGR" in
        apt)
            apt-get update -qq
            apt-get install -y -qq curl wget tar gzip >/dev/null 2>&1
            ;;
        yum)
            yum install -y -q curl wget tar gzip >/dev/null 2>&1
            ;;
        apk)
            apk add --no-cache curl wget tar gzip >/dev/null 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm curl wget tar gzip >/dev/null 2>&1
            ;;
        zypper)
            zypper install -y -q curl wget tar gzip >/dev/null 2>&1
            ;;
        *)
            warn "未知包管理器，请确保已安装 curl wget tar"
            ;;
    esac
    msg "依赖安装完成"
}

# ============ 获取公网 IP ============
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com" "https://ip.sb"; do
        ip="$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" && [[ -n "$ip" ]] && break
    done
    [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
    echo "$ip"
}

# ============ 随机生成 ============
rand_port() {
    shuf -i 10000-65000 -n 1
}

rand_str() {
    local len="${1:-8}"
    head -c 256 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$len" || true
}

# ============ 防火墙 ============
configure_firewall() {
    local port="$1"
    info "配置防火墙 (端口: ${port})..."

    # ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        msg "ufw 已放行端口 ${port}"
        return
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        msg "firewalld 已放行端口 ${port}"
        return
    fi

    # iptables
    if command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
            # 保存规则
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables.rules 2>/dev/null || true
            fi
            msg "iptables 已放行端口 ${port}"
        fi
        return
    fi

    warn "未检测到活跃的防火墙，跳过配置"
}

remove_firewall_rule() {
    local port="$1"
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

# ============ 生成配置 ============
generate_config() {
    local port="$1"

    cat > "$CONFIG_FILE" <<YAML
services:
- name: socks5-service
  addr: ":${port}"
  handler:
    type: socks5
    auths:
$(while IFS=: read -r user pass; do
    [[ -z "$user" ]] && continue
    echo "    - username: \"${user}\""
    echo "      password: \"${pass}\""
done < "$USERS_FILE")
  listener:
    type: tcp
YAML
}

# ============ systemd 服务 ============
create_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=SOCKS5 Proxy Service (gost)
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -C ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"
    msg "服务已启动并设置开机自启"
}

# ============ 管理命令 ============
create_socks5_cmd() {
    cat > "$SOCKS5_CMD" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/socks5"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
USERS_FILE="${CONFIG_DIR}/users.txt"
SERVICE_NAME="socks5-proxy"
GOST_BIN="/usr/local/bin/gost"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
msg()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

[[ $EUID -eq 0 ]] || err "请使用 root 权限运行"

get_port() { grep -oP 'addr:\s*"?:(\d+)"?' "$CONFIG_FILE" | tr -dc '0-9'; }

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip="$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" && [[ -n "$ip" ]] && break
    done
    [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
    echo "$ip"
}

rand_str() { head -c 256 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "${1:-8}" || true; }
regenerate_config() {
    local port
    port="$(get_port)"
    cat > "$CONFIG_FILE" <<YAML
services:
- name: socks5-service
  addr: ":${port}"
  handler:
    type: socks5
    auths:
$(while IFS=: read -r user pass; do
    [[ -z "$user" ]] && continue
    echo "    - username: \"${user}\""
    echo "      password: \"${pass}\""
done < "$USERS_FILE")
  listener:
    type: tcp
YAML
    systemctl restart "$SERVICE_NAME"
}

show_info() {
    local ip port
    ip="$(get_public_ip)"
    port="$(get_port)"
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}       SOCKS5 节点信息${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e " 服务器: ${CYAN}${ip}${NC}"
    echo -e " 端口:   ${CYAN}${port}${NC}"
    echo ""
    echo -e " ${BOLD}连接链接:${NC}"
    while IFS=: read -r user pass; do
        [[ -z "$user" ]] && continue
        echo -e "  ${GREEN}socks5://${user}:${pass}@${ip}:${port}${NC}"
    done < "$USERS_FILE"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""
}

case "${1:-help}" in
    status)
        systemctl status "$SERVICE_NAME" --no-pager
        ;;
    restart)
        systemctl restart "$SERVICE_NAME"
        msg "服务已重启"
        ;;
    stop)
        systemctl stop "$SERVICE_NAME"
        msg "服务已停止"
        ;;
    start)
        systemctl start "$SERVICE_NAME"
        msg "服务已启动"
        ;;
    info)
        show_info
        ;;
    add)
        read -rp "用户名 (回车随机): " new_user
        [[ -z "$new_user" ]] && new_user="user_$(rand_str 4)"
        read -rp "密码 (回车随机): " new_pass
        [[ -z "$new_pass" ]] && new_pass="$(rand_str 12)"
        echo "${new_user}:${new_pass}" >> "$USERS_FILE"
        regenerate_config
        _ip="$(get_public_ip)"
        _port="$(get_port)"
        msg "用户已添加"
        echo -e "  ${GREEN}socks5://${new_user}:${new_pass}@${_ip}:${_port}${NC}"
        ;;
    del)
        if [[ ! -s "$USERS_FILE" ]]; then
            warn "没有用户可删除"
            exit 0
        fi
        echo ""
        info "当前用户列表:"
        _i=1
        while IFS=: read -r user pass; do
            [[ -z "$user" ]] && continue
            echo "  ${_i}) ${user}"
            ((_i++))
        done < "$USERS_FILE"
        echo ""
        read -rp "输入要删除的用户名: " del_user
        if grep -Fq "${del_user}:" "$USERS_FILE" && grep -q "^$(printf '%s' "$del_user" | sed 's/[.[\*^$()+?{|\\]/\\&/g'):" "$USERS_FILE"; then
            grep -Fxv "$(grep -F "${del_user}:" "$USERS_FILE")" "$USERS_FILE" > "${USERS_FILE}.tmp" || true
            mv "${USERS_FILE}.tmp" "$USERS_FILE"
            if [[ ! -s "$USERS_FILE" ]]; then
                warn "警告: 已无用户，服务将无法认证"
            fi
            regenerate_config
            msg "用户 ${del_user} 已删除"
        else
            err "用户 ${del_user} 不存在"
        fi
        ;;
    list)
        echo ""
        info "当前用户列表:"
        _ip="$(get_public_ip)"
        _port="$(get_port)"
        while IFS=: read -r user pass; do
            [[ -z "$user" ]] && continue
            echo -e "  ${CYAN}${user}${NC} -> socks5://${user}:${pass}@${_ip}:${_port}"
        done < "$USERS_FILE"
        echo ""
        ;;
    uninstall)
        echo ""
        warn "即将卸载 SOCKS5 代理服务"
        read -rp "确认卸载? (y/N): " confirm
        if [[ "${confirm,,}" == "y" ]]; then
            _port="$(get_port)" 2>/dev/null || _port=""
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true
            rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
            systemctl daemon-reload
            rm -f "$GOST_BIN"
            rm -rf "$CONFIG_DIR"
            # 清理防火墙
            if [[ -n "${_port:-}" ]]; then
                if command -v ufw &>/dev/null; then ufw delete allow "$_port"/tcp 2>/dev/null || true; fi
                if command -v firewall-cmd &>/dev/null; then
                    firewall-cmd --permanent --remove-port="${_port}/tcp" 2>/dev/null || true
                    firewall-cmd --reload 2>/dev/null || true
                fi
                if command -v iptables &>/dev/null; then
                    iptables -D INPUT -p tcp --dport "$_port" -j ACCEPT 2>/dev/null || true
                fi
            fi
            rm -f "/usr/local/bin/socks5"
            msg "卸载完成"
        else
            info "已取消"
        fi
        ;;
    *)
        echo ""
        echo -e "${BOLD}SOCKS5 管理工具${NC}"
        echo ""
        echo "  socks5 info       查看连接信息"
        echo "  socks5 status     查看服务状态"
        echo "  socks5 start      启动服务"
        echo "  socks5 stop       停止服务"
        echo "  socks5 restart    重启服务"
        echo "  socks5 add        添加用户"
        echo "  socks5 del        删除用户"
        echo "  socks5 list       用户列表"
        echo "  socks5 uninstall  卸载"
        echo ""
        ;;
esac
SCRIPT
    chmod +x "$SOCKS5_CMD"
}

# ============ 下载 gost ============
download_gost() {
    info "下载 gost v${GOST_VERSION} (${ARCH})..."
    local filename="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"
    local url="${GOST_REPO}/${filename}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    if ! curl -fsSL --retry 3 --connect-timeout 10 -o "${tmp_dir}/${filename}" "$url"; then
        err "下载失败，请检查网络连接后重试"
    fi

    tar -xzf "${tmp_dir}/${filename}" -C "${tmp_dir}"
    cp "${tmp_dir}/gost" "$GOST_BIN"
    chmod +x "$GOST_BIN"
    rm -rf "$tmp_dir"
    msg "gost 下载完成"
}

# ============ 主安装流程 ============
do_install() {
    # 修复 bash <(curl ...) 方式运行时 stdin 被占用的问题
    exec < /dev/tty || err "无法连接终端，请在交互式终端中运行此脚本"

    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     SOCKS5 一键部署脚本               ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════╝${NC}"
    echo ""

    check_root
    detect_os
    detect_arch

    # 检查是否已安装
    if [[ -f "$GOST_BIN" ]] && [[ -f "$CONFIG_FILE" ]]; then
        warn "检测到已有安装"
        read -rp "是否重新安装? (y/N): " reinstall
        [[ "${reinstall,,}" != "y" ]] && { info "已取消"; exit 0; }
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi

    install_deps

    # 端口
    local default_port
    default_port="$(rand_port)"
    read -rp "$(echo -e "${CYAN}[?]${NC} 端口 (回车随机 ${default_port}): ")" S5_PORT
    S5_PORT="${S5_PORT:-$default_port}"

    # 验证端口是否为合法数字
    if ! [[ "$S5_PORT" =~ ^[0-9]+$ ]] || (( S5_PORT < 1 || S5_PORT > 65535 )); then
        err "无效端口: ${S5_PORT}，请输入 1-65535 之间的数字"
    fi

    # 检查端口是否被占用
    if ss -tlnp | grep -q ":${S5_PORT} "; then
        err "端口 ${S5_PORT} 已被占用，请更换"
    fi

    # 用户名
    local default_user="user_$(rand_str 4)"
    read -rp "$(echo -e "${CYAN}[?]${NC} 用户名 (回车随机 ${default_user}): ")" S5_USER
    S5_USER="${S5_USER:-$default_user}"

    # 密码
    local default_pass
    default_pass="$(rand_str 16)"
    read -rp "$(echo -e "${CYAN}[?]${NC} 密码 (回车随机): ")" S5_PASS
    S5_PASS="${S5_PASS:-$default_pass}"

    echo ""
    info "开始安装..."

    # 下载 gost
    download_gost

    # 创建配置目录
    mkdir -p "$CONFIG_DIR"

    # 保存用户
    echo "${S5_USER}:${S5_PASS}" > "$USERS_FILE"
    chmod 600 "$USERS_FILE"

    # 生成配置
    generate_config "$S5_PORT"

    # 防火墙
    configure_firewall "$S5_PORT"

    # 创建服务
    create_service

    # 创建管理命令
    create_socks5_cmd

    # 获取公网 IP
    local PUBLIC_IP
    PUBLIC_IP="$(get_public_ip)"

    # 输出信息
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  ✓ 安装完成!${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
    echo -e "  服务器:  ${CYAN}${PUBLIC_IP}${NC}"
    echo -e "  端口:    ${CYAN}${S5_PORT}${NC}"
    echo -e "  用户名:  ${CYAN}${S5_USER}${NC}"
    echo -e "  密码:    ${CYAN}${S5_PASS}${NC}"
    echo ""
    echo -e "  ${BOLD}连接链接:${NC}"
    echo -e "  ${GREEN}${BOLD}socks5://${S5_USER}:${S5_PASS}@${PUBLIC_IP}:${S5_PORT}${NC}"
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "  管理命令: ${CYAN}socks5 help${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
}

# ============ 入口 ============
# 如果通过 socks5 命令调用则转发参数
# 如果直接运行则执行安装
case "${1:-install}" in
    install) do_install ;;
    *) 
        # 如果存在管理命令则转发
        if [[ -x "$SOCKS5_CMD" ]]; then
            exec "$SOCKS5_CMD" "$@"
        else
            do_install
        fi
        ;;
esac
