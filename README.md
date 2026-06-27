# xray-setup

极简 VLESS Reality 一键部署脚本，单文件，无依赖。

## 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/newbietan/proxy-toolkit/main/xray-setup.sh) install
```

或下载后运行：

```bash
chmod +x xray-setup.sh
./xray-setup.sh install
```

## 命令

```bash
xray-setup.sh install     # 安装 Xray-core 并生成配置
xray-setup.sh uninstall   # 卸载 Xray-core
xray-setup.sh status      # 查看服务状态
xray-setup.sh show        # 显示节点信息和分享链接
xray-setup.sh restart     # 重启服务
xray-setup.sh update      # 更新 Xray-core
xray-setup.sh bbr         # 开启 BBR 拥塞控制
xray-setup.sh icmp        # 开启 ICMP (允许 ping)
```

## 安装完成后

运行 `install` 后会自动输出：

- 服务器地址、端口、UUID
- 公钥、Short ID
- VLESS 分享链接（可直接导入客户端）

## 客户端配置

### V2rayN / V2rayNG

1. 复制分享链接
2. 导入链接 → 更新订阅

### Clash Meta

```yaml
proxies:
  - name: "Xray-Reality"
    type: vless
    server: <服务器IP>
    port: 443
    uuid: <UUID>
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.microsoft.com
    reality-opts:
      public-key: <公钥>
      short-id: <Short ID>
    client-fingerprint: chrome
```

### Sing-box

```json
{
  "type": "vless",
  "tag": "xray-reality",
  "server": "<服务器IP>",
  "server_port": 443,
  "uuid": "<UUID>",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "www.microsoft.com",
    "reality": {
      "enabled": true,
      "public_key": "<公钥>",
      "short_id": "<Short ID>"
    }
  }
}
```

## 文件位置

| 文件 | 路径 |
|------|------|
| Xray 二进制 | `/usr/local/bin/xray` |
| 配置文件 | `/usr/local/etc/xray/config.json` |
| 安装信息 | `/usr/local/etc/xray/install-info.conf` |
| 日志 | `/var/log/xray/` |
| systemd 服务 | `/etc/systemd/system/xray.service` |

## 系统要求

- Linux (amd64 / arm64 / armv7 / s390x)
- root 权限
- 能访问 GitHub（下载 Xray-core）

## 兼容性

| 系统 | 包管理器 | Init 系统 | 状态 |
|------|----------|-----------|------|
| Ubuntu/Debian | apt | systemd | ✅ 完全支持 |
| CentOS/RHEL | yum/dnf | systemd | ✅ 完全支持 |
| Alpine | apk | OpenRC | ✅ 支持 |
| Arch Linux | pacman | systemd | ✅ 支持 |
| 无 systemd 的系统 | - | nohup | ✅ 兼容模式 |

## 自动处理

脚本会自动处理以下情况：

- **端口占用**: 自动检测并停止占用 443 端口的服务（nginx/apache 等）
- **Init 系统**: 自动检测 systemd/OpenRC，无 systemd 时使用 nohup 兼容模式
- **开机启动**: 自动配置开机启动（支持所有 init 系统）
- **BBR**: 自动开启 BBR 拥塞控制，提升网络性能
- **ICMP**: 自动开启 ICMP，允许 ping 测试

## 常见问题

### 下载失败（国内服务器）

使用代理或手动下载 Xray 二进制文件：

```bash
# 设置代理下载
export https_proxy=http://127.0.0.1:7890
./xray-setup.sh install

# 或手动下载后放到 /usr/local/bin/xray
```

### 防火墙放行

```bash
# Ubuntu/Debian
ufw allow 443/tcp

# CentOS/RHEL
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --reload

# Alpine (iptables)
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

### 查看日志

```bash
# systemd 系统
journalctl -u xray -f

# nohup 模式
tail -f /var/log/xray/xray.log
```

## License

MIT
