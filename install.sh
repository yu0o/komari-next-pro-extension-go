#!/usr/bin/env sh
# Komari Next Pro · Go 扩展服务 管理脚本
# 支持安装 / 更新 / 卸载 / 状态查看 / GitHub 加速地址切换
# 兼容 Alpine（busybox ash + OpenRC）与 systemd 发行版，无需 Node 运行时。
# 版本：v1.1
set -eu

SCRIPT_VERSION=v1.1

OWNER=yu0o
REPO_NAME=komari-next-pro-extension-go
BINARY=komari-ds-extension
SERVICE=komari-ds
DATA_DIR=/var/lib/komari-ds
BIN_PATH=/usr/local/bin/${BINARY}
INSTALLER_CONF=/etc/komari-ds-installer.conf

SLUG=${KDS_REPO:-${OWNER}/${REPO_NAME}}
MIRROR=${KDS_MIRROR:-}
KDS_VERSION=${KDS_VERSION:-}

ARCH=unknown
INIT=none
TAG=""
PURGE=0
ASSUME_YES=0
ACTION=menu

if [ -t 1 ]; then
    C_RESET=$(printf '\033[0m'); C_INFO=$(printf '\033[36m'); C_OK=$(printf '\033[32m')
    C_WARN=$(printf '\033[33m'); C_ERR=$(printf '\033[31m'); C_BOLD=$(printf '\033[1m')
else
    C_RESET=; C_INFO=; C_OK=; C_WARN=; C_ERR=; C_BOLD=
fi

info() { printf '%s[*]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Komari Next Pro · Go 扩展服务 管理脚本（install.sh ${SCRIPT_VERSION}）

用法：
  sh install.sh                    交互菜单
  sh install.sh install            安装或更新（已有安装则覆盖升级）
  sh install.sh uninstall          卸载，保留数据与配置
  sh install.sh uninstall --purge  卸载并删除数据、配置、运行用户
  sh install.sh mirror             只切换下载加速地址
  sh install.sh status             查看安装与运行状态

参数：
  --version <tag>   指定版本，例如 --version v0.1.0；默认取 latest release
  --mirror <url>    指定加速前缀，例如 --mirror https://ghfast.top；传空字符串为直连
  --purge           卸载时删除数据
  -y, --yes         跳过确认
  -h, --help        显示本帮助

环境变量：KDS_VERSION / KDS_MIRROR / KDS_REPO（调试用，可替代同名参数）
EOF
}

# ---------------- 基础 ----------------

load_conf() {
    if [ -r "$INSTALLER_CONF" ]; then
        . "$INSTALLER_CONF"
        MIRROR=${MIRROR:-}
    fi
}

save_mirror() {
    if mkdir -p "$(dirname "$INSTALLER_CONF")" 2>/dev/null && printf 'MIRROR="%s"\n' "${MIRROR:-}" >"$INSTALLER_CONF" 2>/dev/null; then
        chmod 0644 "$INSTALLER_CONF" 2>/dev/null || true
    else
        warn "无法写入 $INSTALLER_CONF，加速地址仅在本次运行生效"
    fi
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限，请执行：sudo sh $0 ${ACTION}"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) ARCH=amd64 ;;
        aarch64 | arm64) ARCH=arm64 ;;
        *) ARCH=unknown ;;
    esac
}

require_arch() {
    [ "$ARCH" != unknown ] || die "当前只发布 linux-amd64 / linux-arm64 资产，$(uname -m) 需自行编译"
}

detect_init() {
    if command -v rc-service >/dev/null 2>&1 && [ -d /etc/runlevels ]; then
        INIT=openrc
    elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd ]; then
        INIT=systemd
    else
        INIT=none
    fi
}

conf_path() {
    if [ "$INIT" = systemd ]; then
        printf '/etc/default/komari-ds'
    else
        printf '/etc/conf.d/komari-ds'
    fi
}

ensure_downloader() {
    command -v curl >/dev/null 2>&1 && return 0
    command -v wget >/dev/null 2>&1 && return 0
    info "安装 curl 与 ca-certificates"
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates >/dev/null
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q curl ca-certificates >/dev/null
    else
        die "缺少 curl/wget，请先安装其中一个"
    fi
}

fetch_to() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 1 -o "$2" "$1"
    else
        wget -q --timeout=20 -O "$2" "$1"
    fi
}

proxied() {
    if [ -n "$MIRROR" ]; then
        printf '%s/%s' "${MIRROR%/}" "$1"
    else
        printf '%s' "$1"
    fi
}

# 依次尝试：当前加速前缀 → 直连 → 常见公共前缀
try_fetch() {
    target=$1
    out=$2
    cands=""
    if [ -n "$MIRROR" ]; then
        cands=$(proxied "$target")
    else
        cands=$target
    fi
    cands="${cands}
${target}
"
    for prefix in https://ghfast.top https://gh-proxy.com https://ghproxy.net; do
        [ "$prefix" = "$MIRROR" ] && continue
        cands="${cands}${prefix}/${target}
"
    done
    rm -f "$out"
    old_ifs=$IFS
    IFS='
'
    for candidate in $cands; do
        [ -n "$candidate" ] || continue
        IFS=$old_ifs
        if fetch_to "$candidate" "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
            IFS=$old_ifs
            return 0
        fi
        IFS='
'
    done
    IFS=$old_ifs
    rm -f "$out"
    return 1
}

ask() {
    prompt=$1
    default=$2
    if [ -t 0 ]; then
        printf '%s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$default"
        IFS= read -r answer || answer=""
        [ -n "$answer" ] || answer=$default
    else
        answer=$default
    fi
    printf '%s' "$answer"
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ -t 0 ] || return 1
    printf '%s%s%s [y/N]: ' "$C_BOLD" "$1" "$C_RESET"
    IFS= read -r reply || reply=""
    case "$reply" in
        y | Y | yes | YES) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------- 加速地址 ----------------

show_mirror() {
    if [ -n "$MIRROR" ]; then
        printf '%s' "$MIRROR"
    else
        printf '直连 github.com'
    fi
}

select_mirror() {
    detect_arch
    while :; do
        printf '\n当前下载源：%s\n' "$(show_mirror)"
        cat <<'MENU'
  1) 直连 GitHub（默认）
  2) ghfast.top            https://ghfast.top
  3) gh-proxy.com          https://gh-proxy.com
  4) ghproxy.net           https://ghproxy.net
  5) 自定义前缀（如公司内网镜像）
  0) 返回
MENU
        printf '选择 [0-5]: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) MIRROR="" ;;
            2) MIRROR="https://ghfast.top" ;;
            3) MIRROR="https://gh-proxy.com" ;;
            4) MIRROR="https://ghproxy.net" ;;
            5)
                printf '请输入前缀（留空为直连）: '
                IFS= read -r custom || custom=""
                MIRROR=${custom%/}
                ;;
            0) return 0 ;;
            *) warn "无效选择"; continue ;;
        esac
        save_mirror
        ok "已保存下载源：$(show_mirror)"
        printf '下载示例：%s\n' "$(proxied "https://github.com/${SLUG}/releases/download/${TAG:-vX.Y.Z}/${BINARY}-linux-${ARCH}")"
        return 0
    done
}

# ---------------- 版本 ----------------

json_tag() {
    tr ',' '\n' <"$1" | grep '"tag_name"' | head -n 1 | sed 's/.*"tag_name"[^"]*"\([^"]*\)".*/\1/'
}

resolve_version() {
    if [ -n "$KDS_VERSION" ]; then
        TAG=$KDS_VERSION
        return 0
    fi
    api="https://api.github.com/repos/${SLUG}/releases/latest"
    tmp=$(mktemp)
    if fetch_to "$api" "$tmp" 2>/dev/null; then
        TAG=$(json_tag "$tmp" || true)
    fi
    if [ -z "$TAG" ] && [ -n "$MIRROR" ]; then
        if fetch_to "$(proxied "$api")" "$tmp" 2>/dev/null; then
            TAG=$(json_tag "$tmp" || true)
        fi
    fi
    rm -f "$tmp"
    if [ -z "$TAG" ] && command -v curl >/dev/null 2>&1; then
        final=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "$(proxied "https://github.com/${SLUG}/releases/latest")" 2>/dev/null || true)
        case "$final" in
            */tag/*) TAG=${final##*/tag/} ;;
        esac
    fi
    if [ -z "$TAG" ]; then
        warn "无法自动获取最新版本：网络受限，或该仓库尚未发布 Release"
        if [ -t 0 ]; then
            printf '请输入版本标签（如 v0.1.0），留空退出: '
            IFS= read -r manual || manual=""
            [ -n "$manual" ] || die "已取消"
            TAG=$manual
        else
            die "请用 --version 指定版本，或先在该仓库上传 Release 资产"
        fi
    fi
}

# ---------------- 服务文件 ----------------

group_exists() {
    awk -F: -v g=komari-ds '$1 == g { found = 1 } END { exit(found ? 0 : 1) }' /etc/group 2>/dev/null
}

user_gid() {
    awk -F: '$1 == "komari-ds" { print $4; exit }' /etc/passwd 2>/dev/null
}

group_gid() {
    awk -F: '$1 == "komari-ds" { print $3; exit }' /etc/group 2>/dev/null
}

# Alpine 的 busybox adduser 不会自动建同名组，必须显式 addgroup 后再 -G 指定
create_user() {
    if ! group_exists; then
        if command -v addgroup >/dev/null 2>&1; then
            addgroup -S komari-ds >/dev/null 2>&1 || true
        elif command -v groupadd >/dev/null 2>&1; then
            groupadd --system komari-ds >/dev/null 2>&1 || true
        fi
        group_exists || die "创建用户组 komari-ds 失败"
    fi

    if ! id komari-ds >/dev/null 2>&1; then
        if [ -f /etc/alpine-release ] && command -v adduser >/dev/null 2>&1; then
            adduser -S -D -H -s /sbin/nologin -G komari-ds komari-ds >/dev/null 2>&1 || true
        fi
        if ! id komari-ds >/dev/null 2>&1 && command -v useradd >/dev/null 2>&1; then
            useradd --system --no-create-home --shell /usr/sbin/nologin --gid komari-ds komari-ds >/dev/null 2>&1 || true
        fi
        id komari-ds >/dev/null 2>&1 || die "创建运行用户 komari-ds 失败"
    fi

    # 旧脚本可能留下“有用户、无同名组”的残缺账户：先把主组纠正过来
    if [ "$(user_gid)" != "$(group_gid)" ]; then
        if command -v usermod >/dev/null 2>&1; then
            usermod -g komari-ds komari-ds >/dev/null 2>&1 || true
        fi
        if [ "$(user_gid)" != "$(group_gid)" ] \
            && [ -z "$(find "$DATA_DIR" -user komari-ds -print -quit 2>/dev/null)" ] \
            && command -v deluser >/dev/null 2>&1; then
            warn "检测到残缺账户 komari-ds（无同名组、未持有任何数据），重建账户"
            deluser komari-ds >/dev/null 2>&1 || true
            adduser -S -D -H -s /sbin/nologin -G komari-ds komari-ds >/dev/null 2>&1 || true
        fi
        [ "$(user_gid)" = "$(group_gid)" ] || die "komari-ds 的主组仍不是 komari-ds，请手动修正：deluser komari-ds; addgroup -S komari-ds; adduser -S -D -H -s /sbin/nologin -G komari-ds komari-ds"
    fi
    ok "运行用户 komari-ds 就绪（主组 komari-ds）"
}

write_conf() {
    target=$1
    if [ -f "$target" ]; then
        info "配置已存在，保持不变：$target"
        return 0
    fi
    backend=$(ask "Komari 后端地址" "http://127.0.0.1:25774")
    origin=$(ask "站点对外 origin（含协议，用于写接口校验）" "https://komari.example.com")
    port=$(ask "扩展服务监听端口" "5175")
    cat >"$target" <<EOF
# 由 install.sh 生成，修改后重启服务生效
DS_KOMARI_ORIGIN="${backend}"
DS_PUBLIC_ORIGIN="${origin}"
DS_BIND="127.0.0.1"
DS_PORT="${port}"
DS_DATA_DIR="${DATA_DIR}"
DS_ENABLE_JOBS="false"
#DS_KOMARI_API_KEY=""
#DS_IPAPI_KEY=""
#DS_FFMPEG="/usr/bin/ffmpeg"
#DS_MAX_UPLOAD_MIB="100"
EOF
    chmod 0640 "$target"
    ok "配置已写入 $target"
}

install_openrc() {
    cat >/etc/init.d/komari-ds <<'EOF'
#!/sbin/openrc-run
name="komari-ds extension"
description="Komari Next Pro companion service (Go)"

command="/usr/local/bin/komari-ds-extension"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
command_user="komari-ds:komari-ds"
directory="/var/lib/komari-ds"
output_log="/var/log/komari-ds.log"
error_log="/var/log/komari-ds.log"
respawn_delay="3"
respawn_max="10"

depend() {
	need net
	after firewall
}

start_pre() {
	checkpath --directory --owner komari-ds:komari-ds --mode 0750 /var/lib/komari-ds
	touch /var/log/komari-ds.log
	chown komari-ds:komari-ds /var/log/komari-ds.log
	chmod 0640 /var/log/komari-ds.log
	if [ -f /etc/conf.d/komari-ds ]; then
		set -a
		. /etc/conf.d/komari-ds
		set +a
	fi
	export DS_DATA_DIR="${DS_DATA_DIR:-/var/lib/komari-ds}"
}
EOF
    chmod 0755 /etc/init.d/komari-ds
    write_conf /etc/conf.d/komari-ds
}

install_systemd() {
    cat >/etc/systemd/system/komari-ds.service <<'EOF'
[Unit]
Description=Komari Next Pro companion service (Go)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=komari-ds
Group=komari-ds
EnvironmentFile=/etc/default/komari-ds
ExecStart=/usr/local/bin/komari-ds-extension
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/komari-ds

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/komari-ds.service
    write_conf /etc/default/komari-ds
}

service_stop() {
    case "$INIT" in
        openrc) rc-service "$SERVICE" stop >/dev/null 2>&1 || true ;;
        systemd) systemctl stop "$SERVICE" >/dev/null 2>&1 || true ;;
    esac
}

service_start() {
    case "$INIT" in
        openrc)
            if ! rc-service "$SERVICE" start; then
                tail -n 20 /var/log/komari-ds.log 2>/dev/null || true
                die "启动失败，日志见 /var/log/komari-ds.log"
            fi
            rc-update add "$SERVICE" default >/dev/null 2>&1 || true
            ;;
        systemd)
            systemctl daemon-reload
            systemctl enable --now "$SERVICE" || die "启动失败，请查看 journalctl -u $SERVICE"
            ;;
        none)
            warn "未识别 init 系统，二进制已安装，需自行看护：$BIN_PATH"
            ;;
    esac
}

check_health() {
    if [ "$INIT" = none ]; then
        return 1
    fi
    port=$(sed -n 's/^DS_PORT="\([0-9]*\)".*/\1/p' "$(conf_path)" 2>/dev/null | head -n 1)
    [ -n "$port" ] || port=5175
    sleep 1
    command -v curl >/dev/null 2>&1 || return 1
    body=$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/komari-ds-api/v1/capabilities" 2>/dev/null || true)
    if [ -n "$body" ]; then
        ok "服务已响应：$body"
        return 0
    fi
    warn "服务暂无响应，请检查日志后再试"
    return 1
}

# ---------------- 安装 ----------------

install_binary() {
    need_root
    detect_arch
    require_arch
    detect_init
    ensure_downloader
    resolve_version
    info "版本 ${TAG} / 架构 linux-${ARCH} / 下载源 $(show_mirror)"

    asset="${BINARY}-linux-${ARCH}"
    url="https://github.com/${SLUG}/releases/download/${TAG}/${asset}"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT INT TERM

    info "下载 ${asset}"
    try_fetch "$url" "$work/$asset" || die "下载失败：${SLUG} 的 Release ${TAG} 中是否有 ${asset}？也可先切换加速地址重试"
    [ -s "$work/$asset" ] || die "下载文件为空"

    if command -v sha256sum >/dev/null 2>&1; then
        if try_fetch "https://github.com/${SLUG}/releases/download/${TAG}/SHA256SUMS" "$work/SHA256SUMS" 2>/dev/null; then
            expected=$(grep " ${asset}\$" "$work/SHA256SUMS" | awk '{print $1}' | head -n 1 || true)
            if [ -n "$expected" ]; then
                actual=$(sha256sum "$work/$asset" | awk '{print $1}')
                [ "$actual" = "$expected" ] || die "SHA256 校验失败（期望 ${expected}，实际 ${actual}）"
                ok "SHA256 校验通过"
            else
                warn "SHA256SUMS 中无 ${asset} 记录，跳过校验"
            fi
        else
            warn "Release 未提供 SHA256SUMS，跳过校验"
        fi
    else
        warn "系统缺少 sha256sum，跳过校验"
    fi

    create_user
    mkdir -p "$DATA_DIR"
    chown komari-ds:komari-ds "$DATA_DIR" 2>/dev/null || true
    chmod 0750 "$DATA_DIR"

    case "$INIT" in
        openrc) install_openrc ;;
        systemd) install_systemd ;;
        none) warn "未识别 init 系统，仅安装二进制" ;;
    esac

    service_stop
    install -m 0755 "$work/$asset" "$BIN_PATH"
    ok "已安装 $BIN_PATH"

    if [ "$INIT" != none ]; then
        service_start
    fi
    check_health || true

    printf '\n安装完成\n  二进制   : %s\n  数据目录 : %s\n  配置文件 : %s\n' \
        "$BIN_PATH" "$DATA_DIR" "$(conf_path 2>/dev/null || printf '/etc/conf.d/komari-ds')"
    printf '  反代提示 : 将 /komari-ds-api/ 转发到 127.0.0.1:5175（Nginx 片段见 README）\n'
}

# ---------------- 卸载 ----------------

uninstall_service() {
    need_root
    detect_init
    if [ ! -x "$BIN_PATH" ] && [ ! -f /etc/init.d/komari-ds ] && [ ! -f /etc/systemd/system/komari-ds.service ]; then
        warn "未检测到已安装的服务"
    fi
    if [ "$ASSUME_YES" -eq 0 ]; then
        if [ "$PURGE" -eq 1 ]; then
            confirm "确认卸载并删除全部数据与配置？" || die "已取消"
        else
            confirm "确认卸载服务（数据与配置保留）？" || die "已取消"
        fi
    fi

    case "$INIT" in
        openrc)
            rc-service "$SERVICE" stop >/dev/null 2>&1 || true
            rc-update del "$SERVICE" default >/dev/null 2>&1 || true
            rm -f /etc/init.d/komari-ds
            ;;
        systemd)
            systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/komari-ds.service
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
    esac

    rm -f "$BIN_PATH"
    ok "已移除 $BIN_PATH"

    if [ "$PURGE" -eq 1 ]; then
        rm -rf "$DATA_DIR"
        rm -f /etc/conf.d/komari-ds /etc/default/komari-ds /var/log/komari-ds.log
        if id komari-ds >/dev/null 2>&1; then
            if command -v deluser >/dev/null 2>&1; then
                deluser komari-ds >/dev/null 2>&1 || true
            elif command -v userdel >/dev/null 2>&1; then
                userdel komari-ds >/dev/null 2>&1 || true
            fi
        fi
        ok "已删除数据目录、配置与运行用户"
    else
        info "数据目录保留：$DATA_DIR（彻底删除请加 --purge）"
    fi
}

# ---------------- 状态 ----------------

status() {
    detect_arch
    detect_init
    if [ -x "$BIN_PATH" ]; then
        printf '二进制   : %s（%s）\n' "$BIN_PATH" "$(ls -lh "$BIN_PATH" | awk '{print $5}')"
    else
        printf '二进制   : 未安装\n'
    fi
    case "$INIT" in
        openrc) printf '服务     : %s\n' "$(rc-service "$SERVICE" status 2>/dev/null | head -n 1 || printf '未注册')" ;;
        systemd) printf '服务     : %s\n' "$(systemctl is-active "$SERVICE" 2>/dev/null || printf '未注册')" ;;
        *) printf '服务     : 未知 init 系统\n' ;;
    esac
    printf '下载源   : %s\n' "$(show_mirror)"
    printf '脚本版本 : %s\n' "$SCRIPT_VERSION"
    if [ -x "$BIN_PATH" ]; then
        check_health || true
    fi
}

# ---------------- 菜单 ----------------

menu() {
    [ -t 0 ] || die "非交互环境请直接用子命令，例如：sh install.sh install"
    while :; do
        printf '\n Komari Next Pro · Go 扩展服务（install.sh %s）\n' "$SCRIPT_VERSION"
        printf ' 下载源：%s\n' "$(show_mirror)"
        cat <<'MENU'
  1) 安装 / 更新
  2) 卸载
  3) 设置 GitHub 加速地址
  4) 查看状态
  0) 退出
MENU
        printf '选择 [0-4]: '
        IFS= read -r choice || exit 0
        case "$choice" in
            1) install_binary ;;
            2) uninstall_service ;;
            3) select_mirror ;;
            4) status ;;
            0) exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

main() {
    load_conf
    while [ $# -gt 0 ]; do
        case "$1" in
            install | update | uninstall | mirror | status | menu) ACTION=$1 ;;
            --version)
                [ $# -ge 2 ] || die "--version 需要参数"
                KDS_VERSION=$2
                shift
                ;;
            --mirror)
                [ $# -ge 2 ] || die "--mirror 需要参数"
                MIRROR=${2%/}
                save_mirror
                shift
                ;;
            --purge) PURGE=1 ;;
            -y | --yes) ASSUME_YES=1 ;;
            -h | --help) usage; exit 0 ;;
            *) die "未知参数：$1（--help 查看用法）" ;;
        esac
        shift
    done
    case "$ACTION" in
        install | update) install_binary ;;
        uninstall) uninstall_service ;;
        mirror) select_mirror ;;
        status) status ;;
        menu) menu ;;
    esac
}

main "$@"
