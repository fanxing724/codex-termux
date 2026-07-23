#!/bin/bash
# ============================================================
# codex-switch-api.sh — Codex 一键换 API
# 用法：
#   bash codex-switch-api.sh --url https://你的地址 --key sk-你的key
#   bash codex-switch-api.sh -u https://你的地址 -k sk-你的key
#   bash codex-switch-api.sh --test --url https://... --key sk-...
#   bash codex-switch-api.sh --show
#   bash codex-switch-api.sh (交互模式)
# ============================================================
set -euo pipefail

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
err()   { printf "${RED}[✗]${NC} %s\n" "$1" >&2; }
header(){ printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }

# ============================================================
# 参数解析
# ============================================================
BASE_URL=""
API_KEY=""
TEST_ONLY=false
SHOW_ONLY=false

show_help() {
    cat << EOF
Codex 换 API 脚本 — Termux 专用

用法: $0 [选项]

选项:
  -u, --url URL        设置 API 地址
  -k, --key KEY        设置 API Key
  -t, --test           只测试 API 连接
  -s, --show           显示当前配置
  -h, --help           显示帮助

示例:
  $0 -u https://api.deepseek.com/v1 -k sk-xxx
  $0 --url https://你的地址 --key sk-你的key
  $0 -t -u https://你的地址 -k sk-你的key  # 只测试
  $0 -s                                    # 查看当前配置
  $0                                      # 交互模式
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)   BASE_URL="$2"; shift 2 ;;
        -k|--key)   API_KEY="$2"; shift 2 ;;
        -t|--test)  TEST_ONLY=true; shift ;;
        -s|--show)  SHOW_ONLY=true; shift ;;
        -h|--help)  show_help ;;
        *) err "未知选项: $1"; show_help ;;
    esac
done

# ============================================================
# 显示当前配置
# ============================================================
show_config() {
    header "当前 Codex 配置"
    echo ""
    if [ -f "$HOME/.codex/config.toml" ]; then
        info "配置文件: $HOME/.codex/config.toml"
        echo "──────────────────────────────────────────────"
        cat "$HOME/.codex/config.toml"
        echo "──────────────────────────────────────────────"
    else
        warn "未找到配置文件: $HOME/.codex/config.toml"
    fi
    echo ""
    info "环境变量:"
    for var in OPENAI_BASE_URL OPENAI_API_KEY CODEX_API_KEY; do
        val="${!var:-}"
        if [ -n "$val" ]; then
            masked="${val:0:8}...${val: -4}"
            echo "    $var = $masked"
        else
            echo "    $var = (未设置)"
        fi
    done
}

if [ "$SHOW_ONLY" = true ]; then
    show_config
    exit 0
fi

# ============================================================
# 交互模式
# ============================================================
if [ -z "$BASE_URL" ] && [ -z "$API_KEY" ]; then
    header "交互配置模式"
    read -rp "请输入 API 地址 (如 https://api.deepseek.com/v1): " BASE_URL
    while [ -z "$API_KEY" ]; do
        read -rp "请输入 API Key: " API_KEY
        [ -z "$API_KEY" ] && warn "API Key 不能为空"
    done
fi

# ============================================================
# 校验
# ============================================================
if [ -z "$BASE_URL" ] || [ -z "$API_KEY" ]; then
    err "API 地址和 API Key 都不能为空"
    show_help
fi

# 去掉末尾斜杠
BASE_URL="${BASE_URL%/}"

# 校验 Key 格式
if ! echo "$API_KEY" | grep -qE '^[A-Za-z0-9_-]+$'; then
    err "API Key 格式不正确（只能包含字母、数字、连字符和下划线）"
    exit 1
fi

# ============================================================
# 测试 API 连接
# ============================================================
test_api() {
    header "测试 API 连接"
    local code
    code=$(curl -s --connect-timeout 10 -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        "${BASE_URL}/health" 2>/dev/null || echo "000")

    case "$code" in
        200) info "API 连接成功！"; return 0 ;;
        401) err "API Key 认证失败，请检查 Key 是否正确"; return 1 ;;
        000) err "无法连接到服务器，请检查网络和地址"; return 1 ;;
        *)   warn "API 返回状态码: $code（可能不影响使用）"; return 0 ;;
    esac
}

test_api

if [ "$TEST_ONLY" = true ]; then
    exit 0
fi

# ============================================================
# 备份旧配置
# ============================================================
if [ -f "$HOME/.codex/config.toml" ]; then
    local backup="$HOME/.codex/config.toml.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$HOME/.codex/config.toml" "$backup"
    info "旧配置已备份: $backup"
fi

# ============================================================
# 生成 config.toml
# ============================================================
header "生成 Codex 配置"
mkdir -p "$HOME/.codex"

cat > "$HOME/.codex/config.toml" <<CONFIG
# Codex 配置 — 由 codex-switch-api.sh 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

model_provider = "codex"
model = "gpt-5.5"
model_reasoning_effort = "high"
disable_response_storage = true
sandbox_mode = "danger-full-access"

[model_providers.codex]
name = "codex"
base_url = "${BASE_URL}"
wire_api = "responses"
supports_websockets = false
env_key = "CODEX_API_KEY"

[experimental]
use_freeform_apply_patch = true
use_unified_exec_tool = true

[features]
apply_patch_freeform = true
plan_tool = true
rmcp_client = true
streamable_shell = false
unified_exec = false
view_image_tool = true
parallel = true

[sandbox_workspace_write]
network_access = true
CONFIG

info "配置已写入: $HOME/.codex/config.toml"

# ============================================================
# 设置环境变量
# ============================================================
header "设置环境变量"

# 当前会话
export OPENAI_BASE_URL="$BASE_URL"
export OPENAI_API_KEY="$API_KEY"
export CODEX_API_KEY="$API_KEY"

# 写入 shell 配置
detect_shell_config() {
    if [ -n "$BASH_VERSION" ]; then
        echo "$HOME/.bashrc"
    elif [ -n "$ZSH_VERSION" ]; then
        echo "$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
        echo "$HOME/.bashrc"
    elif [ -f "$HOME/.zshrc" ]; then
        echo "$HOME/.zshrc"
    else
        echo "$HOME/.profile"
    fi
}

SHELL_CONFIG=$(detect_shell_config)
info "检测到 Shell 配置: $SHELL_CONFIG"

# 标记块
MARKER_BEGIN="# >>> codex-api-config >>>"
MARKER_END="# <<< codex-api-config <<<"

# 如果已有标记块，替换；否则追加
if grep -qF "$MARKER_BEGIN" "$SHELL_CONFIG" 2>/dev/null; then
    # 替换已有块
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v url="$BASE_URL" -v key="$API_KEY" '
    $0 ~ begin { print; printing=1; next }
    $0 ~ end { printing=0; print; next }
    !printing { print }
    ' "$SHELL_CONFIG" > "${SHELL_CONFIG}.tmp" && mv "${SHELL_CONFIG}.tmp" "$SHELL_CONFIG"
    info "已更新 $SHELL_CONFIG 中的环境变量"
else
    cat >> "$SHELL_CONFIG" <<EOF

${MARKER_BEGIN}
# Codex API 配置
export OPENAI_BASE_URL="${BASE_URL}"
export OPENAI_API_KEY="${API_KEY}"
export CODEX_API_KEY="${API_KEY}"
${MARKER_END}
EOF
    info "已写入 $SHELL_CONFIG"
fi

# ============================================================
# 完成
# ============================================================
echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║  配置完成！                                    ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
echo "  API 地址: ${BASE_URL}"
echo "  API Key:  ${API_KEY:0:8}...${API_KEY: -4}"
echo ""
echo "  启动 Codex:"
echo "    source ${SHELL_CONFIG/$HOME/\~}"
echo "    codex"
echo ""
echo "  如需切换其他 API，重新运行:"
echo "    bash codex-switch-api.sh -u 新地址 -k 新key"
echo ""

show_config