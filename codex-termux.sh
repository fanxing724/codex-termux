#!/bin/bash
# ============================================================
# codex-termux.sh — Termux 部署 OpenAI Codex CLI
# 环境修补 + 自动检测/下载二进制
# API 配置请用你自备的换 API 脚本
# ============================================================
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
USER_BIN="$HOME/.local/bin"
USER_LIB="$HOME/.local/lib"
CODEX_DIR="$USER_LIB/codex"
CODEX_BIN="$CODEX_DIR/codex"
CODEX_VERSION_MARKER="$CODEX_DIR/.installed-version"
CODEX_RESOLV_CONF="$HOME/.config/codex/resolv.conf"

CURL=(curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 120)
WGET=(wget -q --show-progress --timeout=30 --tries=5)

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
err()   { printf "${RED}[✗]${NC} %s\n" "$1" >&2; }
step()  { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }

# ============================================================
# 1. 检查 / 安装依赖
# ============================================================
check_prereqs() {
    step "检查依赖"
    MISSING=()
    command -v curl    >/dev/null 2>&1 || MISSING+=(curl)
    command -v wget    >/dev/null 2>&1 || MISSING+=(wget)
    command -v python3 >/dev/null 2>&1 || MISSING+=(python)
    command -v node    >/dev/null 2>&1 || MISSING+=(nodejs)
    command -v objcopy >/dev/null 2>&1 || MISSING+=(binutils)
    command -v getprop >/dev/null 2>&1 || warn "getprop 不可用（非 Android 环境？）"
    [ -f "$PREFIX/etc/tls/cert.pem" ] || MISSING+=(ca-certificates)

    if [ ${#MISSING[@]} -gt 0 ]; then
        echo "    需要安装: ${MISSING[*]}"
        pkg install -y "${MISSING[@]}" >/dev/null 2>&1 || {
            err "安装失败，请手动执行: pkg install ${MISSING[*]}"
            exit 1
        }
        info "依赖安装完成"
    else
        info "所有依赖已就绪"
    fi
}

# ============================================================
# 2. 生成 DNS 解析文件
# ============================================================
write_resolver() {
    local output="$1"
    mkdir -p "$(dirname "$output")"
    {
        found=0
        for prop in net.dns1 net.dns2 net.dns3 net.dns4; do
            val=$(getprop "$prop" 2>/dev/null | tr -d '\r')
            if [ -n "$val" ] && echo "$val" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:'; then
                echo "nameserver $val"
                found=1
            fi
        done
        if [ "$found" = "0" ]; then
            echo "nameserver 1.1.1.1"
            echo "nameserver 8.8.8.8"
        fi
    } > "$output"
    info "DNS 解析文件已生成: $output"
}

# ============================================================
# 3. 修补二进制 DNS
# ============================================================
patch_resolv_conf_binary() {
    local file="$1"
    local offs
    offs=$(grep -abo "/etc/resolv.conf" "$file" | cut -d: -f1 || true)
    if [ -z "$offs" ]; then
        if grep -aq "/proc/self/fd/9" "$file"; then
            info "DNS 路径已修补，跳过"
            return
        fi
        warn "二进制中未找到 /etc/resolv.conf（可能新版已修复）"
        return
    fi
    local count=0
    for off in $offs; do
        printf '/proc/self/fd/9\0' | dd of="$file" bs=1 seek="$off" count=16 conv=notrunc status=none 2>/dev/null
        count=$((count + 1))
    done
    info "DNS 路径修补完成（$count 处）"
}

# ============================================================
# 4. 安装 Codex 二进制
# ============================================================
install_codex() {
    step "安装 Codex CLI"

    ASSET="codex-aarch64-unknown-linux-musl.tar.gz"

    # 检测已有二进制
    if [ -x "$CODEX_BIN" ]; then
        info "检测到已存在的 Codex 二进制: $CODEX_BIN"
        local bin_size
        bin_size=$(stat -c%s "$CODEX_BIN" 2>/dev/null || stat -f%z "$CODEX_BIN" 2>/dev/null || echo "0")
        if [ "$bin_size" -gt 1000000 ]; then
            info "二进制有效，跳过下载"
            patch_resolv_conf_binary "$CODEX_BIN"
            return
        else
            warn "二进制文件不完整，重新下载"
        fi
    fi

    # 检测本地压缩包
    local found_tarball=""
    for candidate in \
        "./$ASSET" \
        "$HOME/$ASSET" \
        "$HOME/storage/downloads/$ASSET" \
        "$HOME/storage/shared/Download/$ASSET" \
        "/sdcard/Download/$ASSET"; do
        if [ -f "$candidate" ]; then
            info "检测到本地压缩包: $candidate"
            found_tarball="$candidate"
            break
        fi
    done

    # 获取版本
    echo "获取最新版本..."
    if [ -n "${CODEX_RELEASE_TAG:-}" ]; then
        TAG="$CODEX_RELEASE_TAG"
    else
        TAG=$(curl -sL "https://api.github.com/repos/openai/codex/releases/latest" \
            | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null) \
        || TAG=$(wget -q -O- "https://api.github.com/repos/openai/codex/releases/latest" \
            | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null) \
        || { warn "无法获取版本，使用 rust-v0.145.0"; TAG="rust-v0.145.0"; }
    fi
    info "版本: $TAG"

    # 下载或使用本地
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT
    rm -rf "$CODEX_DIR"
    mkdir -p "$CODEX_DIR"

    if [ -n "$found_tarball" ]; then
        cp "$found_tarball" "$TMP_DIR/codex.tgz"
        info "使用本地压缩包"
    else
        echo "下载 Codex 二进制..."
        download_ok=0
        for url in \
            "https://github.com/openai/codex/releases/download/$TAG/$ASSET" \
            "https://mirror.ghproxy.com/https://github.com/openai/codex/releases/download/$TAG/$ASSET"; do
            echo "    尝试: $url"
            if "${CURL[@]}" -o "$TMP_DIR/codex.tgz" "$url" 2>/dev/null; then
                download_ok=1; break
            fi
            if "${WGET[@]}" -O "$TMP_DIR/codex.tgz" "$url" 2>/dev/null; then
                download_ok=1; break
            fi
        done
        if [ "$download_ok" = "0" ]; then
            err "下载失败，请手动下载:"
            err "  wget https://github.com/openai/codex/releases/download/$TAG/$ASSET"
            err "  tar -xzf $ASSET"
            err "  mv codex-aarch64-unknown-linux-musl $CODEX_BIN"
            err "  chmod +x $CODEX_BIN"
            exit 1
        fi
        info "下载成功"
    fi

    tar -xzf "$TMP_DIR/codex.tgz" -C "$TMP_DIR" 2>/dev/null || {
        err "解压失败"
        exit 1
    }
    BIN_PATH=$(find "$TMP_DIR" -name "codex*" -type f | head -1)
    [ -f "$BIN_PATH" ] || { err "未找到 codex 二进制"; exit 1; }
    mv "$BIN_PATH" "$CODEX_BIN"
    chmod +x "$CODEX_BIN"
    info "已安装到 $CODEX_BIN"

    patch_resolv_conf_binary "$CODEX_BIN"
}

# ============================================================
# 5. 生成 wrapper 脚本
# ============================================================
generate_wrapper() {
    step "生成 wrapper 脚本"
    mkdir -p "$USER_BIN"

    cat > "$USER_BIN/codex" <<'WRAPPER'
#!/usr/bin/env bash
# Codex Termux wrapper
set -eu

CODEX_BIN="$HOME/.local/lib/codex/codex"
CODEX_RESOLV_CONF="$HOME/.config/codex/resolv.conf"

export SSL_CERT_FILE="${SSL_CERT_FILE:-/data/data/com.termux/files/usr/etc/tls/cert.pem}"
export TMPDIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"

# 沙箱参数
termux_sandbox_args=()
if [ "${CODEX_TERMUX_DEFAULT_SANDBOX:-danger-full-access}" != "preserve" ]; then
    has_sandbox=0
    for arg in "$@"; do
        case "$arg" in
            -s|--sandbox|--sandbox=*|--dangerously-bypass-approvals-and-sandbox|--yolo)
                has_sandbox=1; break ;;
        esac
    done
    [ "$has_sandbox" = "0" ] && termux_sandbox_args=(--sandbox "${CODEX_TERMUX_DEFAULT_SANDBOX:-danger-full-access}")
fi

exec "$CODEX_BIN" "${termux_sandbox_args[@]}" "$@" 9<"$CODEX_RESOLV_CONF"
WRAPPER

    chmod +x "$USER_BIN/codex"
    info "wrapper 已创建: $USER_BIN/codex"
}

# ============================================================
# 6. 配置 PATH
# ============================================================
setup_path() {
    step "配置 Shell PATH"
    local MARKER_BEGIN="# >>> codex-termux PATH >>>"
    local MARKER_END="# <<< codex-termux PATH <<<"
    local block="$MARKER_BEGIN
case \":\$PATH:\" in
    *\":\$HOME/.local/bin:\"*) ;;
    *) export PATH=\"\$HOME/.local/bin:\$PATH\" ;;
esac
$MARKER_END"

    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ] && grep -qF "$MARKER_BEGIN" "$rc" 2>/dev/null; then
            echo "    $rc: 已配置"
        else
            printf '\n%s\n' "$block" >> "$rc" 2>/dev/null || true
            echo "    $rc: 已添加"
        fi
    done
}

# ============================================================
# 7. 卸载
# ============================================================
uninstall() {
    step "卸载"
    for p in "$USER_BIN/codex" "$CODEX_DIR"; do
        [ -e "$p" ] && rm -rf "$p" && echo "    已删除: $p"
    done
    echo "    配置目录 ~/.codex 保留未删除"
    info "卸载完成"
    exit 0
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║     Codex CLI Termux 一键安装脚本              ║"
    echo "║     环境修补 + 自动检测/下载二进制              ║"
    echo "║     API 配置请用你的换 API 脚本                ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""

    if [ $# -gt 0 ] && [ "$1" = "uninstall" ]; then
        uninstall
    fi

    check_prereqs
    write_resolver "$CODEX_RESOLV_CONF"
    install_codex
    generate_wrapper
    setup_path

    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║  安装完成！                                    ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    echo "  启动 Codex:"
    echo "    source ~/.bashrc"
    echo "    codex"
    echo ""
    echo "  配置 API: 用你的换 API 脚本修改 ~/.codex/config.toml"
    echo "  或直接设置环境变量:"
    echo "    export OPENAI_BASE_URL=https://api.deepseek.com/v1"
    echo "    export OPENAI_API_KEY=sk-xxx"
    echo ""
    echo "  环境变量:"
    echo "    CODEX_TERMUX_DEFAULT_SANDBOX=preserve  # 禁止自动加沙箱"
    echo "    CODEX_RELEASE_TAG=rust-vX.Y.Z          # 指定版本"
    echo ""
}

main "$@"