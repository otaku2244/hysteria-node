#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 config.yaml.example 渲染成 Hysteria 2 的实际配置。

占位符替换 + 必填校验，避免手改配置时漏掉某个字段。
参数一律通过环境变量传入，避免密钥出现在进程命令行里（ps 可见）。

渲染完不做语法校验 —— hysteria 没有 config check 子命令，
语法错误只能在启动时暴露。所以 deploy.sh 会在落盘前
用临时实例试跑一次，见该脚本第 4 步。

用法:
    LISTEN_PORT=8443 AUTH_PASSWORD=x OBFS_PASSWORD=y \\
    TLS_CERT=/path/fullchain.pem TLS_KEY=/path/privkey.pem \\
    python3 render_config.py config/config.yaml.example /etc/hysteria/config.yaml
"""
import os
import sys

# 占位符 -> 环境变量名 -> 是否必填
FIELDS = [
    ("__REPLACE_WITH_PORT__", "LISTEN_PORT", True),
    ("__REPLACE_WITH_CERT_PATH__", "TLS_CERT", True),
    ("__REPLACE_WITH_KEY_PATH__", "TLS_KEY", True),
    ("__REPLACE_WITH_AUTH_PASSWORD__", "AUTH_PASSWORD", True),
    ("__REPLACE_WITH_OBFS_PASSWORD__", "OBFS_PASSWORD", True),
    ("__REPLACE_WITH_MASQUERADE_URL__", "MASQUERADE_URL", False),
]

DEFAULT_MASQUERADE = "https://www.bing.com"


def main():
    if len(sys.argv) != 3:
        print("usage: render_config.py <template> <output>", file=sys.stderr)
        return 2

    tpl_path, out_path = sys.argv[1], sys.argv[2]

    miss = [env for _, env, required in FIELDS
            if required and not os.environ.get(env)]
    if miss:
        print("缺少环境变量: " + ", ".join(miss), file=sys.stderr)
        return 2

    with open(tpl_path, "r", encoding="utf-8") as fh:
        text = fh.read()

    for ph, env, _ in FIELDS:
        val = os.environ.get(env)
        if not val:
            val = DEFAULT_MASQUERADE if env == "MASQUERADE_URL" else ""
        text = text.replace(ph, val)

    if "__REPLACE_WITH_" in text:
        leftover = sorted({w for w in text.split() if "__REPLACE_WITH_" in w})
        print("仍有未替换的占位符: " + " ".join(leftover), file=sys.stderr)
        return 2

    # 证书与私钥必须真实存在，否则 hysteria 启动时才报错，排查成本高
    for env in ("TLS_CERT", "TLS_KEY"):
        p = os.environ.get(env, "")
        if p and not os.path.exists(p):
            print("%s 指向的文件不存在: %s" % (env, p), file=sys.stderr)
            return 2

    d = os.path.dirname(os.path.abspath(out_path))
    os.makedirs(d, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(text)

    os.chmod(out_path, 0o644)
    print("已渲染: %s" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
