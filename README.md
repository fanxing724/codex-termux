# Codex CLI Termux Installer

一键在 Termux / Android 上部署 OpenAI Codex CLI，自动修补环境问题，支持自定义 API。

## Quick Start

```bash
bash codex-termux.sh install
```

安装完成后，用你的换 API 脚本配置：
```bash
curl -s https://你的地址/setup-codex.sh | bash -s -- --url https://你的api地址 --key sk-你的key
```

或者直接设置环境变量：
```bash
export OPENAI_BASE_URL=https://你的api地址
export OPENAI_API_KEY=sk-你的key
codex
```

## Features

- **环境修补** — 自动修补 Termux DNS 问题（`/etc/resolv.conf` → FD 9）
- **沙箱兼容** — 自动添加 `--sandbox danger-full-access`（Android 无 bubblewrap）
- **SSL 配置** — 自动指向 Termux 证书路径
- **自动检测** — 已有二进制或压缩包跳过下载
- **多源下载** — GitHub 直连 + 镜像源自动切换
- **快速换 API** — 配合你自备的换 API 脚本使用

## Requirements

- Termux (Android aarch64)
- `curl`, `wget`, `python3`, `nodejs`, `binutils`

## Files

| Path | Description |
|------|-------------|
| `~/.local/lib/codex/codex` | Codex binary (DNS patched) |
| `~/.local/bin/codex` | Wrapper script |
| `~/.config/codex/resolv.conf` | DNS config |
| `~/.codex/config.toml` | Codex config (由换 API 脚本生成) |

## Acknowledgements

- [openai/codex](https://github.com/openai/codex) — Codex CLI
- [PeroSar/claude-codex-termux](https://github.com/PeroSar/claude-codex-termux) — 原始 Termux 适配方案

## License

MIT