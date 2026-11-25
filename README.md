# hysteria-node

一台自建代理节点：**Hysteria 2 + salamander 混淆**，UDP 单端口，QUIC 之上跑 TLS。
抗丢包强于 TCP 系方案，混淆后连 QUIC 握手指纹都读不到。

配置、部署脚本、服务单元、自检工具四件套，与同作者的 `xray-reality-node` 结构对齐。

```
客户端 ──QUIC/UDP───────────────> 本机:8443 ──> 出站
          └─ 整包 XOR(salamander)
              DPI 读不到 QUIC ClientHello，
             既看不到 SNI，也无从做指纹比对
          └─ 未通过认证者：反代到伪装站点（默认 bing）
```

---

## 为什么是 Hysteria 2 + obfs

| 方案 | 问题 |
|---|---|
| TCP 系（VLESS/VMess/Trojan） | 长连接 TCP 是 DPI 重点照顾对象，特征稳定，封起来有经验 |
| Hysteria 2 裸跑 | QUIC 的 ClientHello 仍是明文结构，能被指纹化，部分线路直接掐 QUIC |
| **Hysteria 2 + salamander** | 每个 UDP 包整体 XOR，线上看是一串随机字节，没有可读的握手 |

salamander 是对称 XOR，不是加密。它防的是**识别**，不是**窃听**——机密性由 QUIC 自带的 TLS 1.3 保证。

代价很明确：**两端口令必须一致，没有协商过程**。服务端开了客户端没开（或口令不同），现象是包发出去没有任何回应，客户端报 `timeout: no recent network activity`，服务端日志一片空白。这个坑很难从现象反推原因，记住它。

---

## 部署

### 前提

- 一台能连外网的 Linux（Debian 12 / Ubuntu 22.04+ 验证过）
- root 权限
- 一个 UDP 端口可用（默认 8443）
- **证书**：Hysteria 强制 TLS，这一项无法跳过，见下节

### 一键

```bash
git clone git@github.com:<you>/hysteria-node.git
cd hysteria-node

HY2_CERT=/etc/hysteria/cert/fullchain.pem \
HY2_KEY=/etc/hysteria/cert/privkey.pem \
./scripts/deploy.sh
```

脚本会依次做：

1. 装 Hysteria（调用官方 `get.hy2.sh`，已装则跳过）
2. 检查目标 UDP 端口是否被别的进程占用
3. 校验证书与私钥存在，从证书 SAN 里读出声明的域名
4. 生成认证密码与混淆口令（32 位随机），或用环境变量指定
5. 用 `config/config.yaml.example` 渲染出 `/etc/hysteria/config.yaml`（旧配置自动备份）
6. **试跑校验**：拿渲染结果起一个临时实例，跑 4 秒，不起就停在这一步，线上配置不动
7. 装 systemd 单元、开机自启、立刻启动
8. 打印可直接导入客户端的 `hysteria2://` 链接

### 参数

`deploy.sh` 接受的环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `HY2_PORT` | `8443` | 监听端口（UDP） |
| `HY2_CERT` | `/etc/hysteria/cert/fullchain.pem` | 证书链 |
| `HY2_KEY` | `/etc/hysteria/cert/privkey.pem` | 私钥 |
| `HY2_AUTH_PASSWORD` | 随机 32 位 | 认证密码，不给则生成 |
| `HY2_OBFS_PASSWORD` | 随机 32 位 | 混淆口令，不给则生成 |
| `MASQUERADE_URL` | `https://www.bing.com` | 未认证流量的落点 |
| `NODE_NAME` | `hysteria-node` | 客户端显示名 |

### 手工

```bash
LISTEN_PORT=8443 \
TLS_CERT=/etc/hysteria/cert/fullchain.pem \
TLS_KEY=/etc/hysteria/cert/privkey.pem \
AUTH_PASSWORD='<认证密码>' \
OBFS_PASSWORD='<混淆口令>' \
  python3 scripts/render_config.py config/config.yaml.example /etc/hysteria/config.yaml

# Hysteria 没有 config check 子命令，只能用临时实例试跑。
# 注意把 listen 改到随机端口 —— 服务已在跑时，抢同一个端口必然失败，
# 那种失败是端口冲突，不是配置错误，很容易误判。
sed 's|^listen:.*|listen: 127.0.0.1:29999|' /etc/hysteria/config.yaml > /tmp/precheck.yaml
timeout 4 hysteria server -c /tmp/precheck.yaml   # 退出码 124 = 跑满 4 秒被 kill = 配置合法

install -m 0644 deploy/hysteria-server.service /etc/systemd/system/hysteria-server.service
systemctl daemon-reload && systemctl enable --now hysteria-server
```

> 临时文件必须用 `.yaml` 后缀。Hysteria 靠**文件扩展名**判断配置类型，命名成 `config.yaml.new` 会报
> `failed to read server config: Unsupported Config Type "new"`，看起来像配置内容写错了，实际只是后缀不对。

---

## 证书

Hysteria 跑在 QUIC 上，TLS 是内建的，没有"无证书"模式。两条路：

### A. 自备证书（脚本走这条）

把证书放好，或者用 `HY2_CERT` / `HY2_KEY` 指路径：

```bash
mkdir -p /etc/hysteria/cert
# CloudFlare Origin / 商业证书 / acme.sh 签的都可以
chown -R hysteria:hysteria /etc/hysteria/cert
chmod 600 /etc/hysteria/cert/privkey.pem
```

**客户端注意**：证书若不是公共 CA 签发的（CloudFlare Origin、自签），客户端不受信任，必须开 `insecure`
或把签发者根证书装进客户端。否则报证书校验失败，与"连不上"是两回事。

### B. 让 Hysteria 自己走 ACME

需要域名已经解析到本机，且 80 或 443 可达。把配置里的 `tls` 段换成：

```yaml
tls:
  acme:
    domains:
      - node.example.com
    email: you@example.com
```

`deploy.sh` 不代做这一步，因为域名与 DNS 状态必须由你自己确认。

### SNI 必须是证书里声明的那个域名

服务端按 SNI 找证书。SNI 填 IP、填 `localhost`、填别的域名，握手在 TLS 层就被拒，客户端只会看到
`CRYPTO_ERROR 0x150 (remote): tls: internal error`，而**服务端日志一个字都不记**。这是排查时最容易走弯路的地方。

证书 SAN 里如果同时有 `*.a.com` 和 `a.com`，**必须用 `a.com`**。通配符不能作为 SNI 发送，而且 YAML 里
未加引号的 `*` 会被解析成别名标记，配置文件直接解析失败。如果证书只有 `*.a.com` 这一条，要自己指定一个
具体子域名（如 `node.a.com`）——`deploy.sh` 和 `show_link.sh` 在这种情况下会报错停下，而不是猜一个写进去。

`deploy.sh` 和 `show_link.sh` 都从证书 SAN 里读域名，不要手抄。

---

## 客户端

`deploy.sh` 末尾打印的链接直接粘贴即可：

```
hysteria2://<auth>@<ip>:8443/?sni=<证书域名>&insecure=1&obfs=salamander&obfs-password=<混淆口令>#hysteria-node
```

### 两条硬规则

**服务器地址填 IP，不要填域名**，除非你确认域名是直连（灰云）。域名一旦走了 Cloudflare 橙云这类 CDN，
解析结果会变成 CDN 的地址，而**CDN 不转发 UDP**，包打到 CDN 就消失了，现象是客户端永远"连接中"。
`dig +short 你的域名` 如果返回的不是你服务器的 IP，就老老实实填 IP。

**SNI 填证书里那个域名**，见上节。

### sing-box

```json
{
  "type": "hysteria2",
  "tag": "proxy",
  "server": "1.2.3.4",
  "server_port": 8443,
  "password": "<认证密码>",
  "obfs": {
    "type": "salamander",
    "password": "<混淆口令>"
  },
  "tls": {
    "enabled": true,
    "server_name": "node.example.com",
    "insecure": true,
    "alpn": ["h3"]
  },
  "up_mbps": 30,
  "down_mbps": 200
}
```

版本要求 **sing-box ≥ 1.11**。低于 1.11 的版本不认 `route.rules` 里的 `action` 字段；而 1.13 之后
`inbounds[].sniff` 这种旧写法被彻底移除，硬写会直接拒绝加载。完整的客户端配置不在本仓库范围，
但这两条足以避开绝大多数加载失败。

`up_mbps` / `down_mbps` 不要往大里写。服务端 `ignoreClientBandwidth: false` 时会采纳客户端声明的带宽，
走 Hysteria 自家的 Brutal 拥塞控制，小内存 VPS 的 CPU 会被打满。想两端都走 BBR，把服务端改成 `true`，
客户端这两个字段留空。

### 其他客户端

| 客户端 | 用法 |
|---|---|
| NekoBox / Karing / Hiddify | 直接导入 `hysteria2://` 链接 |
| mihomo / Clash.Meta | `proxies` 里 `type: hysteria2`，加 `obfs: salamander`、`obfs-password` |
| 命令行 | `scripts/show_link.sh` 从现有配置反推链接 |

---

## 自检

不用手机，在服务器本机上就能验证链路是否真的通：

```bash
python3 scripts/selftest.py
```

原理：读服务端配置 → 取端口/认证密码/混淆口令 → 从证书读 SNI → 在 `127.0.0.1` 起临时客户端
→ 用 curl 穿过它访问 `cloudflare.com/cdn-cgi/trace` → 比对出口 IP → **再用错误口令跑一次反证**
→ 清理临时进程。

最后那步反证是关键：如果错误口令也能连上，说明混淆根本没生效，你以为的隐蔽性并不存在。

通过的样子：

```
[配置] 端口=8443 SNI=node.example.com obfs=salamander
[正向] 经隧道出口 ip=1.2.3.4
[对照] 本机直连出口 ip=1.2.3.4
[反证] 错误混淆口令 -> 无响应（符合预期）
[判定] PASS
```

可配置项：`HY2_CFG`、`HY2_BIN`、`SELFTEST_SOCKS_PORT`、`SELFTEST_TIMEOUT`。

---

## 端口与混淆怎么选

| 项 | 建议 | 理由 |
|---|---|---|
| 端口 | 8443 或 2053、2083、2087 这类"看起来像 HTTPS 备用口"的 | UDP 443 常与别的服务撞端口；8443 既不扎眼也几乎不冲突 |
| 混淆 | 开，且口令用 32 位随机 | 不开等于把 QUIC 指纹拱手送上 |
| 伪装站点 | 换成你自己常用的正常站点 | 默认 bing 只是占位，扫描器看到的是你在反代 bing |

同机有 TCP 443 的 REALITY 时，两套可以共存：一个占 TCP，一个占 UDP，协议栈层面互不干扰。

---

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 服务起不来，日志 `address already in use` | UDP 端口被占 | `ss -lunp \| grep :8443` 找占用者，或用 `HY2_PORT` 换端口 |
| 客户端 `timeout: no recent network activity` | 混淆口令不一致 / 服务端没开 obfs | 两端逐字核对 `obfs-password` |
| 客户端 `CRYPTO_ERROR 0x150 tls: internal error` | SNI 与证书域名不一致 | SNI 填证书 SAN 里的域名，不能填 IP 或 localhost |
| 客户端一直"连接中"，服务端日志无记录 | 地址填了走 CDN 的域名 | 改成服务器 IP |
| 客户端证书校验失败（x509） | 证书非公共 CA 签发 | 开 `insecure`，或装上签发者根证书 |
| `Unsupported Config Type "new"` | 临时配置文件名后缀不对 | 用 `.yaml` |
| 速度上不去、CPU 打满 | 客户端带宽声明过大，走了 Brutal | 调小 `up_mbps`/`down_mbps`，或服务端 `ignoreClientBandwidth: true` |

---

## 安全边界

- 服务以 `hysteria` 用户运行，只保留 `CAP_NET_ADMIN` / `CAP_NET_BIND_SERVICE` / `CAP_NET_RAW`，不是 root
- salamander 只做混淆，不做认证；认证由 `auth.password` 负责，两者不要混为一谈
- 节点本身不做分流，流量全部落地到本机出站。需要分流在客户端侧加规则
- **这个仓库不含任何真实口令**。`config.yaml.example` 全是占位符，真实配置只存在于服务器本地

## 局限

- 强依赖 UDP。线路若整体丢弃非 DNS 的 UDP，这套方案直接不可用
- 单节点单口令模型。多用户要在 `auth` 段改成 `userpass` 并在客户端把用户名密码拼成 `user:pass`
- 混淆会带来轻微 CPU 开销，极高吞吐场景下比裸 QUIC 略贵
- 伪装站点是单点依赖：如果它在你线路上不可达，未认证流量的表现会变差（不影响代理本身）
