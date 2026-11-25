#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Hysteria 2 端到端自检：不依赖手机，在服务器本机上验证链路真的通。

原理：
    读服务端配置 -> 取端口/认证密码/混淆口令 -> 从证书读 SNI
    -> 在 127.0.0.1 起一个临时 hysteria 客户端（socks5）
    -> 用 curl 穿过它访问 cloudflare/cdn-cgi/trace -> 比对出口 IP
    -> 再做一次反证：故意填错混淆口令，应当连不上
    -> 清理临时进程与配置

通过的样子：
    [配置] 端口=8443 SNI=x.example.com obfs=salamander
    [正向] 经隧道出口 ip=1.2.3.4
    [对照] 本机直连出口 ip=1.2.3.4
    [反证] 错误混淆口令 -> 超时无响应（符合预期）
    [判定] PASS

可配置项：HY2_CFG / HY2_BIN / SELFTEST_SOCKS_PORT / SELFTEST_TIMEOUT
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

CFG = os.environ.get("HY2_CFG", "/etc/hysteria/config.yaml")
BIN = os.environ.get("HY2_BIN", "hysteria")
SOCKS_PORT = int(os.environ.get("SELFTEST_SOCKS_PORT", "18080"))
SOCKS_PORT_NEG = SOCKS_PORT + 1
TIMEOUT = int(os.environ.get("SELFTEST_TIMEOUT", "15"))


def line(msg):
    print(msg, flush=True)


def read_cfg(path):
    """从服务端配置里取端口、认证密码、混淆口令、证书路径。

    优先用 PyYAML；没有就退回针对性的正则 —— 只认这份模板产出的结构。
    """
    text = open(path, "r", encoding="utf-8").read()
    try:
        import yaml  # type: ignore
        d = yaml.safe_load(text)
        port = str(d["listen"]).lstrip(":")
        auth = d["auth"]["password"]
        obfs = (d.get("obfs") or {}).get("salamander", {}).get("password", "")
        cert = d["tls"]["cert"]
        return port, auth, obfs, cert
    except ImportError:
        pass
    except Exception:
        pass

    m = re.search(r"^listen:\s*:(\d+)", text, re.M)
    port = m.group(1) if m else ""

    def block(name):
        b = re.search(r"^%s:\s*\n((?:[ \t]+.*\n?)+)" % name, text, re.M)
        return b.group(1) if b else ""

    mp = re.search(r"password:\s*(\S+)", block("auth"))
    auth = mp.group(1) if mp else ""
    mo = re.search(r"password:\s*(\S+)", block("obfs"))
    obfs = mo.group(1) if mo else ""
    mc = re.search(r"cert:\s*(\S+)", block("tls"))
    cert = mc.group(1) if mc else ""
    return port, auth.strip('"'), obfs.strip('"'), cert.strip('"')


def cert_sni(path):
    """从证书 SAN 里读声明的域名。

    两个坑：
      a) SAN 里可能同时有通配符 `*.a.com` 和裸域 `a.com`，而通配符顺序在前。
         通配符不能当 SNI 用（客户端不会发 `*.a.com`），必须优先取非通配符条目。
      b) SNI 填错会在 TLS 层被拒，且服务端不留任何日志，只能靠这里取对。
    """
    try:
        out = subprocess.run(
            ["openssl", "x509", "-in", path, "-noout", "-ext", "subjectAltName"],
            capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""
    names = re.findall(r"DNS:([A-Za-z0-9*.-]+)", out)
    plain = [n for n in names if not n.startswith("*")]
    if plain:
        return plain[0]
    # 只剩通配符：通配符不能直接当 SNI，退化成提示
    return ""


def write_client(path, port, auth, obfs, sni, socks_port):
    # sni / 口令 一律加引号：YAML 里未加引号的 * 会被解析成别名标记，
    # 报 "did not find expected alphabetic or numeric character"
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            'server: "127.0.0.1:%s"\n'
            'auth: "%s"\n'
            "tls:\n"
            '  sni: "%s"\n'
            "  insecure: true\n"
            "obfs:\n"
            "  type: salamander\n"
            "  salamander:\n"
            '    password: "%s"\n'
            "socks5:\n"
            '  listen: "127.0.0.1:%d"\n'
            % (port, auth, sni, obfs, socks_port))


def curl_via(socks_port, url, wait=None):
    cmd = ["curl", "-s", "--max-time", str(wait or TIMEOUT),
           "--socks5-hostname", "127.0.0.1:%d" % socks_port, url]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=(wait or TIMEOUT) + 5)
    return r.stdout.strip(), r.returncode


def get_ip(text):
    m = re.search(r"(?:^ip=|^)(\d{1,3}(?:\.\d{1,3}){3})\s*$", text, re.M)
    return m.group(1) if m else ""


def run_client(cfg_path, log_path):
    logf = open(log_path, "w")
    p = subprocess.Popen([BIN, "client", "-c", cfg_path, "--disable-update-check"],
                         stdout=logf, stderr=subprocess.STDOUT)
    return p, logf


def main():
    if not shutil.which(BIN):
        line("[失败] 找不到 hysteria 可执行文件")
        return 2
    if not os.path.exists(CFG):
        line("[失败] 配置不存在: %s" % CFG)
        return 2

    port, auth, obfs, cert = read_cfg(CFG)
    if not (port and auth and obfs and cert):
        line("[失败] 配置解析不全：port=%r auth=%s obfs=%s cert=%s"
             % (port, bool(auth), bool(obfs), cert))
        return 2

    sni = cert_sni(cert)
    if not sni:
        line("[失败] 无法从证书读出声明的域名，客户端 SNI 无从填写")
        return 2

    line("[配置] 端口=%s SNI=%s obfs=salamander" % (port, sni))

    tmpdir = tempfile.mkdtemp(prefix="hy2selftest-")
    ok_cfg = os.path.join(tmpdir, "ok.yaml")
    bad_cfg = os.path.join(tmpdir, "bad.yaml")
    write_client(ok_cfg, port, auth, obfs, sni, SOCKS_PORT)
    write_client(bad_cfg, port, auth, "WRONG_OBFS_PASSWORD_FOR_NEGATIVE_TEST", sni, SOCKS_PORT_NEG)

    procs = []
    try:
        # ---- 正向 ----
        p1, f1 = run_client(ok_cfg, os.path.join(tmpdir, "ok.log"))
        procs.append((p1, f1))
        time.sleep(5)
        body, rc = curl_via(SOCKS_PORT, "https://www.cloudflare.com/cdn-cgi/trace")
        got = get_ip(body)
        if got:
            line("[正向] 经隧道出口 ip=%s" % got)
        else:
            line("[正向] 失败 (curl rc=%d)，客户端日志：" % rc)
            for ln in open(os.path.join(tmpdir, "ok.log")).read().splitlines()[-6:]:
                line("        " + ln)

        # ---- 对照 ----
        direct = ""
        try:
            r = subprocess.run(["curl", "-s", "--max-time", "10", "https://api.ipify.org"],
                               capture_output=True, text=True, timeout=15)
            direct = r.stdout.strip()
            line("[对照] 本机直连出口 ip=%s" % (direct or "<取不到>"))
        except Exception:
            pass

        # ---- 反证 ----
        p2, f2 = run_client(bad_cfg, os.path.join(tmpdir, "bad.log"))
        procs.append((p2, f2))
        time.sleep(6)
        body2, rc2 = curl_via(SOCKS_PORT_NEG, "https://www.cloudflare.com/cdn-cgi/trace", wait=8)
        neg_ok = (get_ip(body2) == "")
        line("[反证] 错误混淆口令 -> %s" % ("无响应（符合预期）" if neg_ok
                                        else "竟然连上了，混淆可能没生效"))

        # ---- 判定 ----
        pass_all = bool(got) and got == direct and neg_ok
        line("[判定] %s" % ("PASS" if pass_all else "FAIL"))
        return 0 if pass_all else 1
    finally:
        for p, f in procs:
            p.terminate()
            try:
                p.wait(timeout=5)
            except Exception:
                p.kill()
            f.close()
        shutil.rmtree(tmpdir, ignore_errors=True)
        line("[清理] 临时客户端与配置已移除")


if __name__ == "__main__":
    sys.exit(main())
