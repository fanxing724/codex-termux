# Codex CLI Termux 安装 & 配置指南

> ⚠️ **注意：Codex v0.142.5+ 已变更配置格式**
> 本指南基于旧版编写，新版不再支持 `config.toml` 中的 `profile = "..."` 和 `[profiles.*]` 字段，
> 改用 `--profile` 参数 + 独立 `{profile}.config.toml` 文件。自定义 API Provider 方案已受影响。

> 编写: 2026-07-02 | 环境: Termux (aarch64) | Codex: rust-v0.142.5

---

## 原理

### 为什么不能直接装？

Codex CLI 官方只提供 Linux x86_64 / aarch64 的 musl 静态编译二进制，Termux (Android) 上有三个问题：

| 问题 | 原因 | 解决 |
|------|------|------|
| **DNS 解析** | Termux 没有 `/etc/resolv.conf`，二进制硬编码了该路径 | 二进制补丁: 将 `/etc/resolv.conf` 替换为 `/proc/self/fd/9`，启动时通过 FD 9 传入 DNS 配置 |
| **API 配置** | Codex 不读 `OPENAI_*` 环境变量，只用原生 `~/.codex/config.toml`（TOML 格式） | Wrapper 从 `profiles.json` 读取 API key，注入到 `CODEX_ACTIVE_API_KEY` 环境变量；脚本自动从 `profiles.json` 生成 Codex 原生 `config.toml` |
| **网络封锁** | GitHub 在国内部分地区无法直连 | 内置 `--mirror` 参数，支持任意镜像前缀 |

### 架构

```
Termux 终端
    │
    ├─ codex -cc              ← Wrapper 拦截 -cc/--configure → 调安装脚本 setup
    ├─ codex (普通参数)        ← Wrapper
    │     ├── 读取 ~/.codex/profiles.json → 获取 API key
    │     ├── 注入 CODEX_ACTIVE_API_KEY 环境变量
    │     ├── 通过 FD 9 传入 resolv.conf（DNS）
    │     └── exec → ~/.local/lib/codex/codex    ← 真正的二进制
    │                                        ↑
    │                                  读取 ~/.codex/config.toml
    │
    ├─ codex-switch           ← 独立快捷命令，交互式切换 Provider
    │     └── 优先调安装脚本 switch-api pick，找不到则独立运行
    │
    └─ codex-termux-install.sh switch-api ...   ← 完整管理入口
```

**Wrapper 拦截链：** 当你运行 `codex -cc` 时，wrapper 脚本在 exec 二进制之前检测到 `-cc` 参数，转而调用安装脚本的 `switch-api setup` 交互式配置流程，配置完成后正常执行 `codex`。

### 为什么是两层配置？

`~/.codex/` 下有两个文件，各司其职：

| 文件 | 格式 | 谁来读 | 用途 |
|------|------|--------|------|
| `profiles.json` | JSON | **只有 wrapper 读** | 存 API key（私密数据），脚本管理 |
| `config.toml` | TOML | **Codex 原生读取** | 定义 provider 的 base_url、model、env_key |

**原理：** Codex 根本不读 `OPENAI_BASE_URL` / `OPENAI_API_KEY` / `OPENAI_MODEL`，它有自己的配置系统——`~/.codex/config.toml`。每次 `switch-api` 操作后，脚本自动从 `profiles.json` 生成 `config.toml`。Wrapper 只负责把 API key 注入到 `CODEX_ACTIVE_API_KEY` 环境变量（`config.toml` 中 `env_key = "CODEX_ACTIVE_API_KEY"` 指定了要读这个变量）。

### 关键文件

| 路径 | 说明 |
|------|------|
| `~/.local/lib/codex/codex` | Codex 二进制（已打 DNS 补丁） |
| `~/.local/lib/codex-termux-install.sh` | 安装脚本副本（wrapper 的 -cc 调用它） |
| `~/.local/bin/codex` | Wrapper 脚本 |
| `~/.local/bin/codex-switch` | 独立快捷命令（交互式切换 Provider） |
| `~/.codex/profiles.json` | API provider 配置（存储 API key，仅 wrapper 读取） |
| `~/.codex/config.toml` | Codex 原生配置（由脚本自动从 profiles.json 生成） |
| `~/.config/codex/resolv.conf` | DNS 配置（FD 9 传入） |
| `~/.local/lib/codex/.installed-version` | 已安装版本标记 |
| `~/.local/lib/codex/.remote-version` | 远程版本缓存（避免重复查 GitHub API） |

---

## 安装教程

### 1. 下载脚本

将 `codex-termux-install.sh` 放到 Termux 的 `~` 目录下。

### 2. 安装

**能直连 GitHub：**

```bash
bash codex-termux-install.sh install
```

**需要镜像加速：**

```bash
bash codex-termux-install.sh --mirror "https://v4.gh-proxy.org/" install
```

安装过程：

```
━━━━ Shell PATH ━━━━
✔ PATH added to ~/.bashrc
✔ Added ~/.local/bin to current session PATH

━━━━ Install Codex CLI ━━━━
━━━━ Resolve Version ━━━━
✔ Target version: rust-v0.142.5
→ Downloading codex-aarch64-unknown-linux-musl.tar.gz...
✔ Downloaded 96907692 bytes
→ Extracting...
✔ SHA256: 8e64bdf19fa05269c83b5a89adb2e77a8d37f705dd1ea1e9e4177782680451fd
✔ Installed: ~/.local/lib/codex/codex
→ Patching /etc/resolv.conf reference → /proc/self/fd/9...
✔ Patched 2 occurrence(s)
✔ Codex binary ready (rust-v0.142.5)
✔ Wrapper installed: ~/.local/bin/codex
✔ Shortcut installed: ~/.local/bin/codex-switch (run: codex-switch)

━━━━ Summary ━━━━
✔ Codex CLI installed: rust-v0.142.5

  Binary:    ~/.local/lib/codex/codex
  Wrapper:   ~/.local/bin/codex
  Resolver:  ~/.config/codex/resolv.conf

  Run: codex --help
  切换: codex-switch

  API 管理:  codex-termux-install.sh switch-api [add|del|list|show|pick]
```

### 3. 验证

```bash
codex
```

如果弹出交互式界面，说明安装成功。

---

## 配置 API Provider

### 方式一：`codex -cc` 交互式配置（推荐）

最简单的方式，一条命令搞定：

```bash
codex -cc
```

交互流程：

```
━━━━ 配置新 Provider ━━━━
API Base URL (如 https://api.openai.com/v1): https://token.sensenova.cn/v1
API Key: sk-QpBRxY4fpxmKMSBgFBvaDwJCjvPX22xM
→ 正在从 https://token.sensenova.cn/v1/models 拉取模型列表...
✔ 获取到 42 个模型

  1) glm-4-flash
  2) glm-4-plus
  3) glm-5.2
  ...

输入编号 [1-42] (或直接输入模型名): 3
✔ 选择模型: glm-5.2

Provider 标识 [默认: sensenova]: ↵
Provider 显示名 [默认: sensenova]: 智谱清言
✔ Active provider: sensenova

✔ 配置完成! 现在可以用 codex 了
  Provider: 智谱清言 (sensenova)
  Model:    glm-5.2
  API:      https://token.sensenova.cn/v1
```

**原理：**
1. Wrapper 拦截 `-cc`，调用安装脚本的 `switch-api setup`
2. 输入 URL 和 Key 后，自动请求 `/v1/models` 拉取该 Provider 支持的所有模型
3. fzf 有就用 fzf 下拉选择，没有就数字编号
4. 自动写入 `profiles.json` + 生成 `config.toml`，一键切换

也可以用 `codex --configure` 或 `codex-switch -cc`，效果一样。

### 方式二：`codex-switch` 交互式切换

已有多个 Provider 时，用 `codex-switch` 快速切换：

```bash
codex-switch
```

fzf 模式：

```
━━━━ 选择 API Provider (fzf) ━━━━
> sensenova  glm-5.2  https://token.sensenova.cn/v1 [active]
  openai     gpt-4o   https://api.openai.com/v1
  deepseek   deepseek-chat  https://api.deepseek.com/v1
```

没 fzf 时数字编号：

```
━━━━ 选择 API Provider ━━━━
  1) sensenova           glm-5.2         https://token.sensenova.cn/v1 ★ active
  2) openai              gpt-4o          https://api.openai.com/v1
  3) deepseek            deepseek-chat   https://api.deepseek.com/v1

请输入编号 [1-3]:
```

### 方式三：命令行手动添加

```bash
bash codex-termux-install.sh switch-api add <名字> <base_url> <api_key> <model>
```

**示例：**

```bash
bash codex-termux-install.sh switch-api add sensenova \
  https://token.sensenova.cn/v1 \
  sk-QpBRxY4fpxmKMSBgFBvaDwJCjvPX22xM \
  glm-5.2
```

### 查看当前 Provider 的模型列表

```bash
# 当前 active provider
bash codex-termux-install.sh switch-api models

# 指定 provider
bash codex-termux-install.sh switch-api models sensenova
```

### 其他管理命令

```bash
# 列出所有 provider
codex-termux-install.sh switch-api list

# 切换（指定名字）
codex-termux-install.sh switch-api switch sensenova

# 查看当前配置详情
codex-termux-install.sh switch-api show

# 删除 provider
codex-termux-install.sh switch-api del sensenova
```

---

## 版本管理

### 缓存机制（避免重复下载）

脚本内置远程版本缓存：

```
首次安装 → 查 GitHub API → 存 .remote-version → 安装 → 存 .installed-version
第二次   → 比较 .installed-version == .remote-version → 跳过下载 ✓
```

只有 GitHub 发布了新版本，或手动指定 `-f` 才会重新下载。

### 强制重装

```bash
bash codex-termux-install.sh -f install
```

### 指定版本

```bash
bash codex-termux-install.sh --tag rust-v0.140.0 install
```

---

## 卸载

```bash
# 清理 binary + wrapper + 版本标记
bash codex-termux-install.sh uninstall

# 连带 API 配置一起清
bash codex-termux-install.sh uninstall && rm -rf ~/.codex
```

---

## 常见问题

### Q: `codex` 提示 No command found

PATH 没生效。要么新开一个 Termux 会话，要么：
```bash
source ~/.bashrc
```

### Q: 下载失败 / SSL 错误

GitHub 被墙，加镜像：
```bash
bash codex-termux-install.sh --mirror "https://v4.gh-proxy.org/" install
```

或设环境变量（一劳永逸）：
```bash
export CODEX_MIRROR="https://v4.gh-proxy.org/"
bash codex-termux-install.sh install
```

### Q: 使用第三方 API 失败

检查 `config.toml` 是否正确生成：
```bash
cat ~/.codex/config.toml
```

正确结构：
```toml
# Auto-generated by codex-termux-install.sh
profile = "sensenova"

[model_providers.sensenova]
name = "sensenova"
base_url = "https://token.sensenova.cn/v1"
env_key = "CODEX_ACTIVE_API_KEY"
wire_api = "responses"
requires_openai_auth = false

[profiles.sensenova]
model = "glm-5.2"
model_provider = "sensenova"
```

同时检查 `CODEX_ACTIVE_API_KEY` 环境变量是否已设置：
```bash
echo "API Key: ${CODEX_ACTIVE_API_KEY:0:8}..."
```

如果 `config.toml` 不存在，重新运行：
```bash
bash codex-termux-install.sh switch-api show
```

### Q: 旧版 `profiles.json` 不兼容

脚本会自动升级。如果 `profiles.json` 缺少 `env_key` 字段，运行一次 `switch-api show` 就会自动补全。你也可以手动添加：
```json
"env_key": "CODEX_ACTIVE_API_KEY"
```

### Q: 想直连不用 wrapper

```bash
CODEX_ACTIVE_API_KEY="sk-xxx" ~/.local/lib/codex/codex --help
```
但这样不会自动注入 API key 和 DNS。推荐始终用 wrapper。

### Q: `codex -cc` 拉取模型列表失败

可能原因：
- API 地址不支持 `/v1/models` 接口（少数第三方中转站不实现）
- API Key 无权限查询模型列表
- 网络超时（默认 15 秒）

解决：跳过自动拉取，手动指定模型名。在交互流程中，当 fzf/编号选择失败时会提示手动输入模型名。

### Q: 想装 fzf 获得更好的交互体验

```bash
pkg install fzf
```

装完后 `codex -cc` 和 `codex-switch` 都会自动用 fzf 下拉菜单，体验好很多。没装也不影响使用，会自动回退到数字编号。

---

## 完整命令参考

```bash
# ═══════ 快捷命令 ═══════
codex -cc                    # 交互式配置新 Provider (输入URL/Key→拉模型→选择)
codex --configure            # 同上
codex-switch                 # 交互式切换已有 Provider (fzf/数字编号)
codex-switch -cc             # 同 codex -cc

# ═══════ 安装管理 ═══════
codex-termux-install.sh install                     # 安装最新版
codex-termux-install.sh --mirror "URL" install      # 镜像加速安装
codex-termux-install.sh --tag rust-v0.140.0 install # 指定版本
codex-termux-install.sh -f install                  # 强制重装
codex-termux-install.sh uninstall                   # 卸载
codex-termux-install.sh status                      # 查看状态
codex-termux-install.sh version                     # 查看远程版本

# ═══════ API Provider 管理 ═══════
codex-termux-install.sh switch-api                  # 交互式选择 (同 pick)
codex-termux-install.sh switch-api pick             # 交互式选择 Provider
codex-termux-install.sh switch-api setup            # 交互式配置新 Provider (同 codex -cc)
codex-termux-install.sh switch-api list             # 列出所有 Provider
codex-termux-install.sh switch-api show             # 显示当前 active Provider
codex-termux-install.sh switch-api switch <key>     # 切换到指定 Provider
codex-termux-install.sh switch-api models           # 列出当前 Provider 的模型
codex-termux-install.sh switch-api models <key>     # 列出指定 Provider 的模型
codex-termux-install.sh switch-api add <key> <url> <api_key> [model] [name]  # 手动添加
codex-termux-install.sh switch-api del <key>        # 删除 Provider

# ═══════ 选项 ═══════
-v / --verbose               # 详细日志
-q / --quiet                 # 静默模式
-b / --bin-dir DIR           # 自定义 bin 目录
-l / --lib-dir DIR           # 自定义 lib 目录
-s / --sandbox MODE          # 默认沙箱模式
-h / --help                  # 帮助
```