# Codex CLI Termux Installer

> ⚠️ **注意：Codex 已更新配置格式 (v0.142.5+)**
>
> 新版 Codex 不再支持 `config.toml` 中的 `profile = "..."` 和 `[profiles.*]` 字段，
> 改用 `--profile <name>` 参数 + 独立 `{profile}.config.toml` 文件。
> 本项目原来自定义的 API Provider 注入方式已不完全兼容。
>
> 此仓库保留为存档参考，不再积极维护自定义 Provider 功能。

> 一键安装 OpenAI Codex CLI 到 Termux / Android，支持自定义 API Provider 和交互式模型选择。
>
> Personal project — 自用为主，欢迎 fork 和 issue。

## Features

- **一键安装** — 自动下载、校验、补丁、配置
- **`codex -cc`** — 交互式配置：输入 API URL + Key，自动拉取模型列表，fzf 选择
- **`codex-switch`** — 快速切换 Provider（fzf 下拉 / 数字编号回退）
- **DNS 补丁** — 解决 Termux 无 `/etc/resolv.conf` 的问题
- **版本缓存** — 自动对比本地/远程版本，无更新跳过下载
- **多 Provider 管理** — profiles.json 存 Key，自动生成 Codex 原生 config.toml
- **镜像加速** — `--mirror` 参数支持 GitHub 镜像
- **架构检测** — aarch64 / x86_64 自动适配

## Quick Start

### 安装

```bash
# 能直连 GitHub
bash codex-termux-install.sh install

# 需要镜像
bash codex-termux-install.sh --mirror "https://v4.gh-proxy.org/" install
```

### 配置 API

```bash
# 交互式配置（推荐）
codex -cc

# 或手动添加
bash codex-termux-install.sh switch-api add myapi https://api.example.com/v1 sk-xxx gpt-4o
```

### 切换 Provider

```bash
codex-switch        # 交互式切换
codex-switch -cc    # 配置新的
```

## How It Works

```
codex -cc / codex (普通参数)
    │
    ├─ Wrapper (~/.local/bin/codex)
    │     ├── 读取 ~/.codex/profiles.json → 注入 API Key
    │     ├── FD 9 → resolv.conf (DNS)
    │     └── exec → ~/.local/lib/codex/codex (二进制)
    │                              ↑
    │                    ~/.codex/config.toml (Codex 原生配置)
    │
    └─ codex-switch → 交互式 Provider 切换
```

**核心原理：** Termux 没有 `/etc/resolv.conf`，脚本通过二进制补丁将硬编码路径替换为 `/proc/self/fd/9`，启动时通过文件描述符传入 DNS 配置。Codex 不读标准环境变量，所以 wrapper 自动从 profiles.json 读取 Key 并生成原生 config.toml。

详细原理和完整文档见 [GUIDE.md](GUIDE.md)。

## Command Reference

```bash
# 快捷命令
codex -cc                    # 交互式配置新 Provider
codex-switch                 # 交互式切换 Provider

# 安装管理
codex-termux-install.sh install          # 安装
codex-termux-install.sh -f install       # 强制重装
codex-termux-install.sh --tag TAG install # 指定版本
codex-termux-install.sh --mirror URL install # 镜像加速
codex-termux-install.sh uninstall        # 卸载
codex-termux-install.sh status           # 状态

# Provider 管理
codex-termux-install.sh switch-api pick    # 交互式选择
codex-termux-install.sh switch-api setup   # 交互式配置 (= codex -cc)
codex-termux-install.sh switch-api list    # 列表
codex-termux-install.sh switch-api show    # 详情
codex-termux-install.sh switch-api models  # 查看模型
codex-termux-install.sh switch-api add <key> <url> <api_key> [model] [name]
codex-termux-install.sh switch-api del <key>
```

## Requirements

- Termux (Android) 或普通 Linux
- `curl`, `tar`, `grep`, `sed`, `sha256sum`（必装）
- `python3`（推荐，JSON 解析和 config.toml 生成）
- `fzf`（可选，提升交互体验：`pkg install fzf`）

## Files

| Path | Description |
|------|-------------|
| `~/.local/lib/codex/codex` | Codex binary (DNS patched) |
| `~/.local/bin/codex` | Wrapper script |
| `~/.local/bin/codex-switch` | Provider switcher shortcut |
| `~/.codex/profiles.json` | API provider config (keys) |
| `~/.codex/config.toml` | Codex native config (auto-generated) |
| `~/.config/codex/resolv.conf` | DNS config |

## Acknowledgements

- [openai/codex](https://github.com/openai/codex) — Codex CLI
- [PeroSar/claude-codex-termux](https://github.com/PeroSar/claude-codex-termux) — 原始 Termux 适配方案
- [CC Switch](https://github.com/topics/cc-switch) — API Provider 切换思路参考

## License

MIT — 自用项目，随便改。
