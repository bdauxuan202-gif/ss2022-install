# Shadowsocks 2022 一键安装脚本

## ⚠️ 安全提醒
**请立即撤销你在对话中暴露的 GitHub Token！** 前往 GitHub Settings → Developer settings → Personal access tokens 删除并重新生成。

## 快速使用

```bash
# 上传到服务器后
chmod +x ss2022-install.sh
sudo ./ss2022-install.sh
```

脚本会交互式询问 **端口、加密方式、密钥** 三个参数。

## 非交互式安装

通过环境变量跳过交互：

```bash
SS_PORT=12345 SS_METHOD=2022-blake3-aes-256-gcm SS_PASSWORD=auto sudo -E ./ss2022-install.sh
```

| 环境变量 | 说明 | 默认值 |
|---|---|---|
| `SS_PORT` | 监听端口 | 8388 |
| `SS_METHOD` | 加密方式 | 2022-blake3-aes-256-gcm |
| `SS_PASSWORD` | 密钥 (Base64)，`auto` = 自动生成 | 自动生成 |
| `SS_VERSION` | shadowsocks-rust 版本号 | 1.21.2 |

## 可修改参数

直接编辑脚本头部的默认值：

```bash
DEFAULT_PORT=8388
DEFAULT_METHOD="2022-blake3-aes-256-gcm"
DEFAULT_PASSWORD=""     # 留空=自动生成
SS_VERSION="1.21.2"
```

或修改运行中的配置：

```bash
sudo vim /etc/shadowsocks-rust/config.json
sudo systemctl restart shadowsocks-rust
```

## 支持的加密方式

| 方式 | 密钥长度 | 说明 |
|---|---|---|
| `2022-blake3-aes-256-gcm` | 32字节 | 推荐，安全性最高 |
| `2022-blake3-aes-128-gcm` | 16字节 | 性能稍好 |
| `2022-blake3-chacha20-poly1305` | 32字节 | 适合无 AES 硬件加速设备 |

## 服务管理

```bash
sudo systemctl start   shadowsocks-rust   # 启动
sudo systemctl stop    shadowsocks-rust   # 停止
sudo systemctl restart shadowsocks-rust   # 重启
sudo systemctl status  shadowsocks-rust   # 状态
journalctl -u shadowsocks-rust -f         # 实时日志
```

## 卸载

```bash
sudo ./ss2022-install.sh uninstall
```

## 系统支持

- Debian / Ubuntu
- CentOS / RHEL / Rocky / Alma / Fedora
- 架构: x86_64, aarch64, armv7
