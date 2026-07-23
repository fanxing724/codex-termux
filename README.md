# Codex CLI Termux Installer

> 🚀 一键在 Termux / Android 上部署 OpenAI Codex CLI
>
> 自动修补 Termux 环境差异，让你在手机上跑 Codex

## 快速开始

```bash
# 1. 安装
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fanxing724/codex-termux/main/codex-termux.sh)" install

# 2. 配置 API（交互式）
bash codex-switch-api.sh

# 或一键配置
bash codex-switch-api.sh -u https://你的api地址 -k sk-你的key

# 3. 启动
source ~/.bashrc
codex
```

## 解决了什么问题

在 Termux 上跑 Codex 会遇到几个问题，这个脚本自动处理：

| 问题 | 原因 | 解决方式 |
|------|------|----------|
| ❌ DNS 解析失败 | Android 没有 `/etc/resolv.conf` | 二进制修补 + FD 9 传入 DNS |
| ❌ 沙箱不可用 | Android 没有 bubblewrap | 自动加 `--sandbox danger-full-access` |
| ❌ SSL 证书路径 | Termux 证书位置不同 | 自动设置 `SSL_CERT_FILE` |
| ❌ TMPDIR 不可写 | Android 的 `/tmp` 不能写 | 自动指向 `$PREFIX/tmp` |
| ❌ GitHub 下载慢 | 国内网络问题 | 内置镜像源自动切换 |

## 安装说明

### 前置要求

- Termux（Android aarch64 / ARM64）
- 已安装基础包（脚本会自动补装缺失的依赖）

### 安装方式

```bash
# 方式一：直接运行（推荐）
bash codex-termux.sh install

# 方式二：强制重装
bash codex-termux.sh install -f

# 方式三：指定版本
CODEX_RELEASE_TAG=rust-v0.145.0 bash codex-termux.sh install

# 卸载
bash codex-termux.sh uninstall
```

### 安装流程

```
bash codex-termux.sh install
    │
    ├── 检查/安装依赖 (curl, wget, nodejs, python, binutils...)
    ├── 生成 DNS 解析文件 (~/.config/codex/resolv.conf)
    ├── 检测已有二进制 → 跳过下载 或 下载最新版
    │     ├── GitHub 直连
    │     └── ghproxy 镜像 (备用)
    ├── 修补二进制 DNS 路径
    ├── 生成 wrapper 脚本 (~/.local/bin/codex)
    └── 配置 PATH (~/.bashrc / ~/.zshrc)
```

## 使用方式

### 配置 API

安装完成后，用 `codex-switch-api.sh` 配置 API：

```bash
# 交互式配置（推荐）
bash codex-switch-api.sh

# 一键配置
bash codex-switch-api.sh -u https://你的api地址 -k sk-你的key

# 只测试连接
bash codex-switch-api.sh -t -u https://你的api地址 -k sk-你的key

# 查看当前配置
bash codex-switch-api.sh -s
```

支持的 API 示例：

| 供应商 | 地址 |
|--------|------|
| DeepSeek | `https://api.deepseek.com/v1` |
| 硅基流动 | `https://api.siliconflow.cn/v1` |
| Kimi | `https://api.moonshot.cn/v1` |
| 自定义中转 | 你的中转站地址 |

### 手动设置环境变量

```bash
export OPENAI_BASE_URL="https://你的api地址/v1"
export OPENAI_API_KEY="sk-你的key"
codex
```

或者编辑配置文件：

```bash
nano ~/.codex/config.toml
```

配置示例：

```toml
openai_base_url = "https://你的api地址/v1"

[models]
default = "deepseek-chat"

[model_providers.custom]
name = "custom"
base_url = "https://你的api地址/v1"
wire_api = "responses"
env_key = "CODEX_API_KEY"
```

### 启动

```bash
codex
```

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `CODEX_TERMUX_DEFAULT_SANDBOX` | 沙箱模式 | `danger-full-access` |
| `CODEX_RELEASE_TAG` | 指定 Codex 版本 | 自动获取最新 |
| `FORCE_INSTALL_CC_CODEX` | 强制重装 | `0` |

## 文件结构

```
~/.local/
├── bin/codex              # Wrapper 脚本（入口）
└── lib/codex/codex        # Codex 二进制（已修补 DNS）

~/.codex/
└── config.toml            # Codex 配置（由 codex-switch-api.sh 生成）

~/.config/codex/
└── resolv.conf            # DNS 解析文件
```

## 原理说明

### DNS 修补

Codex 二进制硬编码了 `/etc/resolv.conf`，但 Android/Termux 没有这个文件。

脚本通过 `dd` 命令把二进制中的 `/etc/resolv.conf`（16 字节）替换为 `/proc/self/fd/9\0`（也是 16 字节，不破坏文件结构），然后 wrapper 通过 FD 9 传入 DNS 配置。

### Wrapper 流程

```
codex 命令
    │
    ├── 设置 SSL_CERT_FILE → Termux 证书路径
    ├── 设置 TMPDIR → $PREFIX/tmp
    ├── 检查是否需要加 --sandbox
    ├── 打开 FD 9 → resolv.conf
    └── exec → codex 二进制
```

## 更新

```bash
# 重新运行安装脚本（自动检测版本）
bash codex-termux.sh install
```

## 卸载

```bash
bash codex-termux.sh uninstall
```

## 常见问题

**Q: 下载失败怎么办？**
```bash
# 手动下载
wget https://github.com/openai/codex/releases/download/rust-v0.145.0/codex-aarch64-unknown-linux-musl.tar.gz
tar -xzf codex-aarch64-unknown-linux-musl.tar.gz
mkdir -p ~/.local/lib/codex
mv codex-aarch64-unknown-linux-musl ~/.local/lib/codex/codex
chmod +x ~/.local/lib/codex/codex
# 再运行脚本（会跳过下载）
bash codex-termux.sh install
```

**Q: `codex: command not found`**
```bash
export PATH="$HOME/.local/bin:$PATH"
# 或重新打开终端
```

**Q: 怎么换 API？**
```bash
bash codex-switch-api.sh -u 新地址 -k 新key
```

## Acknowledgements

- [openai/codex](https://github.com/openai/codex) — Codex CLI
- [PeroSar/claude-codex-termux](https://github.com/PeroSar/claude-codex-termux) — 原始 Termux 适配方案

## License

MIT