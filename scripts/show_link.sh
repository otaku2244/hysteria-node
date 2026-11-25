#!/usr/bin/env bash
# 从现有配置反推客户端链接（轮换口令、换设备时用）
#
# 用法：./show_link.sh [服务器IP]
# 不传 IP 时自动取本机公网出口地址。
set -euo pipefail

CFG="${HY2_CFG:-/etc/hysteria/config.yaml}"
NODE_NAME="${NODE_NAME:-hysteria-node}"

[[ -f "$CFG" ]] || { echo "配置不存在: $CFG"; exit 1; }

read -r PORT AUTH OBFS CERT < <(python3 - "$CFG" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()

def block(name):
    b = re.search(r"^%s:\s*\n((?:[ \t]+.*\n?)+)" % name, text, re.M)
    return b.group(1) if b else ""

port = (re.search(r"^listen:\s*:(\d+)", text, re.M) or [None, ""])[1]
auth = (re.search(r"password:\s*(\S+)", block("auth")) or [None, ""])[1]
obfs = (re.search(r"password:\s*(\S+)", block("obfs")) or [None, ""])[1]
cert = (re.search(r"cert:\s*(\S+)", block("tls")) or [None, ""])[1]
print(port, auth.strip('"'), obfs.strip('"'), cert.strip('"'))
PY
)

[[ -n "$PORT" && -n "$AUTH" ]] || { echo "配置解析失败"; exit 1; }

# SNI 取自证书，不要手填 —— 填错会在 TLS 层被拒且服务端不留日志。
# 通配符条目（*.a.com）不能当 SNI，必须优先取非通配符的那条。
_all=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null \
       | tr ',' '\n' | grep -oE '[A-Za-z0-9*.-]+\.[A-Za-z]{2,}' || true)
SNI=$(printf '%s\n' "$_all" | grep -v '^\*' | head -1 || true)
if [[ -z "$SNI" ]]; then
  echo "证书 SAN 里只有通配符条目，不能直接当 SNI。请手动指定一个具体子域名。" >&2
  exit 1
fi

IP="${1:-}"
if [[ -z "$IP" ]]; then
  IP=$(curl -s -m 10 https://api.ipify.org || true)
  [[ -n "$IP" ]] || { echo "取不到公网 IP，请手动传入"; exit 1; }
fi

echo "hysteria2://${AUTH}@${IP}:${PORT}/?sni=${SNI}&insecure=1&obfs=salamander&obfs-password=${OBFS}#${NODE_NAME}"
echo
printf '服务器   %s\n端口     %s (UDP)\nSNI      %s\n认证密码 %s\n混淆     salamander\n混淆口令 %s\n' \
  "$IP" "$PORT" "$SNI" "$AUTH" "$OBFS"
echo
echo "提醒：服务器地址用 IP，不要用域名。域名若走了 CDN，CDN 不转发 UDP。"
