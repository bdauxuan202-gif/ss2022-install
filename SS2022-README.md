# Shadowsocks 2022 一键安装 / 管理脚本

基于 [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)，支持自定义参数、菜单管理、更新与卸载。

## 一键安装

```bash
wget -O ss2022-install.sh https://raw.githubusercontent.com/bdauxuan202-gif/ss2022-install/main/ss2022-install.sh && chmod +x ss2022-install.sh && sudo ./ss2022-install.sh
```

或直接安装（不进菜单）：

```bash
wget -O ss2022-install.sh https://raw.githubusercontent.com/bdauxuan202-gif/ss2022-install/main/ss2022-install.sh
chmod +x ss2022-install.sh
sudo ./ss2022-install.sh install
```

## 功能

| 功能 | 说明 |
|------|------|
| 安装/重装 | 交互或环境变量配置端口、加密、密钥、IPv6 |
| 自动最新版 | `SS_VERSION=latest` 从 GitHub 拉取最新 release |
| 下载镜像 | 主链接失败自动走 `ghfast.top` 加速 |
| 端口检测 | 安装前检查端口占用 |
| 密钥校验 | 校验 Base64 解码长度是否符合 SS2022 |
| systemd | 开机自启 + 失败重启 + 安全加固 |
| 防火墙 | firewalld / ufw / iptables 自动放行 |
| BBR 优化 | 写入 sysctl，尽量开启 BBR |
| 连接信息 | 输出 SS 链接；有 `qrencode` 时输出二维码 |
| 改配置 | 端口 / 加密 / 密钥 / IPv6 在线修改 |
| 更新内核 | 不丢配置，只更新二进制并重启 |
| 卸载 | 清理服务、二进制、配置 |

## 命令

```bash
sudo ./ss2022-install.sh              # 菜单
sudo ./ss2022-install.sh install      # 安装
sudo ./ss2022-install.sh update       # 更新
sudo ./ss2022-install.sh info         # 连接信息
sudo ./ss2022-install.sh config       # 改配置
sudo ./ss2022-install.sh restart      # 重启
sudo ./ss2022-install.sh status       # 状态
sudo ./ss2022-install.sh uninstall    # 卸载
./ss2022-install.sh help              # 帮助
```

## 非交互安装

```bash
SS_PORT=443 \
SS_METHOD=2022-blake3-aes-256-gcm \
SS_PASSWORD=auto \
SS_VERSION=latest \
ENABLE_IPV6=false \
sudo -E ./ss2022-install.sh install
```

| 变量 | 说明 | 默认 |
|------|------|------|
| `SS_PORT` | 端口 | 8388 |
| `SS_METHOD` | 加密 | 2022-blake3-aes-256-gcm |
| `SS_PASSWORD` | Base64 密钥，`auto` 自动生成 | 自动生成 |
| `SS_VERSION` | `latest` 或具体版本号 | latest |
| `ENABLE_IPV6` | 是否监听 IPv6 | false |
| `MIRROR_PREFIX` | 下载前缀加速，如 `https://ghfast.top/` | 空 |

## 修改默认参数

编辑脚本顶部：

```bash
DEFAULT_PORT=8388
DEFAULT_METHOD="2022-blake3-aes-256-gcm"
DEFAULT_PASSWORD=""
SS_VERSION="latest"
ENABLE_IPV6="false"
MIRROR_PREFIX=""
```

或改线上配置后重启：

```bash
sudo vim /etc/shadowsocks-rust/config.json
sudo systemctl restart shadowsocks-rust
```

客户端信息保存在：`/etc/shadowsocks-rust/client-info.txt`

## 加密方式

| method | 密钥解码长度 | 说明 |
|--------|--------------|------|
| `2022-blake3-aes-256-gcm` | 32 字节 | 推荐 |
| `2022-blake3-aes-128-gcm` | 16 字节 | 略快 |
| `2022-blake3-chacha20-poly1305` | 32 字节 | 无 AES 加速时适用 |

## 系统支持

- Debian / Ubuntu
- CentOS / RHEL / Rocky / Alma / Fedora / Amazon Linux
- Alpine（基础依赖）
- 架构: x86_64 / aarch64 / armv7

## 服务管理

```bash
systemctl start|stop|restart|status shadowsocks-rust
journalctl -u shadowsocks-rust -f
```

## 云安全组

脚本只能改本机防火墙。使用云服务器时，请在控制台安全组放行对应 **TCP + UDP** 端口。
