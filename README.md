# xray-setup

极简 VLESS 一键部署脚本，支持直连和 CDN 两种模式，单文件，无依赖。

## 部署模式

| 模式 | 协议 | 特点 | 适用场景 |
|------|------|------|----------|
| **直连模式** | VLESS + Reality | 速度快、延迟低、伪装强 | IP 稳定、追求性能 |
| **CDN 模式** | VLESS + WebSocket + Cloudflare | 隐藏 IP、抗封锁 | IP 易被封、需要稳定 |
| **双模式** | 同时部署直连 + CDN | 两种方式都支持 | 推荐：主用直连，CDN 备用 |

## 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/newbietan/proxy-toolkit/main/xray-setup.sh) install
```

或下载后运行：

```bash
chmod +x xray-setup.sh
./xray-setup.sh install
```

安装时会提示选择部署模式，CDN 模式需要提前准备：
1. 拥有一个域名
2. 域名 NS 已切换到 Cloudflare
3. 在 Cloudflare 添加 A 记录指向服务器 IP

## 命令

```bash
xray-setup.sh install     # 安装 Xray-core 并生成配置（支持选择模式）
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
- 公钥、Short ID（直连模式）
- 域名、路径、证书位置（CDN 模式）
- VLESS 分享链接（可直接导入客户端）

### CDN 模式额外配置

#### 1. 申请 Cloudflare Origin 证书

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. 选择你的域名
3. 进入 **SSL/TLS** → **源服务器**
4. 点击 **创建证书**
5. 保持默认设置（RSA 2048，有效期 15 年）
6. 复制 **证书** 和 **私钥** 内容（脚本会提示粘贴）

#### 2. 运行安装脚本

选择 CDN 模式或双模式后，脚本会提示粘贴证书和私钥内容。输入完成后按 `Ctrl+D` 结束。

#### 3. Cloudflare 配置

安装完成后，在 Cloudflare 控制面板进行以下配置：

1. **添加 A 记录**：指向服务器 IP，开启橙色云朵（代理）
2. **SSL/TLS 设置**：选择 "Full"（不要选 "Full (Strict)"）
3. **回源端口**（双模式）：设置为 8080

## 客户端配置

### V2rayN / V2rayNG

1. 复制分享链接
2. 导入链接 → 更新订阅

### Clash Meta

#### 直连模式 (Reality)

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

#### CDN 模式 (WebSocket)

```yaml
proxies:
  - name: "Xray-CDN"
    type: vless
    server: <你的域名>
    port: 443
    uuid: <UUID>
    network: ws
    tls: true
    udp: true
    servername: <你的域名>
    ws-opts:
      path: /vless
      headers:
        Host: <你的域名>
    client-fingerprint: chrome
```

### Sing-box

#### 直连模式 (Reality)

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

#### CDN 模式 (WebSocket)

```json
{
  "type": "vless",
  "tag": "xray-cdn",
  "server": "<你的域名>",
  "server_port": 443,
  "uuid": "<UUID>",
  "tls": {
    "enabled": true,
    "server_name": "<你的域名>"
  },
  "transport": {
    "type": "ws",
    "path": "/vless",
    "headers": {
      "Host": "<你的域名>"
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
- **防火墙**: 自动放行 22 (SSH) 和 443 (Xray) 端口（支持 ufw/firewalld/iptables）
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
