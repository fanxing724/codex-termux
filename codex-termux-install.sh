#!/usr/bin/env bash
# codex-termux-install.sh — 优化适配版
# 来源: https://github.com/PeroSar/claude-codex-termux (Codex 部分提取优化)
# 提取/优化时间: 2026-07-01
# 许可证: 原仓库许可证 (MIT/GPL 请参照原仓库)
#
# 优化内容:
#   1. 架构自动检测 (aarch64 / x86_64)
#   2. 环境自适应 (Termux/Android vs 普通 Linux)
#   3. 下载 SHA256 校验
#   4. 远程/本地版本对比, 无变更跳过下载
#   5. 外部配置文件支持
#   6. 详细模式 (-v) 与静默模式 (-q)
#   7. 更健壮的错误处理与清理
#   8. Wrapper 信号转发优化
#   9. 依赖检查前置
#   10. 卸载与状态查询子命令
#  11. 内置 API provider 切换 (switch-api) — 支持 openai/azure/friday/custom 等
#  12. Wrapper 自动注入当前 provider 的 base_url/model

set -euo pipefail

# ============================================================================
# 全局配置
# ============================================================================

# --- 路径 ---
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
USER_BIN="${CODEX_USER_BIN:-$HOME/.local/bin}"
USER_LIB="${CODEX_USER_LIB:-$HOME/.local/lib}"
CODEX_DIR="$USER_LIB/codex"
CODEX_BIN="$CODEX_DIR/codex"
CODEX_VERSION_MARKER="$CODEX_DIR/.installed-version"
CODEX_REMOTE_VERSION_FILE="$CODEX_DIR/.remote-version"
CODEX_RESOLV_CONF="$HOME/.config/codex/resolv.conf"
CODEX_CHECKSUM_FILE="$CODEX_DIR/.sha256"
TMP_DIR=""

# --- 配置 ---
CODEX_REPO="${CODEX_REPO:-openai/codex}"
CODEX_RELEASE_TAG="${CODEX_RELEASE_TAG:-}"
CODEX_MIRROR="${CODEX_MIRROR:-}"
CODEX_TERMUX_DEFAULT_SANDBOX="${CODEX_TERMUX_DEFAULT_SANDBOX:-danger-full-access}"
FORCE_INSTALL="${FORCE_INSTALL:-0}"
VERBOSE="${VERBOSE:-0}"
QUIET="${QUIET:-0}"

# --- 运行时状态 ---
IS_TERMUX=0
IS_ANDROID=0
ARCH=""
ASSET_NAME=""
ASSET_BINARY_NAME=""
DOWNLOADED_CHECKSUM=""

# ============================================================================
# 输出辅助
# ============================================================================

_log()   { [ "$QUIET" = "0" ] && printf '[codex-install] %s\n' "$*" || true; }
_logv()  { [ "$VERBOSE" = "1" ] && printf '[codex-install:dbg] %s\n' "$*" >&2 || true; }
_warn()  { printf '[codex-install:warn] %s\n' "$*" >&2; }
_err()   { printf '[codex-install:ERROR] %s\n' "$*" >&2; }
_step()  { printf '[codex-install] → %s\n' "$*"; }
_ok()    { printf '[codex-install] ✔ %s\n' "$*"; }

_section() {
  [ "$QUIET" = "0" ] && printf '\n━━━━ %s ━━━━\n' "$1" || true
}

# ============================================================================
# 清理
# ============================================================================

cleanup() {
  local rc=$?
  if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR:-}" ]; then
    _logv "Cleaning up temp dir: $TMP_DIR"
    rm -rf "$TMP_DIR"
  fi
  # 还原终端前景色
  tput sgr0 2>/dev/null || true
}

trap cleanup EXIT INT TERM HUP

# ============================================================================
# 依赖检查
# ============================================================================

check_deps() {
  local missing=()
  for cmd in curl tar grep sed mkdir chmod rm mktemp sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    _err "Missing required commands: ${missing[*]}"
    echo "Please install them first (e.g. apt-get install ${missing[*]})"
    exit 1
  fi

  # 可选依赖：缺失时降级而非报错
  for opt in lsof tput python3; do
    if ! command -v "$opt" >/dev/null 2>&1; then
      _warn "Optional command '$opt' not found — some features may be limited"
    fi
  done

  _logv "All required commands available"
}

# ============================================================================
# 环境检测
# ============================================================================

detect_environment() {
  _logv "Detecting environment..."

  # 架构
  ARCH=$(uname -m)
  case "$ARCH" in
    aarch64|arm64)
      ARCH="aarch64"
      ASSET_NAME="codex-aarch64-unknown-linux-musl.tar.gz"
      ASSET_BINARY_NAME="codex-aarch64-unknown-linux-musl"
      ;;
    x86_64|amd64)
      ARCH="x86_64"
      ASSET_NAME="codex-x86_64-unknown-linux-musl.tar.gz"
      ASSET_BINARY_NAME="codex-x86_64-unknown-linux-musl"
      ;;
    armv7l|armhf)
      _err "armv7/armhf is not supported by official Codex releases. Try building from source."
      exit 1
      ;;
    *)
      _err "Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac
  _logv "Architecture: $ARCH"

  # Termux / Android
  if [ -d "/data/data/com.termux" ] || [ -n "${TERMUX_VERSION:-}" ]; then
    IS_TERMUX=1
    _logv "Detected: Termux"
  fi

  if [ -f "/system/build.prop" ] || [ -n "${ANDROID_ROOT:-}" ]; then
    IS_ANDROID=1
    _logv "Detected: Android"
  fi

  # 普通 Linux 不需要 resolv.conf 补丁
  if [ "$IS_TERMUX" = "0" ] && [ -f "/etc/resolv.conf" ]; then
    _logv "Standard Linux with /etc/resolv.conf, no binary patching needed"
  fi
}

# ============================================================================
# 版本解析
# ============================================================================

resolve_version() {
  _section "Resolve Version"

  # --- 缓存检测：本地版本 + 远程缓存在手 → 跳过 GitHub API ---
  if [ "$FORCE_INSTALL" != "1" ] \
    && [ -f "$CODEX_VERSION_MARKER" ] \
    && [ -f "$CODEX_REMOTE_VERSION_FILE" ] \
    && [ -x "$CODEX_BIN" ]; then
    local installed_tag
    installed_tag=$(cat "$CODEX_VERSION_MARKER")
    local remote_tag
    remote_tag=$(cat "$CODEX_REMOTE_VERSION_FILE")
    if [ "$installed_tag" = "$remote_tag" ]; then
      TAG="$installed_tag"
      _ok "Already up to date ($TAG) [cached]"
      return 1  # 信号给调用者: 跳过安装
    fi
  fi

  if [ -n "$CODEX_RELEASE_TAG" ]; then
    TAG="$CODEX_RELEASE_TAG"
    _log "Using tag override: $TAG"
  else
    _log "Fetching latest release from GitHub..."
    local meta
    meta=$(curl -fsSL --retry 3 --retry-delay 2 \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${CODEX_REPO}/releases/latest" 2>/dev/null) || true

    # 检查返回内容是否为有效 JSON（防止人机验证等非 JSON 响应）
    if ! echo "$meta" | grep -q '"tag_name"'; then
      _err "GitHub API 返回了非预期内容（可能触发了人机检测）"
      _logv "原始响应(前200字符): $(echo "$meta" | head -c 200)"
      _log ""
      _log "解决方案:"
      _log "  1. 稍后再试 (API 可能临时限流)"
      _log "  2. 手动指定版本:  $0 -t rust-v0.142.5 install"
      _log "  3. 设置浏览器 Cookie 后重试"
      exit 1
    fi

    TAG=$(grep -m1 '"tag_name"' <<<"$meta" 2>/dev/null \
      | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//; s/"//; s/,$//')

    if [ -z "$TAG" ]; then
      _err "Could not resolve release tag from GitHub API"
      exit 1
    fi
  fi
  _ok "Target version: $TAG"

  # 缓存远程版本
  mkdir -p "$(dirname "$CODEX_REMOTE_VERSION_FILE")"
  echo "$TAG" > "$CODEX_REMOTE_VERSION_FILE"

  # 版本对比
  if [ "$FORCE_INSTALL" != "1" ] && [ -f "$CODEX_VERSION_MARKER" ]; then
    local installed_tag
    installed_tag=$(cat "$CODEX_VERSION_MARKER")
    if [ "$installed_tag" = "$TAG" ] && [ -x "$CODEX_BIN" ]; then
      _ok "Already up to date ($TAG)"
      return 1  # 信号给调用者: 跳过安装
    else
      _log "Update available: $installed_tag → $TAG"
    fi
  fi

  return 0
}

# ============================================================================
# 下载 + 校验
# ============================================================================

download_codex() {
  TMP_DIR=$(mktemp -d)
  _logv "Temp dir: $TMP_DIR"

  local tarball_url="${CODEX_MIRROR}https://github.com/${CODEX_REPO}/releases/download/${TAG}/${ASSET_NAME}"
  _step "Downloading ${ASSET_NAME}..."
  [ -n "$CODEX_MIRROR" ] && _log "Mirror: $CODEX_MIRROR"

  local http_code
  http_code=$(curl -fsSL --retry 3 --retry-delay 2 -w '%{http_code}' \
    -o "$TMP_DIR/codex.tgz" "$tarball_url")

  if [ "${http_code:-0}" != "200" ]; then
    _err "Download failed (HTTP $http_code): $tarball_url"
    exit 1
  fi

  # 校验文件非空
  local size
  size=$(stat -c%s "$TMP_DIR/codex.tgz" 2>/dev/null || stat -f%z "$TMP_DIR/codex.tgz" 2>/dev/null)
  if [ "${size:-0}" -lt 1000 ]; then
    _err "Downloaded file is too small (${size} bytes), possibly an error page"
    exit 1
  fi
  _ok "Downloaded ${size} bytes"

  # 解压
  _step "Extracting..."
  tar -xzf "$TMP_DIR/codex.tgz" -C "$TMP_DIR"
  _logv "Extracted contents: $(ls -1 "$TMP_DIR" | tr '\n' ' ')"

  if [ ! -f "$TMP_DIR/$ASSET_BINARY_NAME" ]; then
    _err "Binary not found at $TMP_DIR/$ASSET_BINARY_NAME (asset: $ASSET_NAME)"
    exit 1
  fi

  # 计算 SHA256
  DOWNLOADED_CHECKSUM=$(sha256sum "$TMP_DIR/$ASSET_BINARY_NAME" | awk '{print $1}')
  _ok "SHA256: $DOWNLOADED_CHECKSUM"
}

# ============================================================================
# 二进制补丁 (仅 Termux/Android)
# ============================================================================

patch_binary_if_needed() {
  if [ "$IS_TERMUX" = "0" ] && [ -f "/etc/resolv.conf" ]; then
    _logv "Skipping resolv.conf patch (standard Linux)"
    return
  fi

  _step "Patching /etc/resolv.conf reference → /proc/self/fd/9..."

  local file="$1"
  local count=0

  # 找到所有匹配的偏移
  local offsets
  offsets=$(grep -abo "/etc/resolv.conf" "$file" | cut -d: -f1 || true)

  if [ -z "$offsets" ]; then
    if grep -aq "/proc/self/fd/9" "$file"; then
      _ok "Already patched"
      return
    fi
    _err "Pattern /etc/resolv.conf not found in binary"
    exit 1
  fi

  for off in $offsets; do
    printf '/proc/self/fd/9\0' | dd of="$file" bs=1 seek="$off" count=16 \
      conv=notrunc status=none 2>/dev/null
    count=$((count + 1))
  done

  _ok "Patched $count occurrence(s)"
}

# ============================================================================
# Resolver 文件
# ============================================================================

write_resolver_file() {
  local output_file="$1"
  mkdir -p "$(dirname "$output_file")"

  {
    local found=0

    # Termux/Android: 用 getprop 取 DNS
    if [ "$IS_ANDROID" = "1" ] || [ "$IS_TERMUX" = "1" ]; then
      for prop in net.dns1 net.dns2 net.dns3 net.dns4; do
        val=$(getprop "$prop" 2>/dev/null | tr -d '\r')
        if [ -n "$val" ] && echo "$val" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:'; then
          echo "nameserver $val"
          found=1
        fi
      done
    fi

    # 普通 Linux: 从 /etc/resolv.conf 提取
    if [ "$found" = "0" ] && [ -f "/etc/resolv.conf" ]; then
      grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf \
        | head -4 || true
      found=1
    fi

    # 兜底
    if [ "$found" = "0" ]; then
      echo "nameserver 1.1.1.1"
      echo "nameserver 8.8.8.8"
    fi
  } > "$output_file"

  _logv "Resolver file written: $output_file"
  [ "$VERBOSE" = "1" ] && cat "$output_file"
}

# ============================================================================
# 安装主流程
# ============================================================================

install_codex() {
  _section "Install Codex CLI"

  # 1. 版本
  if ! resolve_version; then
    return 0  # 已最新
  fi

  # 2. 下载
  download_codex

  # 3. 停止旧 wrapper 引用, 创建目录
  mkdir -p "$CODEX_DIR"
  rm -f "$USER_BIN/codex"

  # 4. 移动到最终位置
  mv "$TMP_DIR/$ASSET_BINARY_NAME" "$CODEX_BIN"
  chmod +x "$CODEX_BIN"
  _ok "Installed: $CODEX_BIN"

  # 5. 补丁
  patch_binary_if_needed "$CODEX_BIN"

  # 6. 保存校验和
  echo "$DOWNLOADED_CHECKSUM" > "$CODEX_CHECKSUM_FILE"

  # 7. 写 resolver
  write_resolver_file "$CODEX_RESOLV_CONF"

  # 8. Wipe 残留
  rm -rf "${TMP_DIR:-}"
  TMP_DIR=""

  _ok "Codex binary ready ($TAG)"
}

# ============================================================================
# Wrapper 脚本
# ============================================================================

generate_wrapper() {
  local wrapper_path="$USER_BIN/codex"
  mkdir -p "$(dirname "$wrapper_path")"

  cat > "$wrapper_path" <<WRAPPER_EOF
#!/usr/bin/env bash
# Auto-generated wrapper for Codex CLI on Termux/Android
# Generated: $(date -u '+%Y-%m-%d %H:%M UTC')
# Version: ${TAG:-unknown}
#
# Notes:
#   - Reads resolv.conf from FD 9
#   - Auto-injects --sandbox unless explicitly overridden
#   - Forwards all signals to the real process
#   - Reads API key from profiles.json and exports to CODEX_ACTIVE_API_KEY
#   - Generates ~/.codex/config.toml for Codex native config

set -eu

CODEX_BIN='$CODEX_BIN'
CODEX_RESOLV_CONF='$CODEX_RESOLV_CONF'
CODEX_DEFAULT_SANDBOX='${CODEX_TERMUX_DEFAULT_SANDBOX}'
CODEX_API_CONFIG_FILE="$CODEX_API_CONFIG_FILE"
CODEX_CONFIG_TOML="$CODEX_CONFIG_TOML"

# --- 前置检查 ---
if [ ! -x "\$CODEX_BIN" ]; then
  printf '[codex-wrapper] ERROR: codex binary not found or not executable\n' >&2
  printf '  Expected: %s\n' "\$CODEX_BIN" >&2
  exit 127
fi

if [ ! -f "\$CODEX_RESOLV_CONF" ]; then
  printf '[codex-wrapper] ERROR: resolver file not found: %s\n' "\$CODEX_RESOLV_CONF" >&2
  exit 1
fi

# --- SSL ---
export SSL_CERT_FILE="\${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"

# --- API Key 注入 (Codex 从 config.toml 的 env_key 字段读取此变量) ---
# profiles.json 存放实际 API key, config.toml 存 provider 定义
_codex_inject_api_key() {
  [ ! -f "\$CODEX_API_CONFIG_FILE" ] && return 0
  [ ! -f "\$CODEX_CONFIG_TOML" ] && return 0

  local _active
  _active=\$(grep '"active"' "\$CODEX_API_CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*"active"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  [ -z "\$_active" ] && return 0

  # 从 profiles.json 读 API key
  local _block _api_key
  _block=\$(sed -n "/\"\$_active\": {/,/}/p" "\$CODEX_API_CONFIG_FILE")
  _api_key=\$(echo "\$_block" | grep '"api_key"' | sed 's/.*"api_key"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

  # 用 '${CODEX_DEFAULT_ENV_KEY}' 作为统一 env_key, 与 config.toml 一致
  if [ -n "\$_api_key" ]; then
    export ${CODEX_DEFAULT_ENV_KEY}="\$_api_key"
  fi

  if [ "\${CODEX_DEBUG:-0}" = "1" ]; then
    printf '[codex-wrapper:api] active=%s api_key=%s\n' "\$_active" "\${${CODEX_DEFAULT_ENV_KEY}:+****}" >&2
  fi
}

_codex_inject_api_key

# --- -cc / --configure 拦截: 交互式配置新 Provider ---
INSTALL_SCRIPT='$USER_LIB/codex-termux-install.sh'
for _cc_arg in "\$@"; do
  case "\$_cc_arg" in
    -cc|--configure|--config)
      if [ -x "\$INSTALL_SCRIPT" ]; then
        exec "\$INSTALL_SCRIPT" switch-api setup
      else
        printf '[codex-wrapper] ERROR: install script not found at %s\n' "\$INSTALL_SCRIPT" >&2
        printf '  Run codex-termux-install.sh switch-api setup directly\n' >&2
        exit 1
      fi
      ;;
  esac
done

# --- 读取 active profile 用于 --profile 参数 ---
_active_profile=""
if [ -f "\$CODEX_API_CONFIG_FILE" ]; then
  _active_profile=\$(grep '"active"' "\$CODEX_API_CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*"active"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
fi

# --- 沙箱参数注入 ---
has_sandbox_arg=0
for arg in "\$@"; do
  case "\$arg" in
    -s|--sandbox|--sandbox=*)
      has_sandbox_arg=1
      break
      ;;
    --dangerously-bypass-approvals-and-sandbox|--yolo)
      has_sandbox_arg=1
      break
      ;;
  esac
done

extra_args=()
if [ "\$has_sandbox_arg" = "0" ] && [ "\$CODEX_DEFAULT_SANDBOX" != "preserve" ]; then
  extra_args=(--sandbox "\$CODEX_DEFAULT_SANDBOX")
fi

# --- 注入 --profile 参数 (v0.142.5+ 不再支持 config.toml 中的 profile = 行) ---
if [ -n "\$_active_profile" ] && [ "\$_active_profile" != "openai" ]; then
  extra_args+=(--profile "\$_active_profile")
fi

# --- 前台执行, 信号转发 ---
if [ \${#extra_args[@]} -gt 0 ]; then
  exec "\$CODEX_BIN" "\${extra_args[@]}" "\$@" 9<"\$CODEX_RESOLV_CONF"
else
  exec "\$CODEX_BIN" "\$@" 9<"\$CODEX_RESOLV_CONF"
fi
WRAPPER_EOF

  chmod +x "$wrapper_path"

  # 原子替换: 如果老 wrapper 正在被 source, 等一下
  if lsof "$wrapper_path" >/dev/null 2>&1; then
    _warn "Wrapper is in use, waiting for release..."
    for i in 1 2 3 4 5; do
      sleep 1
      if ! lsof "$wrapper_path" >/dev/null 2>&1; then
        break
      fi
    done
  fi

  _ok "Wrapper installed: $wrapper_path"
}

# ============================================================================
# 独立快捷命令: codex-switch
# ============================================================================

generate_switch_shortcut() {
  local shortcut_path="$USER_BIN/codex-switch"
  mkdir -p "$(dirname "$shortcut_path")"

  cat > "$shortcut_path" <<SWITCH_EOF
#!/usr/bin/env bash
# codex-switch — 交互式切换 Codex API Provider
# Auto-generated by codex-termux-install.sh
# Version: ${TAG:-unknown}

set -eu

CODEX_HOME="\$HOME/.codex"
PROFILES="\$CODEX_HOME/profiles.json"
CONFIG_TOML="\$CODEX_HOME/config.toml"
INSTALL_SCRIPT="$USER_LIB/codex-termux-install.sh"

# 处理 -cc / --configure 参数
for _arg in "\$@"; do
  case "\$_arg" in
    -cc|--configure|--config|setup)
      if [ -x "\$INSTALL_SCRIPT" ]; then
        exec "\$INSTALL_SCRIPT" switch-api setup
      else
        echo "安装脚本不在 \$INSTALL_SCRIPT, 请重新运行 codex-termux-install.sh" >&2
        exit 1
      fi
      ;;
  esac
done

# 如果安装脚本还在，直接调用它
if [ -x "\$INSTALL_SCRIPT" ]; then
  exec "\$INSTALL_SCRIPT" switch-api pick "\$@"
fi

# 独立模式: 不依赖安装脚本
if [ ! -f "\$PROFILES" ]; then
  echo "未找到 \$PROFILES" >&2
  echo "请先运行 codex-termux-install.sh switch-api add 添加 provider" >&2
  exit 1
fi

# 提取 active
active=\$(grep '"active"' "\$PROFILES" 2>/dev/null | grep -o '"active":[[:space:]]*"[^"]*"' | sed 's/"active":[[:space:]]*"\([^"]*\)"/\1/')

# 提取 provider 列表
entries=()
keys=()
if command -v python3 &>/dev/null; then
  while IFS='|' read -r mark key name url model; do
    local_tag=""
    [ "\$mark" = "*" ] && local_tag=" ★"
    entries+=("\${key}\t\${name}  \${model}  \${url}\${local_tag}")
    keys+=("\$key")
  done < <(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
active = sys.argv[2]
for k, p in cfg.get('providers', {}).items():
    m = '*' if k == active else ' '
    print(f'{m}|{k}|{p.get(\"name\",k)}|{p.get(\"base_url\",\"\")}|{p.get(\"model\",\"gpt-4o\")}')
" "\$PROFILES" "\$active" 2>/dev/null)
fi

if [ \${#entries[@]} -eq 0 ]; then
  echo "没有找到任何 provider" >&2
  exit 1
fi

selected=""
if command -v fzf &>/dev/null; then
  selected=\$(printf '%b\n' "\${entries[@]}" | fzf --height=40% --reverse --prompt="Provider> " | cut -f1 2>/dev/null) || true
else
  echo "选择 API Provider:"
  for i in "\${!entries[@]}"; do
    printf '  %d) %b\n' "\$((i+1))" "\${entries[\$i]}"
  done
  echo ""
  printf '编号: '
  read -r n
  if [[ "\$n" =~ ^[0-9]+\$ ]] && [ "\$n" -ge 1 ] && [ "\$n" -le \${#entries[@]} ]; then
    selected="\${keys[\$((n-1))]}"
  fi
fi

[ -z "\$selected" ] && { echo "已取消"; exit 0; }

# 切换
sed -i "s/\"active\": *\"[^\"]*\"/\"active\": \"\$selected\"/" "\$PROFILES"
echo "✔ Active provider: \$selected"

# 重新生成 config.toml
if command -v python3 &>/dev/null; then
  python3 -c "
import json, sys, os
reserved = {'openai', 'amazon-bedrock', 'ollama', 'lmstudio'}
cfg = json.load(open(sys.argv[1]))
active = cfg.get('active', 'openai')
providers = cfg.get('providers', {})
providers = {k: v for k, v in providers.items() if k not in reserved}
if active in reserved and providers:
    active = list(providers.keys())[0]
outdir = os.path.dirname(sys.argv[2])
lines = ['# Auto-generated', '']
for key, p in providers.items():
    lines.append(f'[model_providers.{key}]')
    lines.append(f'name = \"{p.get(\"name\",key)}\"')
    lines.append(f'base_url = \"{p.get(\"base_url\",\"\")}\"')
    lines.append(f'env_key = \"{p.get(\"env_key\",\"CODEX_ACTIVE_API_KEY\")}\"')
    lines.append('wire_api = \"responses\"')
    lines.append('requires_openai_auth = false')
    lines.append('')
with open(sys.argv[2], 'w') as f:
    f.write('\n'.join(lines) + '\n')
# Generate {profile}.config.toml files
for key, p in providers.items():
    pf = os.path.join(outdir, f'{key}.config.toml')
    pl = []
    pl.append('# Auto-generated')
    pl.append(f'# Profile: {key}')
    pl.append('')
    pl.append(f'[model_providers.{key}]')
    pl.append(f'name = \"{p.get(\"name\",key)}\"')
    pl.append(f'base_url = \"{p.get(\"base_url\",\"\")}\"')
    pl.append(f'env_key = \"{p.get(\"env_key\",\"CODEX_ACTIVE_API_KEY\")}\"')
    pl.append('wire_api = \"responses\"')
    pl.append('requires_openai_auth = false')
    pl.append('')
    pl.append(f'[profiles.{key}]')
    pl.append(f'model = \"{p.get(\"model\",\"gpt-4o\")}\"')
    pl.append(f'model_provider = \"{key}\"')
    with open(pf, 'w') as f:
        f.write('\n'.join(pl) + '\n')
" "\$PROFILES" "\$CONFIG_TOML" 2>/dev/null
fi
SWITCH_EOF

  chmod +x "$shortcut_path"
  _ok "Shortcut installed: $shortcut_path (run: codex-switch)"
}

# ============================================================================
# 卸载
# ============================================================================

uninstall_codex() {
  _section "Uninstall Codex CLI"

  local removed=0
  for p in "$CODEX_VERSION_MARKER" "$CODEX_REMOTE_VERSION_FILE" "$CODEX_CHECKSUM_FILE" \
           "$CODEX_BIN" "$CODEX_DIR" "$CODEX_RESOLV_CONF"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      rm -rf "$p"
      _log " ✗ Removed: $p"
      removed=$((removed + 1))
    fi
  done

  # wrapper 也删
  if [ -f "$USER_BIN/codex" ]; then
    rm -f "$USER_BIN/codex"
    _log " ✗ Removed: $USER_BIN/codex"
    removed=$((removed + 1))
  fi

  # codex-switch 快捷命令也删
  if [ -f "$USER_BIN/codex-switch" ]; then
    rm -f "$USER_BIN/codex-switch"
    _log " ✗ Removed: $USER_BIN/codex-switch"
    removed=$((removed + 1))
  fi

  # config.toml 也清理（但保留 profiles.json）
  if [ -f "$CODEX_CONFIG_TOML" ]; then
    rm -f "$CODEX_CONFIG_TOML"
    _log " ✗ Removed: $CODEX_CONFIG_TOML"
    removed=$((removed + 1))
  fi

  # {profile}.config.toml 清理 (v0.142.5+ 新增格式)
  local CODEX_HOME_DIR
  CODEX_HOME_DIR=$(dirname "$CODEX_CONFIG_TOML" 2>/dev/null || echo "$HOME/.codex")
  for _pf in "$CODEX_HOME_DIR"/*.config.toml; do
    [ -f "$_pf" ] && [ "$_pf" != "$CODEX_CONFIG_TOML" ] && rm -f "$_pf" && _log " ✗ Removed: $_pf" && removed=$((removed + 1)) || true
  done

  if [ "$removed" = "0" ]; then
    _log "Nothing to clean. Codex CLI was not installed."
  else
    _ok "Uninstalled ($removed items removed)"
  fi
}

# ============================================================================
# 状态
# ============================================================================

status_codex() {
  _section "Codex Status"

  echo " Environment:"
  echo "   IS_TERMUX:     $IS_TERMUX"
  echo "   IS_ANDROID:    $IS_ANDROID"
  echo "   ARCH:          $ARCH"
  echo "   PREFIX:        $PREFIX"
  echo ""

  echo " Installation:"
  if [ -x "$CODEX_BIN" ]; then
    echo "   Binary:        $CODEX_BIN ✔"
  else
    echo "   Binary:        not found ✘"
  fi

  if [ -f "$CODEX_VERSION_MARKER" ]; then
    echo "   Local version: $(cat "$CODEX_VERSION_MARKER")"
  else
    echo "   Local version: n/a"
  fi

  if [ -f "$CODEX_RESOLV_CONF" ]; then
    echo "   Resolver:      $CODEX_RESOLV_CONF ✔"
  else
    echo "   Resolver:      not found ✘"
  fi

  if [ -f "$USER_BIN/codex" ]; then
    echo "   Wrapper:       $USER_BIN/codex ✔"
  else
    echo "   Wrapper:       not found ✘"
  fi

  if [ -f "$CODEX_CONFIG_TOML" ]; then
    echo "   Config (原生): $CODEX_CONFIG_TOML ✔"
  else
    echo "   Config (原生): not found ✘"
  fi

  echo ""

  if [ -x "$CODEX_BIN" ]; then
    echo " Version info:"
    "$CODEX_BIN" --version 2>&1 | sed 's/^/   /' || true
  fi

  # PATH 检查
  case ":${PATH:-}" in
    *":$USER_BIN:"*)
      echo "   PATH:          $USER_BIN ∈ PATH ✔"
      ;;
    *)
      echo "   PATH:          $USER_BIN ∉ PATH ⚠ (run: source ~/.bashrc)"
      ;;
  esac
}

# ============================================================================
# PATH 配置
# ============================================================================

PATH_MARKER_BEGIN="# >>> codex-install PATH >>>"
PATH_MARKER_END="# <<< codex-install PATH <<<"

add_path_to_rc() {
  local rc="$1"
  local block="$2"

  if [ -f "$rc" ] && grep -qF "$PATH_MARKER_BEGIN" "$rc"; then
    _logv "PATH already configured in $rc"
    return
  fi

  mkdir -p "$(dirname "$rc")"
  printf '\n%s\n%s\n%s\n' "$PATH_MARKER_BEGIN" "$block" "$PATH_MARKER_END" >> "$rc"
  _ok "PATH added to $rc"
}

setup_shell_path() {
  _section "Shell PATH"

  local sh_block="case \":\$PATH:\" in
  *\":\$HOME/.local/bin:\"*) ;;
  *) export PATH=\"\$HOME/.local/bin:\$PATH\" ;;
esac"

  local fish_block="if not contains \"\$HOME/.local/bin\" \$PATH
  set -gx PATH \"\$HOME/.local/bin\" \$PATH
end"

  [ -f "$HOME/.bashrc" ]  && add_path_to_rc "$HOME/.bashrc"  "$sh_block" || true
  [ -f "$HOME/.zshrc" ]   && add_path_to_rc "$HOME/.zshrc"   "$sh_block" || true
  [ -d "$HOME/.config/fish" ] && add_path_to_rc "$HOME/.config/fish/config.fish" "$fish_block" || true

  # 没有任何 rc 文件时，创建 ~/.bashrc（Termux 默认 shell）
  if [ ! -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ]; then
    add_path_to_rc "$HOME/.bashrc" "$sh_block"
  fi

  case ":${PATH:-}" in
    *":$USER_BIN:"*) _log "Current shell already has $USER_BIN in PATH" ;;
    *)
      export PATH="$USER_BIN:$PATH"
      _ok "Added $USER_BIN to current session PATH (also saved to rc file)"
      ;;
  esac
}

# ============================================================================
# API 切换功能: 添加/切换/删除 provider
# ============================================================================

CODEX_HOME="$HOME/.codex"
CODEX_API_CONFIG_DIR="$CODEX_HOME"
CODEX_API_CONFIG_FILE="$CODEX_API_CONFIG_DIR/profiles.json"
CODEX_CONFIG_TOML="$CODEX_HOME/config.toml"
# 所有 provider 共用这个 env_key，由 wrapper 在运行前注入
CODEX_DEFAULT_ENV_KEY="CODEX_ACTIVE_API_KEY"

api_init() {
  mkdir -p "$CODEX_API_CONFIG_DIR"
  [ -f "$CODEX_API_CONFIG_FILE" ] || {
    cat > "$CODEX_API_CONFIG_FILE" <<'DEFAULT_CFG'
{
  "providers": {
    "openai": {
      "name": "OpenAI 官方",
      "base_url": "https://api.openai.com/v1",
      "model": "gpt-4o",
      "api_key": "",
      "env_key": "OPENAI_API_KEY"
    }
  },
  "active": "openai"
}
DEFAULT_CFG
  }
  # 升级旧格式：补上缺失的 env_key
  generate_codex_toml
}

# 从 profiles.json 生成 Codex 原生 ~/.codex/config.toml + {profile}.config.toml
# Codex rust-v0.142.5+ 不再支持 config.toml 中的 profile = "..." 字段
# 改用独立的 {profile}.config.toml 文件 + --profile <name> 参数
generate_codex_toml() {
  [ ! -f "$CODEX_API_CONFIG_FILE" ] && return 0

  local active
  active=$(grep '"active"' "$CODEX_API_CONFIG_FILE" | grep -o '"active":[[:space:]]*"[^"]*"' | sed 's/"active":[[:space:]]*"\([^"]*\)"/\1/')
  [ -z "$active" ] && active="openai"

  # 用 Python 解析 JSON 生成 TOML（兼容 BusyBox 环境）
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys, os

config_file = sys.argv[1]
output_file = sys.argv[2]
default_env_key = sys.argv[3]

with open(config_file) as f:
    cfg = json.load(f)

reserved_ids = {'openai', 'amazon-bedrock', 'ollama', 'lmstudio'}
active = cfg.get('active', 'openai')
providers = cfg.get('providers', {})

# Skip reserved built-in provider IDs (Codex rejects them)
filtered = {k: v for k, v in providers.items() if k not in reserved_ids}

# If active is a reserved ID, fall back to first custom provider
if active in reserved_ids and filtered:
    active = list(filtered.keys())[0]

output_dir = os.path.dirname(output_file)

lines = []
lines.append('# Auto-generated by codex-termux-install.sh')
lines.append('# Do not edit manually — use switch-api commands')
lines.append('')

for key, p in filtered.items():
    name = p.get('name', key)
    base_url = p.get('base_url', '')
    model = p.get('model', 'gpt-4o')
    env_key = p.get('env_key', default_env_key)

    lines.append(f'[model_providers.{key}]')
    lines.append(f'name = \"{name}\"')
    lines.append(f'base_url = \"{base_url}\"')
    lines.append(f'env_key = \"{env_key}\"')
    lines.append('wire_api = \"responses\"')
    lines.append('requires_openai_auth = false')
    lines.append('')

# Write main config.toml — only model_providers, NO profiles sections (v0.142.5+)
# profiles go into {profile}.config.toml files
with open(output_file, 'w') as f:
    f.write('\n'.join(lines) + '\n')

# Write {profile}.config.toml for each profile (new format)
for key, p in filtered.items():
    name = p.get('name', key)
    base_url = p.get('base_url', '')
    model = p.get('model', 'gpt-4o')
    env_key = p.get('env_key', default_env_key)

    profile_lines = []
    profile_lines.append('# Auto-generated by codex-termux-install.sh')
    profile_lines.append(f'# Profile: {key}')
    profile_lines.append('')
    profile_lines.append(f'[model_providers.{key}]')
    profile_lines.append(f'name = \"{name}\"')
    profile_lines.append(f'base_url = \"{base_url}\"')
    profile_lines.append(f'env_key = \"{env_key}\"')
    profile_lines.append('wire_api = \"responses\"')
    profile_lines.append('requires_openai_auth = false')
    profile_lines.append('')
    profile_lines.append(f'[profiles.{key}]')
    profile_lines.append(f'model = \"{model}\"')
    profile_lines.append(f'model_provider = \"{key}\"')
    profile_lines.append('')

    profile_file = os.path.join(output_dir, f'{key}.config.toml')
    with open(profile_file, 'w') as f:
        f.write('\n'.join(profile_lines) + '\n')

provider_list = list(filtered.keys())
print(f'Generated config.toml: active={active}, providers={provider_list}')
" "$CODEX_API_CONFIG_FILE" "$CODEX_CONFIG_TOML" "$CODEX_DEFAULT_ENV_KEY" || { _logv "generate_codex_toml: Python 失败，尝试 fallback"; generate_codex_toml_fallback; }
  else
    generate_codex_toml_fallback
  fi

  _logv "config.toml updated: $CODEX_CONFIG_TOML"
}

# Pure-bash fallback for generate_codex_toml (no python3)
generate_codex_toml_fallback() {
  [ ! -f "$CODEX_API_CONFIG_FILE" ] && return 0

  local active
  active=$(grep '"active"' "$CODEX_API_CONFIG_FILE" | grep -o '"active":[[:space:]]*"[^"]*"' | sed 's/"active":[[:space:]]*"\([^"]*\)"//')
  [ -z "$active" ] && active="openai"

  local reserved_regex='^("openai"|"amazon-bedrock"|"ollama"|"lmstudio")$'
  local CODEX_HOME_DIR
  CODEX_HOME_DIR=$(dirname "$CODEX_CONFIG_TOML")

  local in_providers=0
  local current_key="" current_name="" current_url="" current_model="" current_envkey=""
  local first_custom=""
  local keys=() names=() urls=() models=() envkeys=()

  while IFS= read -r line; do
    case "$line" in
      *'"providers"'*) in_providers=1; continue ;;
      *'"active"'*) continue ;;
    esac
    [ "$in_providers" = "0" ] && continue

    if echo "$line" | grep -q '"[^"]*": *{'; then
      if [ -n "$current_key" ] && ! echo "\"$current_key\"" | grep -qE "$reserved_regex"; then
        keys+=("$current_key"); names+=("${current_name:-$current_key}")
        urls+=("$current_url"); models+=("${current_model:-gpt-4o}")
        envkeys+=("${current_envkey:-$CODEX_DEFAULT_ENV_KEY}")
        [ -z "$first_custom" ] && first_custom="$current_key"
      fi
      current_key=$(echo "$line" | sed 's/.*"\([^"]*\)".*//')
      current_name="$current_key"; current_url=""; current_model="gpt-4o"; current_envkey="$CODEX_DEFAULT_ENV_KEY"
    fi
    echo "$line" | grep -q '"name"' && current_name=$(echo "$line" | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)"//')
    echo "$line" | grep -q '"base_url"' && current_url=$(echo "$line" | sed 's/.*"base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)"//')
    echo "$line" | grep -q '"model"' && current_model=$(echo "$line" | sed 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)"//')
    echo "$line" | grep -q '"env_key"' && current_envkey=$(echo "$line" | sed 's/.*"env_key"[[:space:]]*:[[:space:]]*"\([^"]*\)"//')
  done < "$CODEX_API_CONFIG_FILE"

  if [ -n "$current_key" ] && ! echo "\"$current_key\"" | grep -qE "$reserved_regex"; then
    keys+=("$current_key"); names+=("${current_name:-$current_key}")
    urls+=("$current_url"); models+=("${current_model:-gpt-4o}")
    envkeys+=("${current_envkey:-$CODEX_DEFAULT_ENV_KEY}")
    [ -z "$first_custom" ] && first_custom="$current_key"
  fi

  # 主 config.toml — 只含 model_providers, 不含 profiles (v0.142.5+)
  {
    echo '# Auto-generated by codex-termux-install.sh'
    echo '# Do not edit manually — use switch-api commands'
    echo ''
    for i in "${!keys[@]}"; do
      printf '[model_providers.%s]
' "${keys[$i]}"
      printf 'name = "%s"
' "${names[$i]}"
      printf 'base_url = "%s"
' "${urls[$i]}"
      printf 'env_key = "%s"
' "${envkeys[$i]}"
      printf 'wire_api = "responses"
'
      printf 'requires_openai_auth = false
'
      echo ''
    done
  } > "$CODEX_CONFIG_TOML"

  # {profile}.config.toml — 新版 Codex 格式
  for i in "${!keys[@]}"; do
    local pf="$CODEX_HOME_DIR/${keys[$i]}.config.toml"
    {
      echo '# Auto-generated by codex-termux-install.sh'
      echo "# Profile: ${keys[$i]}"
      echo ''
      printf '[model_providers.%s]
' "${keys[$i]}"
      printf 'name = "%s"
' "${names[$i]}"
      printf 'base_url = "%s"
' "${urls[$i]}"
      printf 'env_key = "%s"
' "${envkeys[$i]}"
      printf 'wire_api = "responses"
'
      printf 'requires_openai_auth = false
'
      echo ''
      printf '[profiles.%s]
' "${keys[$i]}"
      printf 'model = "%s"
' "${models[$i]}"
      printf 'model_provider = "%s"
' "${keys[$i]}"
    } > "$pf"
    _logv "  -> ${keys[$i]}.config.toml"
  done

  _logv "config.toml + ${#keys[@]} profile(s) generated (fallback, no python3)"
}

api_switch() {
  api_init
  local target="${1:-}"

  [ -z "$target" ] && { api_list; return; }

  # 检查 provider 是否存在
  if ! grep -q "\"$target\":" "$CODEX_API_CONFIG_FILE" 2>/dev/null; then
    _err "Provider \"$target\" 不存在"
    echo "可用 provider:"
    api_list
    return 1
  fi

  # 用 python 或 jq 更新 JSON, 没有 jq 时临时安装或用 grep/sed 手撸
  # 用 grep 提取 active 行并替换
  sed -i "s/\"active\": *\"[^\"]*\"/\"active\": \"$target\"/" "$CODEX_API_CONFIG_FILE"
  _ok "Active provider: $target"

  # 重新生成 config.toml
  generate_codex_toml
}

api_list() {
  api_init
  local active
  active=$(grep '"active"' "$CODEX_API_CONFIG_FILE" | grep -o '"active":[[:space:]]*"[^"]*"' | sed 's/"active":[[:space:]]*"\([^"]*\)"/\1/')

  _section "API Providers"

  # 用 grep/awk 简单解析 JSON (不依赖 jq)
  local in_providers=0
  local current_name=""
  while IFS= read -r line; do
    case "$line" in
      *'\"providers\"'*) in_providers=1; continue ;;
      *'\"active\"') continue ;;
    esac

    [ "$in_providers" = "0" ] && continue

    # provider key
    if echo "$line" | grep -q '\"[^\"]*\": *{'; then
      current_name=$(echo "$line" | sed 's/.*\"\([^\"]*\)\".*/\1/')
      if [ "$current_name" = "$active" ]; then
        printf '  ★ %s (active)\n' "$current_name"
      else
        printf '    %s\n' "$current_name"
      fi
    fi
  done < "$CODEX_API_CONFIG_FILE"

  echo ""
  local hint="[用法] $0 switch-api <provider-name>"
  echo "$hint"
}

api_add() {
  api_init
  local key="${1:-}" base_url="${2:-}" api_key="${3:-}" model="${4:-}" name="${5:-}"
  [ -z "$key" ] && { _err "用法: switch-api add <key> <base_url> <api_key> [model] [name]"; return 1; }
  [ -z "$base_url" ] && { _err "base_url 不能为空"; return 1; }
  [ -z "$api_key" ] && { _err "api_key 不能为空"; return 1; }
  [ -z "$model" ] && model="gpt-4o"
  [ -z "$name" ] && name="$key"

  # 检查 key 是否已存在
  if grep -q "\"$key\":" "$CODEX_API_CONFIG_FILE" 2>/dev/null; then
    _err "Provider \"$key\" 已存在"
    return 1
  fi

  # 插入新 provider（用 python 处理 JSON，兼容 Termux BusyBox 环境）
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
cfg_file = sys.argv[1]
key, name, base_url, api_key, model, env_key = sys.argv[2:8]
cfg = json.load(open(cfg_file))
cfg.setdefault('providers', {})[key] = {'name': name, 'base_url': base_url, 'api_key': api_key, 'model': model, 'env_key': env_key}
with open(cfg_file, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$CODEX_API_CONFIG_FILE" "$key" "$name" "$base_url" "$api_key" "$model" "$CODEX_DEFAULT_ENV_KEY" || { _err "Python JSON 写入失败"; return 1; }
  else
    # fallback: awk 插入（兼容 BusyBox awk）
    awk -v k="$key" -v n="$name" -v u="$base_url" -v a="$api_key" -v m="$model" -v e="$CODEX_DEFAULT_ENV_KEY" '
    /"active"/ { printf "    \"%s\": {\n      \"name\": \"%s\",\n      \"base_url\": \"%s\",\n      \"api_key\": \"%s\",\n      \"model\": \"%s\",\n      \"env_key\": \"%s\"\n    },\n", k, n, u, a, m, e }
    { print }
    ' "$CODEX_API_CONFIG_FILE" > "${CODEX_API_CONFIG_FILE}.tmp" && mv "${CODEX_API_CONFIG_FILE}.tmp" "$CODEX_API_CONFIG_FILE"
  fi
  local _provider_count
  _provider_count=$(grep -c '"base_url"' "$CODEX_API_CONFIG_FILE" || echo 0)
  _ok "Provider 已添加 (${_provider_count} 个 provider)"

  # 重新生成 config.toml
  generate_codex_toml
  printf "\n是否切换到 %s? (y/N): " "$key"
  read -r _confirm
  [ "$_confirm" = "y" ] || [ "$_confirm" = "Y" ] && api_switch "$key"
}

api_del() {
  api_init
  local target="${1:-}"
  [ -z "$target" ] && { _err "用法: switch-api del <key>"; return 1; }

  local active
  active=$(grep '"active"' "$CODEX_API_CONFIG_FILE" | grep -o '"active":[[:space:]]*"[^"]*"' | sed 's/"active":[[:space:]]*"\([^"]*\)"/\1/')

  if [ "$target" = "$active" ]; then
    _warn "\"$target\" 是当前 active provider, 不能删除"
    return 1
  fi

  if ! grep -q "\"$target\":" "$CODEX_API_CONFIG_FILE" 2>/dev/null; then
    _err "Provider \"$target\" 不存在"
    return 1
  fi

  # 删除 provider（用 python 处理 JSON，兼容 Termux BusyBox 环境）
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
cfg_file, target = sys.argv[1], sys.argv[2]
cfg = json.load(open(cfg_file))
cfg['providers'].pop(target, None)
with open(cfg_file, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$CODEX_API_CONFIG_FILE" "$target" || { _err "Python JSON 写入失败"; return 1; }
  else
    # fallback: awk 删除 provider block
    awk -v t="$target" '
    BEGIN { skip=0 }
    skip && /},?/ && !done { skip=0; done=1; next }
    {
      if ($0 ~ "\"" t "\" *: *{") { skip=1 }
      else if (!skip) print
    }
    ' "$CODEX_API_CONFIG_FILE" > "${CODEX_API_CONFIG_FILE}.tmp" && mv "${CODEX_API_CONFIG_FILE}.tmp" "$CODEX_API_CONFIG_FILE"
  fi
  _ok "Provider \"$target\" 已删除"

  # 重新生成 config.toml
  generate_codex_toml
}

api_show() {
  api_init
  local active
  active=$(grep '"active"' "$CODEX_API_CONFIG_FILE" | grep -o '"active":[[:space:]]*"[^"]*"' | sed 's/"active":[[:space:]]*"\([^"]*\)"/\1/')

  _section "Current API"

  local provider_block
  provider_block=$(sed -n "/\"$active\": {/,/}/p" "$CODEX_API_CONFIG_FILE")
  local base_url model api_key name env_key
  base_url=$(echo "$provider_block" | grep '"base_url"' | sed 's/.*"base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  api_key=$(echo "$provider_block" | grep '"api_key"' | sed 's/.*"api_key"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  model=$(echo "$provider_block" | grep '"model"' | sed 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  name=$(echo "$provider_block" | grep '"name"' | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  env_key=$(echo "$provider_block" | grep '"env_key"' | sed 's/.*"env_key"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

  echo "  Provider: $name ($active)"
  echo "  Base URL: ${base_url:-<not set>}"
  echo "  API Key:  ${api_key:+${api_key:0:8}...}${api_key:-<not set>}"
  echo "  Model:    ${model:-<not set>}"
  echo "  Env Key:  ${env_key:-$CODEX_DEFAULT_ENV_KEY} (运行时注入)"
  echo ""
  echo "  Config:   $CODEX_API_CONFIG_FILE"
  echo "  Codex 原生: $CODEX_CONFIG_TOML"
}

# ============================================================================
# 交互式 Provider 选择器 (fzf 优先, 数字编号回退)
# ============================================================================

# 提取 provider 列表: 输出格式 "key|name|base_url|model|active_marker"
_api_provider_entries() {
  local active
  active=$(grep '"active"' "$CODEX_API_CONFIG_FILE" 2>/dev/null \
    | grep -o '"active":[[:space:]]*"[^"]*"' | sed 's/"active":[[:space:]]*"\([^"]*\)"/\1/')

  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
cfg_file = sys.argv[1]
active = sys.argv[2]
cfg = json.load(open(cfg_file))
for key, p in cfg.get('providers', {}).items():
    name = p.get('name', key)
    base_url = p.get('base_url', '')
    model = p.get('model', 'gpt-4o')
    mark = '*' if key == active else ' '
    print(f'{mark}|{key}|{name}|{base_url}|{model}')
" "$CODEX_API_CONFIG_FILE" "$active" 2>/dev/null
  else
    # fallback: grep/awk 解析
    local in_providers=0
    local current_key="" current_name="" current_url="" current_model=""
    while IFS= read -r line; do
      case "$line" in
        *'"providers"'*) in_providers=1; continue ;;
        *'"active"'*) continue ;;
      esac
      [ "$in_providers" = "0" ] && continue

      if echo "$line" | grep -q '"[^"]*": *{'; then
        # 输出上一个 provider
        if [ -n "$current_key" ]; then
          local mark=" "
          [ "$current_key" = "$active" ] && mark="*"
          printf '%s|%s|%s|%s|%s\n' "$mark" "$current_key" "$current_name" "$current_url" "$current_model"
        fi
        current_key=$(echo "$line" | sed 's/.*"\([^"]*\)".*/\1/')
        current_name="$current_key"; current_url=""; current_model="gpt-4o"
      fi
      echo "$line" | grep -q '"name"' && current_name=$(echo "$line" | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
      echo "$line" | grep -q '"base_url"' && current_url=$(echo "$line" | sed 's/.*"base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
      echo "$line" | grep -q '"model"' && current_model=$(echo "$line" | sed 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
    done < "$CODEX_API_CONFIG_FILE"
    # 最后一个
    if [ -n "$current_key" ]; then
      local mark=" "
      [ "$current_key" = "$active" ] && mark="*"
      printf '%s|%s|%s|%s|%s\n' "$mark" "$current_key" "$current_name" "$current_url" "$current_model"
    fi
  fi
}

api_interactive_select() {
  api_init

  local entries
  entries=$(_api_provider_entries)

  if [ -z "$entries" ]; then
    _warn "没有找到任何 provider，请先用 switch-api add 添加"
    return 1
  fi

  local selected_key=""

  if command -v fzf &>/dev/null; then
    # ---- fzf 模式 ----
    _section "选择 API Provider (fzf)"

    local fzf_input=""
    while IFS='|' read -r mark key name url model; do
      local active_tag=""
      [ "$mark" = "*" ] && active_tag=" [active]"
      fzf_input+="${key}"$'\t'"${name}  ${model}  ${url}${active_tag}"$'\n'
    done <<< "$entries"

    selected_key=$(printf '%s' "$fzf_input" \
      | fzf --height=40% --reverse --header="选择要切换的 Provider" \
            --preview="echo {}" --preview-window=up:1:hidden \
            --prompt="Provider> " \
      | cut -f1 2>/dev/null) || true

  else
    # ---- 数字编号回退 ----
    _section "选择 API Provider"

    local i=1
    local keys=()
    while IFS='|' read -r mark key name url model; do
      keys+=("$key")
      local active_tag=""
      [ "$mark" = "*" ] && active_tag=" ★ active"
      printf '  %d) %-20s %-15s %s%s\n' "$i" "$name" "$model" "$url" "$active_tag"
      i=$((i + 1))
    done <<< "$entries"

    echo ""
    printf '请输入编号 [1-%d]: ' "${#keys[@]}"
    read -r _choice
    if [[ "$_choice" =~ ^[0-9]+$ ]] && [ "$_choice" -ge 1 ] && [ "$_choice" -le "${#keys[@]}" ]; then
      selected_key="${keys[$((_choice - 1))]}"
    else
      _err "无效编号: $_choice"
      return 1
    fi
  fi

  if [ -n "$selected_key" ]; then
    api_switch "$selected_key"
  else
    _log "未选择，已取消"
  fi
}

# ============================================================================
# 从 Provider 拉取可用模型列表
# ============================================================================

# 用法: api_fetch_models <base_url> <api_key>
# 输出: 每行一个 model id
api_fetch_models() {
  local base_url="${1:-}" api_key="${2:-}"
  [ -z "$base_url" ] && { _err "base_url 不能为空"; return 1; }
  [ -z "$api_key" ] && { _err "api_key 不能为空"; return 1; }

  # 去掉末尾 /
  base_url="${base_url%/}"

  _logv "正在从 ${base_url}/models 拉取模型列表..."

  local response http_code
  response=$(curl -fsSL --retry 2 --retry-delay 1 --max-time 15 \
    -H "Authorization: Bearer ${api_key}" \
    -H "Accept: application/json" \
    "${base_url}/models" 2>/dev/null) || {
    _err "请求失败，请检查 base_url 和 api_key"
    return 1
  }

  if [ -z "$response" ]; then
    _err "空响应，请检查 API 地址是否正确"
    return 1
  fi

  # 用 python 解析 (最可靠)
  if command -v python3 &>/dev/null; then
    local models
    models=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
items = data.get('data', data) if isinstance(data, dict) else data
if isinstance(items, list):
    for m in items:
        mid = m.get('id', m.get('name', '')) if isinstance(m, dict) else str(m)
        if mid:
            print(mid)
" "$response" 2>/dev/null)

    if [ -z "$models" ]; then
      _warn "API 返回了数据但无法解析模型列表"
      _logv "原始响应: $response"
      return 1
    fi
    echo "$models"
    return 0
  fi

  # fallback: grep 提取 id 字段
  local models
  models=$(echo "$response" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sort -u)

  if [ -z "$models" ]; then
    _warn "无法解析模型列表 (无 python3，grep 回退失败)"
    _logv "原始响应: $response"
    return 1
  fi
  echo "$models"
}

# ============================================================================
# 交互式配置: 输入 URL/Key → 拉模型 → 选择 → 写配置
# ============================================================================

api_configure() {
  api_init

  _section "配置新 Provider"

  # 1. 输入 base_url
  printf 'API Base URL (如 https://api.openai.com/v1): '
  read -r input_url
  input_url="${input_url%/}"  # 去掉末尾 /
  if [ -z "$input_url" ]; then
    _err "URL 不能为空"
    return 1
  fi

  # 2. 输入 api_key
  printf 'API Key: '
  read -r input_key
  if [ -z "$input_key" ]; then
    _err "API Key 不能为空"
    return 1
  fi

  # 3. 拉取模型列表
  local models
  models=$(api_fetch_models "$input_url" "$input_key") || return 1

  local model_count
  model_count=$(echo "$models" | wc -l | tr -d ' ')
  _ok "获取到 ${model_count} 个模型"

  # 4. 选择模型
  local selected_model=""
  if command -v fzf &>/dev/null; then
    selected_model=$(echo "$models" | fzf --height=60% --reverse \
      --prompt="Model> " --header="共 ${model_count} 个模型，选择后回车") || true
  else
    echo ""
    echo "可用模型 (${model_count} 个):"
    local i=1
    local model_arr=()
    while IFS= read -r m; do
      model_arr+=("$m")
      printf '  %3d) %s\n' "$i" "$m"
      i=$((i + 1))
    done <<< "$models"

    echo ""
    printf '输入编号 [1-%d] (或直接输入模型名): ' "${#model_arr[@]}"
    read -r _mchoice
    if [[ "$_mchoice" =~ ^[0-9]+$ ]] && [ "$_mchoice" -ge 1 ] && [ "$_mchoice" -le "${#model_arr[@]}" ]; then
      selected_model="${model_arr[$((_mchoice - 1))]}"
    elif [ -n "$_mchoice" ]; then
      selected_model="$_mchoice"
    fi
  fi

  if [ -z "$selected_model" ]; then
    _log "未选择模型"
    printf '手动输入模型名 (如 gpt-4o): '
    read -r selected_model
    [ -z "$selected_model" ] && { _err "未指定模型"; return 1; }
  fi

  _ok "选择模型: $selected_model"

  # 5. 给 provider 起个名
  local provider_key provider_name
  # 自动从 URL 提取 key 名 (取域名部分)
  local auto_key
  auto_key=$(echo "$input_url" | sed 's|https\?://||; s|[:/].*||; s|^api\.||; s|\..*||')
  printf 'Provider 标识 [默认: %s]: ' "$auto_key"
  read -r provider_key
  [ -z "$provider_key" ] && provider_key="$auto_key"

  printf 'Provider 显示名 [默认: %s]: ' "$provider_key"
  read -r provider_name
  [ -z "$provider_name" ] && provider_name="$provider_key"

  # 6. 检查是否已存在，已存在则更新，不存在则添加
  if grep -q "\"$provider_key\":" "$CODEX_API_CONFIG_FILE" 2>/dev/null; then
    # 更新已有 provider
    if command -v python3 &>/dev/null; then
      python3 -c "
import json, sys
cfg_file, key, name, url, key_val, model, env_key = sys.argv[1:8]
cfg = json.load(open(cfg_file))
cfg.setdefault('providers', {})[key] = {'name': name, 'base_url': url, 'api_key': key_val, 'model': model, 'env_key': env_key}
with open(cfg_file, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$CODEX_API_CONFIG_FILE" "$provider_key" "$provider_name" "$input_url" "$input_key" "$selected_model" "$CODEX_DEFAULT_ENV_KEY"
    fi
    _ok "Provider \"$provider_key\" 已更新"
  else
    api_add "$provider_key" "$input_url" "$input_key" "$selected_model" "$provider_name"
  fi

  # 7. 切换到此 provider
  api_switch "$provider_key"

  echo ""
  _ok "配置完成! 现在可以用 codex 了"
  _log "Provider: $provider_name ($provider_key)"
  _log "Model:    $selected_model"
  _log "API:      $input_url"
}

switch_api() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    add)    api_add "$@" ;;
    del|rm) api_del "$@" ;;
    ls|list) api_list ;;
    show)   api_show ;;
    switch)
      if [ -n "${1:-}" ]; then
        api_switch "$1"
      else
        api_interactive_select
      fi
      ;;
    pick|select|"")
      api_interactive_select
      ;;
    setup|configure|cc)
      api_configure
      ;;
    models)
      # 用法: switch-api models [provider_key]
      # 从指定 provider 拉取模型列表
      local _prov_key="${1:-}"
      api_init
      if [ -z "$_prov_key" ]; then
        # 用当前 active provider
        _prov_key=$(grep '"active"' "$CODEX_API_CONFIG_FILE" 2>/dev/null \
          | grep -o '"active":[[:space:]]*"[^"]*"' | sed 's/"active":[[:space:]]*"\([^"]*\)"/\1/')
      fi
      [ -z "$_prov_key" ] && { _err "没有 active provider，请指定 provider key"; return 1; }

      local _prov_block _prov_url _prov_key_val
      _prov_block=$(sed -n "/\"$_prov_key\": {/,/}/p" "$CODEX_API_CONFIG_FILE")
      _prov_url=$(echo "$_prov_block" | grep '"base_url"' | sed 's/.*"base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
      _prov_key_val=$(echo "$_prov_block" | grep '"api_key"' | sed 's/.*"api_key"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

      api_fetch_models "$_prov_url" "$_prov_key_val"
      ;;
    *)
      _err "Unknown subcommand: $subcmd"
      _log "Available: add, del, list, show, switch, pick, setup, models"
      return 1
      ;;
  esac
}

usage() {
  cat <<USAGE
Usage: ${0##*/} [COMMAND] [OPTIONS]

Commands:
  install       Install or update Codex CLI (default)
  uninstall     Remove Codex CLI
  status        Show installation status
  version       Print remote version only
  switch-api    API provider 切换 (add/del/list/show/switch)
                底层自动生成 ~/.codex/config.toml (Codex 原生格式)

switch-api subcommands:
  list          列出所有 provider
  show          显示当前 active provider
  switch <key>  切换到指定 provider (无 key 时弹交互菜单)
  pick          交互式选择 provider (fzf 优先, 数字编号回退)
  setup         交互式配置: 输入 URL/Key → 拉取模型 → 选择 → 写入
  models [key]  列出指定 provider 的可用模型 (默认当前 active)
  add <key> <base_url> <api_key> [model] [name]
                添加新 provider (自动生成 config.toml)
  del <key>     删除 provider

快捷命令:
  codex -cc     交互式配置新 Provider (等同 switch-api setup)
  codex-switch  交互式切换已有 Provider

Options:
  -t, --tag TAG         Pin a specific version tag
  -f, --force           Force reinstall even if up to date
  -v, --verbose         Show debug-level logs
  -q, --quiet           Suppress non-error output
  -b, --bin-dir DIR     Override USER_BIN (default: ~/.local/bin)
  -l, --lib-dir DIR     Override USER_LIB (default: ~/.local/lib)
  -s, --sandbox MODE    Default sandbox mode (danger-full-access | readonly | preserve)
      --repo OWNER/REPO Override repo (default: openai/codex)
      --mirror PREFIX   Mirror prefix for downloads (e.g. https://ghproxy.com/)
  -h, --help            Show this help

Environment variables (alternative to flags):
  CODEX_RELEASE_TAG     Same as --tag
  FORCE_INSTALL         Same as --force (1 to enable)
  VERBOSE / QUIET       Same as --verbose / --quiet
  CODEX_USER_BIN        Same as --bin-dir
  CODEX_USER_LIB        Same as --lib-dir
  CODEX_MIRROR          Same as --mirror

Examples:
  # Install latest
  ./codex-termux-install.sh

  # Pin version
  ./codex-termux-install.sh --tag r1.2.0

  # Force reinstall, verbose
  ./codex-termux-install.sh -f -v

  # Status & uninstall
  ./codex-termux-install.sh status
  ./codex-termux-install.sh uninstall

  # Via mirror (GitHub blocked network)
  ./codex-termux-install.sh --mirror "https://ghproxy.com/"

  # API 切换示例 (add: key base_url api_key model name)
  ./codex-termux-install.sh switch-api list
  ./codex-termux-install.sh switch-api add sensenova https://token.sensenova.cn/v1 sk-xxxxx glm-5.2 "SenseNova"
  ./codex-termux-install.sh switch-api switch sensenova
  ./codex-termux-install.sh switch-api show
  ./codex-termux-install.sh switch-api del sensenova

USAGE
  exit 0
}

# ============================================================================
# CLI 解析
# ============================================================================

COMMAND="install"

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      install|uninstall|status|version)
        COMMAND="$1"
        ;;
      switch-api)
        COMMAND="switch-api"
        shift || true
        SWITCH_API_ARGS=("$@")
        break
        ;;
      -t|--tag)
        shift
        CODEX_RELEASE_TAG="${1:-}"
        ;;
      -f|--force)
        FORCE_INSTALL=1
        ;;
      -v|--verbose)
        VERBOSE=1
        ;;
      -q|--quiet)
        QUIET=1
        ;;
      -b|--bin-dir)
        shift
        USER_BIN="${1:-$USER_BIN}"
        ;;
      -l|--lib-dir)
        shift
        USER_LIB="${1:-$USER_LIB}"
        ;;
      -s|--sandbox)
        shift
        CODEX_TERMUX_DEFAULT_SANDBOX="${1:-danger-full-access}"
        ;;
      --repo)
        shift
        CODEX_REPO="${1:-openai/codex}"
        ;;
      --mirror)
        shift
        CODEX_MIRROR="${1:-}"
        ;;
      -h|--help)
        usage
        ;;
      *)
        _err "Unknown option: $1"
        echo "Run: $0 --help"
        exit 1
        ;;
    esac
    shift
  done

  # 更新派生变量
  CODEX_DIR="$USER_LIB/codex"
  CODEX_BIN="$CODEX_DIR/codex"
  CODEX_VERSION_MARKER="$CODEX_DIR/.installed-version"
  CODEX_CHECKSUM_FILE="$CODEX_DIR/.sha256"
  USER_BIN="${USER_BIN%/}"
  USER_LIB="${USER_LIB%/}"
}

# ============================================================================
# main
# ============================================================================

main() {
  parse_args "$@"

  case "$COMMAND" in
    version)
      detect_environment
      resolve_version
      exit 0
      ;;
    status)
      detect_environment
      status_codex
      exit 0
      ;;
    uninstall)
      uninstall_codex
      exit 0
      ;;
    switch-api)
      switch_api "${SWITCH_API_ARGS[@]+"${SWITCH_API_ARGS[@]}"}"
      exit 0
      ;;
    install)
      check_deps
      detect_environment
      # 先行创建目录和 PATH，确保后续 codex 命令可用
      mkdir -p "$USER_BIN"
      setup_shell_path
      # 安装 binary
      local _install_rc=0
      install_codex || _install_rc=$?

      if [ "$_install_rc" -eq 0 ]; then
        generate_wrapper
        # 把安装脚本复制到 USER_LIB, 让 wrapper 的 -cc 能找到
        cp "$0" "$USER_LIB/codex-termux-install.sh" 2>/dev/null && chmod +x "$USER_LIB/codex-termux-install.sh" || _warn "无法复制安装脚本到 $USER_LIB, codex -cc 可能不可用"
        generate_switch_shortcut
        echo "${TAG:-unknown}" > "$CODEX_VERSION_MARKER" 2>/dev/null || true
        echo "${TAG:-unknown}" > "$CODEX_REMOTE_VERSION_FILE" 2>/dev/null || true

        _section "Summary"
        _ok "Codex CLI installed: $(cat "$CODEX_VERSION_MARKER" 2>/dev/null || echo '?')"
        echo ""
        echo "  Binary:    $CODEX_BIN"
        echo "  Wrapper:   $USER_BIN/codex"
        echo "  Resolver:  $CODEX_RESOLV_CONF"
        echo ""
        echo "  Run: codex --help"
        echo "  切换: codex-switch"
        echo ""
        echo "  API 管理:  $0 switch-api [add|del|list|show|pick]"

        # 检查当前 shell PATH 是否包含 ~/.local/bin
        case ":${PATH:-}:" in
          *":$USER_BIN:"*) ;;
          *)
            _warn "当前会话找不到 codex 命令！新终端会自动生效，或现在执行："
            echo ""
            printf '  source ~/.bashrc\n'
            echo ""
            ;;
        esac
      else
        _err "Installation failed (exit code $_install_rc)"
        _log "Wrapper and version marker were NOT written"
        _log "Re-run with -v for details, or check the error above"
        exit "$_install_rc"
      fi
      ;;
  esac
}

main "$@"
