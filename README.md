# Codex Termux 工具箱

> 🚀 在 Termux / Android 上运行 OpenAI Codex CLI
>
> 环境修补 + 一键换 API，手机也能写代码

## 快速开始

```bash
# 1. 安装 Codex（环境修补 + 下载二进制）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fanxing724/codex-termux/main/codex-termux.sh)" install

# 2. 配置 API
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fanxing724/codex-termux/main/codex-switch-api.sh)" -u https://你的api地址 -k sk-你的key

# 3. 启动
source ~/.bashrc
codex
```

## 脚本说明

| 脚本 | 功能 |
|------|------|
| `codex-termux.sh` | 环境修补 + 下载 Codex 二进制 |
| `codex-switch-api.sh` | 一键换 API（配置 + 环境变量） |

### codex-termux.sh — 环境修补

在 Termux 上跑 Codex 会遇到的问题，自动处理：

| 问题 | 解决方式 |
|------|----------|
| DNS 解析失败 | 二进制修补，FD 9 传入 DNS |
| 沙箱不可用 | 自动加 `--sandbox danger-full-access` |
| SSL 证书路径 | 自动设置 `SSL_CERT_FILE` |
| TMPDIR 不可写 | 自动指向 `$PREFIX/tmp` |
| GitHub 下载慢 | 内置镜像源切换 |

```bash
# 安装
bash codex-termux.sh install

# 卸载
bash codex-termux.sh uninstall
```

### codex-switch-api.sh — 一键换 API

```bash
# 交互式
bash codex-switch-api.sh

# 一键配置
bash codex-switch-api.sh -u https://你的地址 -k sk-你的key

# 只测试连接
bash codex-switch-api.sh -t -u https://你的地址 -k sk-你的key

# 查看当前配置
bash codex-switch-api.sh -s
```

## 文件结构

```
~/.local/
├── bin/codex              # Wrapper 入口
└── lib/codex/codex        # Codex 二进制（已修补 DNS）

~/.codex/
└── config.toml            # 配置（由 codex-switch-api.sh 生成）

~/.config/codex/
└── resolv.conf            # DNS 解析文件
```

## 原理

Codex 二进制硬编码了 `/etc/resolv.conf`，但 Termux 没有。脚本用 `dd` 把二进制中的路径替换为 `/proc/self/fd/9\0`，通过 wrapper 的 FD 9 传入 Android 的 DNS 配置。

## License

MIT