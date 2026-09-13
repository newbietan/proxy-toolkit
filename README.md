# proxy-toolkit

极简代理一键部署脚本，单文件、无依赖。支持主流的 **VLESS + Reality (TCP)**、**Hysteria 2 (UDP 弱网加速/端口跳跃)** 以及 **VLESS + XHTTP (CDN 隐藏 IP)** 三大核心模式。

## 部署模式

| 模式 | 协议 | 传输层 | 特点 | 适用场景 |
| --- | --- | --- | --- | --- |
| **直连模式** | VLESS + Reality | TCP | 速度快、延迟低、智能环境感知自动匹配最优大厂/同机房 TLS 伪装域名，默认监听 443 (可自定义)，无需域名 | IP 稳定、追求轻量性能 |
| **极速模式** | Hysteria 2 | UDP (QUIC) | 暴力抗丢包（自研 Brutal 拥塞控制），支持端口跳跃 (Port Hopping)，内置自签证书 | 跨洋弱网严重、晚高峰丢包、防端口封禁/QoS |
| **CDN 模式** | VLESS + XHTTP + Cloudflare | HTTP/TLS | 隐藏源站 IP、穿透 WAF，IP 被墙依然可用，需自备域名接入 Cloudflare | IP 易被墙、需要长期稳定备用 |

## 快速使用

```bash
# 一键安装
bash <(curl -fsSL https://raw.githubusercontent.com/newbietan/proxy-toolkit/main/xray-setup.sh) install
```

或下载后运行（直接执行即可唤出交互式管理控制台）：

```bash
chmod +x xray-setup.sh
./xray-setup.sh
```

**Alpine Linux 用户需先安装 bash：**

```bash
apk add bash
bash <(curl -fsSL https://raw.githubusercontent.com/newbietan/proxy-toolkit/main/xray-setup.sh) install
```

安装时会提示选择部署模式：

- **直连模式 (Reality)**: 提示输入监听端口（默认推荐 `443`，可自定义），自动根据服务器网络画像（国家/地区、机房 ASN、握手延迟、TLS 1.3 与 ALPN h2 兼容性）智能探测并匹配最优伪装域名，一键完成配置。
- **极速模式 (Hysteria 2)**: 提示输入监听端口（默认推荐 `443`，可自定义）、是否开启端口跳跃（默认推荐关闭 `N` 以获得最佳长连接与视频缓冲稳定性；仅在特定运营商对单端口严重限速时按需开启 `20000-50000`）、认证密码（回车随机生成）及伪装 SNI（默认 `www.bing.com`），内置 EC 自签证书。
- **CDN 模式**: 需要提前准备域名并接入 Cloudflare，添加 A 记录指向服务器并申请 Cloudflare Origin 证书。

## 卸载

```bash
./xray-setup.sh uninstall
```

脚本会自动停止服务、清理服务文件、删除配置与二进制，并自动清理 iptables 端口跳跃转发规则。

## 命令

```bash
./xray-setup.sh             # 快捷管理控制台 (查看状态/启停/管理)
./xray-setup.sh install     # 安装节点服务并生成配置（交互式选择模式）
./xray-setup.sh uninstall   # 卸载当前节点服务并清理规则
./xray-setup.sh status      # 查看服务运行状态
./xray-setup.sh show        # 显示节点信息、分享链接及二维码
./xray-setup.sh restart     # 重启当前节点服务
./xray-setup.sh update      # 更新核心程序 (Xray 或 Hysteria)
./xray-setup.sh bbr         # 开启系统 BBR 拥塞控制
./xray-setup.sh icmp        # 开启 ICMP (允许 ping)
```

## 安装完成后

安装完成后会自动输出：

- 节点协议类型与状态
- 服务器地址、端口（或端口跳跃范围）、UUID / 认证密码
- 公钥、Short ID（Reality 模式）
- 伪装域名 (SNI)
- 对应协议的一键导入分享链接（`vless://` 或 `hysteria2://`）
- 终端二维码（支持客户端直接扫码导入）

---

## 客户端配置示例

### 1. V2rayN / V2rayNG / Shadowrocket / Nekoray / Sing-box

安装完成后终端会直接输出对应协议的分享链接，直接**复制分享链接导入**或**扫码导入**即可。

### 2. Clash Meta (Mihomo)

#### 直连模式 (VLESS + Reality)

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
    servername: <伪装域名 SNI> # 填入安装完成时提示的 SNI
    reality-opts:
      public-key: <公钥>
      short-id: <Short ID>
    client-fingerprint: chrome
```

#### 极速模式 (Hysteria 2 - 支持端口跳跃)

```yaml
proxies:
  - name: "Hysteria2"
    type: hysteria2
    server: <服务器IP>
    port: 443
    ports: 20000-50000 # 开启端口跳跃时填写，单端口模式可去掉此行
    password: <认证密码>
    sni: www.bing.com
    skip-cert-verify: true
    alpn:
      - h3
```

#### CDN 模式 (VLESS + XHTTP)

```yaml
proxies:
  - name: "Xray-CDN"
    type: vless
    server: <你的域名>
    port: 443
    uuid: <UUID>
    network: xhttp
    tls: true
    udp: true
    servername: <你的域名>
    xhttp-opts:
      path: /vless-xhttp
      headers:
        Host: <你的域名>
    client-fingerprint: chrome
```

### 3. Sing-box

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
    "server_name": "<伪装域名 SNI>",
    "reality": {
      "enabled": true,
      "public_key": "<公钥>",
      "short_id": "<Short ID>"
    }
  }
}
```

#### 极速模式 (Hysteria 2)

```json
{
  "type": "hysteria2",
  "tag": "hysteria2",
  "server": "<服务器IP>",
  "server_port": 443,
  "server_ports": ["20000:50000"],
  "password": "<认证密码>",
  "tls": {
    "enabled": true,
    "server_name": "www.bing.com",
    "insecure": true
  }
}
```

#### CDN 模式 (XHTTP)

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
    "type": "xhttp",
    "path": "/vless-xhttp",
    "headers": {
      "Host": "<你的域名>"
    }
  }
}
```

---

## 文件与配置位置

| 文件类型 | Xray 模式路径 | Hysteria 2 模式路径 |
| --- | --- | --- |
| **可执行二进制** | `/usr/local/bin/xray` | `/usr/local/bin/hysteria` |
| **配置文件** | `/usr/local/etc/xray/config.json` | `/etc/hysteria/config.yaml` |
| **自签证书 / 密钥** | `/usr/local/etc/xray/certs/` | `/etc/hysteria/server.crt`, `server.key` |
| **安装信息** | `/usr/local/etc/xray/install-info.conf` | `/usr/local/etc/xray/install-info.conf` |
| **日志目录** | `/var/log/xray/` | `/var/log/hysteria/` |
| **systemd 服务** | `/etc/systemd/system/xray.service` | `/etc/systemd/system/hysteria-server.service` |
| **OpenRC 服务** | `/etc/init.d/xray` | `/etc/init.d/hysteria-server` |

---

## 自动处理特性

脚本全自动处理底层系统细节：

- **端口与协议冲突检测**: 自动检测所选端口占用情况（支持 TCP 和 UDP），支持自动停止旧服务并防止端口冲突。
- **防火墙最小侵入与增量放行**: 遵循最小特权原则。若系统已有活跃防火墙（`ufw`、`firewalld` 或 `iptables`），仅增量追加开放当前代理协议所需端口，绝不扰动原有防火墙策略；若系统初次配置防火墙，则确保基础管理端口 (22/tcp) 与服务端口同时放行。
- **服务启动探活与故障自诊断**: 服务启动后自动执行探活校验；若启动失败立即抓取最近诊断日志并在终端高亮提示，杜绝“假成功”。
- **端口跳跃 (Port Hopping) 自动转发**: 自动配置 iptables UDP PREROUTING REDIRECT 规则，并写入开机持久化恢复脚本；卸载时干净清理。
- **智能环境感知伪装**: 直连模式针对服务器所在国家/地区及机房 ASN（如 AWS、Oracle、Azure、DigitalOcean、Hetzner、OVH 等）自动构建候选池，在 VPS 本地并发验证 TLS 1.3、ALPN (h2) 与握手 RTT，智能推荐延迟最低、拟真度最高的伪装站点，告别固定域名导致的特征暴露与封锁。
- **协议深度与证书规范化**: Xray 嗅探启用 `routeOnly: true` 避免破坏 TLS 原生握手；Hysteria 2 自签证书规范包含 `subjectAltName` (SAN) 扩展并遵循现代 TLS 有效期规范。
- **Init 系统适配**: 完美支持 systemd、OpenRC (Alpine Linux) 及无 init 系统的 nohup 守护，开机自启动全自动配置。
- **性能调优**: 自动检测并开启 Linux BBR 拥塞控制，自动放行 ICMP 允许网络连通性测试。
- **纯 IPv4 简化与稳健绑定**: 移除 IPv6 冗余交互，监听 `0.0.0.0`，杜绝部分 VPS 因关闭 IPv6 内核而引发的启动失败。

---

## 常见问题

### 1. 为什么 Reality 伪装域名要根据服务器信息智能匹配，而不是写死固定域名？

Reality 的核心工作原理是**借用真实合法站点的 TLS 证书与握手特征**，未通过身份鉴权的探测流量会被透明转发（Fallback）到该目标站点。
若使用写死的域名（如 `www.cloudflare.com`），一旦你的 VPS IP 属于 Oracle、Linode 或 AWS，就会产生严重的**「IP 归属 ASN 与 SNI 域名不符」**以及**「跨洋转发 RTT 异常毛刺」**，极易被防火墙的主动探测机制识别并阻断。
脚本内置智能画像与本地探针引擎：

- 优先选择与 VPS 同属一个机房/运营商（同 ASN）或同地理区域的本土高校/知名技术站点；
- 在 VPS 本地并发进行 TLS 1.3 协商、ALPN (h2) 协议支持与毫秒级延迟（RTT）探测；
- 确保握手行为真实自然，同时彻底避免客户端因伪装目标配置不合规而出现 `reality verification failed`。

### 2. 为什么 Reality 默认使用 443 端口，又支持自定义？

Reality 借用真实网站的 TLS 握手特征作为伪装，而公网绝大部分 HTTPS 服务均运行在标准 443 端口，因此使用 443 端口能达到最高的伪装与隐蔽效果。如果用户所在地区的运营商对境外 IP 的 443 端口存在封锁或丢包，脚本也支持在安装时自定义其他备用端口（如 8443 或高位端口）。

### 3. 什么是端口跳跃 (Port Hopping)？

部分运营商会对长期传输大流量的单个 UDP 端口进行 QoS 限速甚至断流。通过在服务端将例如 `20000-50000` 范围内的 UDP 流量自动转发至核心监听端口，客户端即可在发起连接时随机跳跃端口，彻底瓦解运营商基于单端口的阻断策略。

### 4. Alpine Linux 提示 `bash: not found`

Alpine Linux 默认使用 busybox ash，请先安装 bash 后再运行脚本：

```bash
apk add bash
```

### 5. 查看服务实时日志

```bash
# systemd 系统 (Xray)
journalctl -u xray -f

# systemd 系统 (Hysteria)
journalctl -u hysteria-server -f

# OpenRC / nohup 系统
tail -f /var/log/xray/error.log
tail -f /var/log/hysteria/error.log
```

## License

MIT
