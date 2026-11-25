#!/usr/bin/env bash
# Hysteria 2 节点一键部署（Debian / Ubuntu，root 执行）
#
# 用法：
#   HY2_CERT=/etc/hysteria/cert/fullchain.pem \
#   HY2_KEY=/etc/hysteria/cert/privkey.pem  ./deploy.sh
#
# 环境变量：
#   HY2_PORT           监听端口，默认 8443
#   HY2_CERT           证书链路径，默认 /etc/hysteria/cert/fullchain.pem
#   HY2_KEY            私钥路径，默认 /etc/hysteria/cert/privkey.pem
#   HY2_AUTH_PASSWORD  认证密码，不给则随机生成
#   HY2_OBFS_PASSWORD  混淆口令，不给则随机生成
#   MASQUERADE_URL     伪装目标，默认 https://www.bing.com
#   NODE_NAME          客户端显示名，默认 hysteria-node
set -euo pipefail

PORT="${HY2_PORT:-8443}"
CERT="${HY2_CERT:-/etc/hysteria/cert/fullchain.pem}"
KEY="${HY2_KEY:-/etc/hysteria/cert/privkey.pem}"
MASQ="${MASQUERADE_URL:-https://www.bing.com}"
NODE_NAME="${NODE_NAME:-hysteria-node}"

CFG_DIR=/etc/hysteria
CFG="$CFG_DIR/config.yaml"
SVC=/etc/systemd/system/hysteria-server.service
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SRC="$(cd "$HERE/.." && pwd)"

c() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }

# ---------- 1. 安装 hysteria ----------
c "检查 Hysteria"
if command -v hysteria >/dev/null 2>&1; then
  echo "已安装：$(hysteria version 2>/dev/null | grep -i '^Version' || hysteria version | head -1)"
else
  echo "未安装，执行官方安装脚本..."
  bash -c "$(curl -fsSL https://get.hy2.sh/)" || { warn "安装失败"; exit 1; }
fi

# ---------- 2. 端口占用检查（UDP） ----------
c "检查 UDP $PORT"
if ss -lunp 2>/dev/null | grep -q ":$PORT "; then
  HOLDER=$(ss -lunp 2>/dev/null | grep ":$PORT " | grep -oP 'users:\(\("\K[^"]+' | head -1)
  if [[ "$HOLDER" != "hysteria" ]]; then
    warn "UDP $PORT 已被 $HOLDER 占用"
    warn "Hysteria 需要独占该 UDP 端口。请先停掉它，或用 HY2_PORT 换一个端口"
    exit 1
  fi
  echo "已被 hysteria 自身占用，将覆盖配置后重启"
else
  echo "UDP $PORT 空闲"
fi

# ---------- 3. 证书 ----------
c "检查证书"
for f in "$CERT" "$KEY"; do
  [[ -f "$f" ]] || {
    warn "证书文件不存在：$f"
    cat <<'EOF'
Hysteria 强制 TLS（QUIC 内建），必须提供证书，这一项无法跳过。两条路：

  A. 自备证书 —— 把 fullchain.pem / privkey.pem 放到 /etc/hysteria/cert/，
     或用 HY2_CERT / HY2_KEY 指定路径。CloudFlare Origin 证书可以用，
     但客户端不受公共 CA 信任，必须开 insecure 或装它的根证书。

  B. 让 Hysteria 自己用 ACME 申请 —— 需要域名已解析到本机 80/443，
     把 config 里的 tls 段换成 acme 配置块。本脚本不代做这一步，
     写法见 README「证书」一节。
EOF
    exit 1
  }
done

# SNI 只能取非通配符条目：通配符（*.a.com）不能作为 SNI 发送，
# 而且 YAML 里未加引号的 * 会被解析成别名标记。
_all=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null \
       | tr ',' '\n' | grep -oE '[A-Za-z0-9*.-]+\.[A-Za-z]{2,}' || true)
SAN=$(printf '%s\n' "$_all" | grep -v '^\*' | head -1 || true)
if [[ -z "$SAN" ]]; then
  warn "证书 SAN 里只有通配符条目，无法自动确定 SNI"
  warn "通配符证书请手动指定一个具体子域名（如 node.example.com）"
  exit 1
fi
echo "证书域名(SNI) = $SAN"

# ---------- 4. 生成密钥 ----------
c "生成密钥"
AUTH_PWD="${HY2_AUTH_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)}"
OBFS_PWD="${HY2_OBFS_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)}"
echo "认证密码 = $AUTH_PWD"
echo "混淆口令 = $OBFS_PWD"

# ---------- 5. 渲染配置 ----------
c "渲染配置"
if [[ -f "$CFG" ]]; then
  BAK="$CFG.bak-$(date +%Y%m%d%H%M%S)"
  cp -f "$CFG" "$BAK"
  echo "旧配置已备份：$BAK"
fi

LISTEN_PORT="$PORT" TLS_CERT="$CERT" TLS_KEY="$KEY" \
AUTH_PASSWORD="$AUTH_PWD" OBFS_PASSWORD="$OBFS_PWD" \
MASQUERADE_URL="$MASQ" \
  python3 "$ROOT_SRC/scripts/render_config.py" \
  "$ROOT_SRC/config/config.yaml.example" "$CFG.new"

# ---------- 6. 试跑校验 ----------
# 两个坑都在这一步：
#   a) hysteria 靠文件扩展名判断配置类型，临时文件必须是 .yaml 后缀，
#      否则报 Unsupported Config Type "new"，看起来像配置写错了。
#   b) 服务已经在跑的时候，临时实例去抢同一个端口必然失败。
#      所以试跑前把 listen 改到本机一个随机空闲端口，只校验语法，不碰线上端口。
c "试跑校验（不影响正在运行的服务）"
PRE_PORT=$(shuf -i 20000-40000 -n 1)
for _ in 1 2 3 4 5; do
  ss -lunp 2>/dev/null | grep -q ":$PRE_PORT " || break
  PRE_PORT=$(shuf -i 20000-40000 -n 1)
done
PRECHECK="/tmp/hy2-precheck-$$.yaml"
sed "s|^listen:.*|listen: 127.0.0.1:${PRE_PORT}|" "$CFG.new" >"$PRECHECK"
set +e
timeout 4 hysteria server -c "$PRECHECK" >/tmp/hy2-precheck.log 2>&1
RC=$?
set -e
rm -f "$PRECHECK"
if [[ $RC -eq 124 ]]; then
  echo "试跑 4 秒未退出，配置合法（临时端口 $PRE_PORT）"
elif [[ $RC -eq 0 ]]; then
  echo "试跑正常退出"
else
  warn "配置校验失败，线上配置未改动"
  tail -20 /tmp/hy2-precheck.log
  rm -f "$CFG.new"
  exit 1
fi

install -m 0644 "$CFG.new" "$CFG"
rm -f "$CFG.new"

# ---------- 7. 安装服务 ----------
c "安装 systemd 服务"
install -m 0644 "$ROOT_SRC/deploy/hysteria-server.service" "$SVC"
systemctl daemon-reload
systemctl enable hysteria-server >/dev/null 2>&1 || true
systemctl restart hysteria-server
sleep 2
systemctl is-active hysteria-server

c "运行状态"
ss -lunp 2>/dev/null | grep ":$PORT " || warn "UDP $PORT 未监听，检查 journalctl -u hysteria-server -n 50"
journalctl -u hysteria-server -n 5 --no-pager | tail -5

# ---------- 8. 输出客户端链接 ----------
IP=$(curl -s -m 10 https://api.ipify.org || echo "<你的服务器IP>")
LINK="hysteria2://${AUTH_PWD}@${IP}:${PORT}/?sni=${SAN}&insecure=1&obfs=salamander&obfs-password=${OBFS_PWD}#${NODE_NAME}"

c "完成"
cat <<EOF
客户端链接（可直接导入 sing-box / NekoBox / Karing）：

$LINK

参数备忘：
  服务器     $IP
  端口       $PORT   （UDP，不要填 TCP）
  SNI        ${SAN}
  insecure   1       （自签 / CloudFlare Origin 证书必须开）
  认证密码   $AUTH_PWD
  混淆       salamander
  混淆口令   $OBFS_PWD

两个必查项：
  1) 服务器地址填 IP，不要填域名 —— 若域名走了 CDN（Cloudflare 橙云之类），
     CDN 不转发 UDP，包会直接消失，现象是客户端一直"连接中"。
  2) SNI 必须填 ${SAN}，不能填 IP 或 localhost。
     SNI 不匹配会在 TLS 层被拒，而且服务端日志一个字都不会记。

下一步：端到端自检（不依赖手机）
  python3 $ROOT_SRC/scripts/selftest.py

注意：真实配置只存在于 $CFG，认证密码与混淆口令都在里面。
不要提交到任何仓库，不要发给任何人。
EOF
