#!/bin/bash
# ---------------------------------------------------------------------------
# 衍生自 aimili-vpngate (https://github.com/baoweise-bot/aimili-vpngate)
# 依据 GPL-3.0 修改与分发；本文件的衍生部分同样以 GPL-3.0 发布。
# 完整许可见同目录 LICENSE，改造说明见 NOTICE。
#
# MichaelVPN One —— 单通道、单端口版
#   · 整机只对外提供 1 个 SOCKS5/HTTP 代理端口（默认 7928），NAT 机只要映射这一个口
#   · 面板 8787（NAT 机上也要映射出来，否则只能用内网地址访问）
#   · 测速专用口 7929 只监听回环，不需要映射
# ---------------------------------------------------------------------------
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

if [ "$(id -u)" != "0" ]; then echo -e "${RED}必须以 root 权限运行${NC}"; exit 1; fi

INSTALL_DIR="/opt/aimilivpn"
SERVICE_NAME="MichaelVpn"
GUARD_SERVICE="vpngate-one-guard"
# 老版本（6 通道 Dport 版）的守护单元名，切换过来时要清掉，否则两个守护抢着重连
LEGACY_GUARD="vpngate6-guard"
# 默认装本仓库（完整版：源码 + tests/）。
# 想装别的分支/仓库: bash install.sh <owner> <repo>
REPO_OWNER="${1:-Michaelwuzb}"
REPO_NAME="${2:-MichaelVPNone}"
BRANCH="main"

# 策略路由表号：通道 0 用 200，测速口用 201（主程序 POLICY_TABLE_BASE=200）。
# 卸载/切换时必须清干净：tun 设备会随进程消失，但 ip rule/route 留在内核里，
# 会继续把别人的流量往一个已经不存在的设备上引。
#   200~210  本版（单通道 200 + 测速 201），多留几格是为了以后可能调大通道数
#   100~110  更早的 6 通道版用 100+i 做表号，从那种机器切换过来时也要清
cleanup_policy_routing() {
    for t in $(seq 200 210) $(seq 100 110); do
        # ip rule del 每次只删一条匹配项，必须循环删到删不动
        while ip rule del table "$t" 2>/dev/null; do :; done
        ip route flush table "$t" 2>/dev/null || true
    done
}

stop_everything() {
    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    systemctl stop ${GUARD_SERVICE} 2>/dev/null || true
    systemctl stop ${LEGACY_GUARD} 2>/dev/null || true
    # 主进程被停掉后子进程（openvpn / 代理）可能还在，先清一遍
    pkill -f "vpngate_one.py\|proxy_server.py\|vpngate_one_guard.py" 2>/dev/null || true
    sleep 1
}

# === 卸载功能 ===
if [ "${1:-}" = "uninstall" ] || [ "${1:-}" = "卸载" ]; then
    echo -e "${YELLOW}正在卸载 MichaelVPN One...${NC}"
    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    systemctl disable ${SERVICE_NAME} 2>/dev/null || true
    # 守护也装了服务，得一起停掉 —— 否则它会继续按老端口探活、给已删掉的通道重连
    systemctl stop ${GUARD_SERVICE} 2>/dev/null || true
    systemctl disable ${GUARD_SERVICE} 2>/dev/null || true
    systemctl stop ${LEGACY_GUARD} 2>/dev/null || true
    systemctl disable ${LEGACY_GUARD} 2>/dev/null || true
    rm -f /lib/systemd/system/${SERVICE_NAME}.service
    rm -f /lib/systemd/system/${GUARD_SERVICE}.service
    rm -f /lib/systemd/system/${LEGACY_GUARD}.service
    systemctl daemon-reload
    cleanup_policy_routing
    rm -rf "$INSTALL_DIR"
    rm -f /usr/bin/ml
    rm -f /etc/sysctl.d/99-${SERVICE_NAME}.conf
    pkill -f "vpngate_one.py\|proxy_server.py\|vpngate_one_guard.py" 2>/dev/null || true
    echo -e "${GREEN}卸载完成！${NC}"
    exit 0
fi

detect_distro() {
    if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else OS=$(uname -s | tr '[:upper:]' '[:lower:]'); fi
    case "$OS" in
        ubuntu|debian|linuxmint|pop|kali|raspbian) PKG_MANAGER="apt-get" ;;
        alpine) PKG_MANAGER="apk"; OS="alpine" ;;
        centos|rhel|rocky|almalinux|fedora|oraclelinux)
            command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"; OS="centos" ;;
        arch|manjaro) PKG_MANAGER="pacman"; OS="arch" ;;
        opensuse*|suse*) PKG_MANAGER="zypper"; OS="opensuse" ;;
        *) echo -e "${RED}不支持: $OS${NC}"; exit 1 ;;
    esac
    echo -e "${GREEN}系统: $OS${NC}"
}

install_deps() {
    echo -e "${CYAN}[1/6] 安装依赖...${NC}"
    # openssl 是为了给面板自签 HTTPS 证书（找不到现成证书时的兜底）。
    # 系统自带的一般都有，这里显式装上，省得落到"没 openssl 就退明文 HTTP"。
    case "$PKG_MANAGER" in
        apt-get) apt-get update -qq && apt-get install -y -qq openvpn curl git ca-certificates iptables iproute2 psmisc python3 openssl 2>/dev/null ;;
        apk) apk update -q && apk add openvpn curl git ca-certificates iptables iproute2 psmisc python3 bash openssl 2>/dev/null ;;
        dnf|yum) $PKG_MANAGER install -y epel-release 2>/dev/null || true; $PKG_MANAGER install -y openvpn curl git ca-certificates iptables iproute psmisc python3 openssl 2>/dev/null ;;
        pacman) pacman -S --noconfirm openvpn curl git ca-certificates iptables iproute2 psmisc python openssl 2>/dev/null ;;
        zypper) zypper install -y openvpn curl git ca-certificates iptables iproute2 psmisc python3 openssl 2>/dev/null ;;
    esac
    echo -e "${GREEN}  OK${NC}"
}

deploy_code() {
    echo -e "${CYAN}[2/6] 部署代码...${NC}"
    if [ -d "$INSTALL_DIR/.git" ]; then
        cd "$INSTALL_DIR"
        # 关键：从 6 通道版切过来时，origin 还指着老仓库。不换地址的话
        # `git fetch && reset --hard origin/main` 拉回来的仍然是 6 通道代码，
        # 表现就是"装完还是六个端口"。
        git remote set-url origin "https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
        git fetch --all --prune 2>/dev/null || true
        git reset --hard "origin/${BRANCH}"
        # 只清未被跟踪、也没被 .gitignore 忽略的残留（老版本改名前的 .py 之类）。
        # 不带 -x，所以 vpngate_data/ 里的通道配置、密码哈希、IP 缓存都不会被动到。
        git clean -fd 2>/dev/null || true
    elif [ -d "$INSTALL_DIR" ]; then
        # 目录在但不是 git 仓库（手工解压安装的）：重拉代码，数据目录保持不动
        git clone --depth 1 -b "$BRANCH" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$INSTALL_DIR.tmp"
        cp -a "$INSTALL_DIR.tmp"/. "$INSTALL_DIR"/
        rm -rf "$INSTALL_DIR.tmp"
    else
        git clone --depth 1 -b "$BRANCH" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$INSTALL_DIR"
    fi

    # Generate login page
    mkdir -p "$INSTALL_DIR/vpngate_data"
    if [ ! -f "$INSTALL_DIR/vpngate_data/login.html" ]; then
        cat > "$INSTALL_DIR/vpngate_data/login.html" << 'LOGINEOF'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MichaelVPN One 登录</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#0f0f13;color:#e0e0e0;display:flex;align-items:center;justify-content:center;min-height:100vh}
.card{background:#1a1a24;border:1px solid rgba(255,255,255,0.08);border-radius:20px;padding:40px;width:360px}
.logo{font-size:24px;font-weight:700;text-align:center;margin-bottom:8px;color:#f0f0f5}
.sub{text-align:center;color:#6b7280;font-size:13px;margin-bottom:28px}
.fg{margin-bottom:16px}
.fg label{display:block;font-size:12px;color:#9ca3af;margin-bottom:6px}
.fg input{width:100%;padding:10px 14px;background:#0f0f13;border:1px solid rgba(255,255,255,0.1);border-radius:10px;color:#e0e0e0;font-size:14px;outline:none}
.fg input:focus{border-color:#818cf8}
.btn{width:100%;padding:10px;background:#818cf8;border:none;border-radius:10px;color:#fff;font-size:14px;font-weight:500;cursor:pointer}
.btn:hover{background:#6d79e8}
.err{color:#ef4444;font-size:13px;text-align:center;margin-top:10px}
</style>
</head>
<body>
<div class="card">
<div class="logo">MichaelVPN One</div>
<div class="sub">单通道 VPN 管理面板</div>
<form method="post" action="/api/login">
<div class="fg"><label>管理账号</label><input type="text" name="username" required autocomplete="username"></div>
<div class="fg"><label>安全密码</label><input type="password" name="password" required autocomplete="current-password"></div>
<button class="btn" type="submit">登录</button>
<div class="err" style="display:${error_display}">${error_text}</div>
</form>
</div>
</body>
</html>
LOGINEOF
    fi

    # Generate default auth if missing
    # 首次启动时面板会把它自动升级成 PBKDF2 哈希(明文只在首次存在)
    if [ ! -f "$INSTALL_DIR/vpngate_data/ui_auth.json" ]; then
        echo '{"username":"admin","password":"admin"}' > "$INSTALL_DIR/vpngate_data/ui_auth.json"
    fi
    # 若存在旧的明文格式, 启动前先就地升级为哈希
    python3 - "$INSTALL_DIR" << 'PYEOF' 2>/dev/null || true
import json, os, secrets, hashlib, sys
d = sys.argv[1]; p = os.path.join(d, "vpngate_data", "ui_auth.json")
try:
    cfg = json.load(open(p, encoding="utf-8"))
except Exception:
    sys.exit(0)
if cfg.get("password_hash") or "password" not in cfg:
    sys.exit(0)
salt = secrets.token_hex(16)
dk = hashlib.pbkdf2_hmac("sha256", str(cfg.get("password", "admin")).encode(), bytes.fromhex(salt), 200000)
cfg = {"username": cfg.get("username", "admin"),
       "password_hash": "pbkdf2_sha256$200000$%s$%s" % (salt, dk.hex())}
open(p, "w", encoding="utf-8").write(json.dumps(cfg, ensure_ascii=False, indent=2))
print("  ui_auth.json 明文密码已升级为哈希")
PYEOF

    # 代理口认证：默认**不开启**，和 6/9 通道版保持一致 —— 7928 无账号密码，本机 / 内网直接连。
    # 只有当你要把 7928 映射到公网（NAT 出站）时，才建议手动补一份认证，防止被白嫖：
    #   python3 - <<'PYEOF'
    #   import json, secrets
    #   p = "/opt/aimilivpn/vpngate_data/proxy_auth.json"
    #   json.dump({"username": "mvp" + secrets.token_hex(2),
    #              "password": secrets.token_urlsafe(12)},
    #             open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    #   import os; os.chmod(p, 0o600)
    #   PYEOF
    #   然后 systemctl restart MichaelVpn。
    # 如果之前装过带认证的版本、现在想回到无认证，删掉 proxy_auth.json 再重启即可。

    chmod -R 755 "$INSTALL_DIR"
    # 面板凭据、守护令牌都不能全机可读
    chmod 600 "$INSTALL_DIR/vpngate_data/ui_auth.json" 2>/dev/null || true
    chmod 600 "$INSTALL_DIR/vpngate_data/guard_token" 2>/dev/null || true
    echo -e "${GREEN}  OK${NC}"
}

install_service() {
    echo -e "${CYAN}[3/6] 配置面板服务...${NC}"
    # 服务名从 aimilivpn 改成了 MichaelVpn：老机器升级时把旧单元清掉，
    # 否则新旧两个单元都指向同一个主程序，会抢端口
    if [ -f /lib/systemd/system/aimilivpn.service ]; then
        systemctl stop aimilivpn 2>/dev/null || true
        systemctl disable aimilivpn 2>/dev/null || true
        rm -f /lib/systemd/system/aimilivpn.service
        systemctl daemon-reload
    fi
    # 6 通道版的守护单元，切换过来必须清掉：它会按老端口去探活，把正常通道判成假连接
    if [ -f /lib/systemd/system/${LEGACY_GUARD}.service ]; then
        systemctl stop ${LEGACY_GUARD} 2>/dev/null || true
        systemctl disable ${LEGACY_GUARD} 2>/dev/null || true
        rm -f /lib/systemd/system/${LEGACY_GUARD}.service
        systemctl daemon-reload
    fi
    cat > /lib/systemd/system/${SERVICE_NAME}.service << 'SERVICEEOF'
[Unit]
Description=MichaelVPN One single-port VPN Gateway
After=network.target network-online.target
Wants=network-online.target
# 崩溃后允许无限重启（默认 5 次/10 秒 就会被 systemd 放弃）
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=/opt/aimilivpn
ExecStart=/usr/bin/python3 /opt/aimilivpn/vpngate_one.py
Restart=always
RestartSec=5
# 代理口要收 NAT 映射过来的流量，必须绑 0.0.0.0；
# 只想给同机程序用就改成 127.0.0.1。
Environment=VPNGATE_PROXY_LISTEN=0.0.0.0
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICEEOF
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} 2>/dev/null || true
    echo -e "${GREEN}  OK${NC}"
}

# 通道守护：判断"假连接"（面板显示已连接但 SOCKS5 实测没有出口流量）并自动换节点。
# 以前要照着 README 手动写这一份 service，装完忘了装就等于没有守护 ——
# 所以这里直接一起装上。不想装：ML_NO_GUARD=1 bash install.sh
install_guard_service() {
    if [ "${ML_NO_GUARD:-0}" = "1" ]; then
        echo -e "${YELLOW}[4/6] 跳过守护服务（ML_NO_GUARD=1）${NC}"
        return 0
    fi
    echo -e "${CYAN}[4/6] 配置守护服务...${NC}"
    cat > /lib/systemd/system/${GUARD_SERVICE}.service << 'GUARDEOF'
[Unit]
Description=MichaelVPN One Guard (fake-connection detector)
# 面板是它探活的对象，排在面板后面启动才有意义
After=network.target network-online.target MichaelVpn.service
Wants=network-online.target
# 崩了要能一直重来（默认 5 次/10 秒 会被 systemd 放弃，守护就没了）
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=/opt/aimilivpn
# 只在"假连接/连不上"时动手，不主动轮换出口 IP。
# 确实想要定时换 IP 就改成 30（单位是"轮"，60 秒一轮）。
Environment=VPNGATE_ROTATE_EVERY=0
ExecStart=/usr/bin/python3 /opt/aimilivpn/vpngate_one_guard.py
Restart=always
RestartSec=10
# 守护会调 curl 走 SOCKS5 实测出口
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
GUARDEOF
    systemctl daemon-reload
    systemctl enable ${GUARD_SERVICE} 2>/dev/null || true
    echo -e "${GREEN}  OK${NC}"
}

install_ml() {
    echo -e "${CYAN}[5/6] 创建 ml 命令...${NC}"
    cat > /usr/bin/ml << 'MLEOF'
#!/bin/bash
# 面板接口调用：面板可能跑在 https 上（复用 s-ui 等现成证书，或自签）。
# 走回环地址，所以用 -k 跳过证书校验 —— 自签证书的域名本来就对不上 127.0.0.1。
panel_api() {
    curl -sk --max-time 8 "https://localhost:8787$1" 2>/dev/null && return 0
    curl -s --max-time 8 "http://localhost:8787$1" 2>/dev/null
}
info() {
    echo "=== MichaelVPN One（单通道 / 单端口）==="
    echo "  代理端口: 7928  (SOCKS5 + HTTP 共用，绑 0.0.0.0)"
    echo "  测速端口: 7929  (只看回环，不需要映射)"
    echo "  面板端口: 8787"
    echo "  代理认证: 默认无认证（和 6/9 通道版一样，127.0.0.1:7928 直接连）"
    if [ -f "$INSTALL_DIR/vpngate_data/proxy_auth.json" ]; then
        echo "  提示: 检测到旧的 proxy_auth.json，代理口当前仍带认证。"
        echo "        想回到无认证就删掉它再重启：rm -f $INSTALL_DIR/vpngate_data/proxy_auth.json"
    fi
}
case "${1:-status}" in
    start)   systemctl start MichaelVpn vpngate-one-guard 2>/dev/null ;;
    stop)    systemctl stop MichaelVpn vpngate-one-guard 2>/dev/null ;;
    restart) systemctl restart MichaelVpn 2>/dev/null; systemctl restart vpngate-one-guard 2>/dev/null ;;
    info|连接信息) info ;;
    uninstall|卸载)
        echo -e "\033[0;33m正在卸载 MichaelVPN One...\033[0m"
        systemctl stop MichaelVpn 2>/dev/null || true
        systemctl disable MichaelVpn 2>/dev/null || true
        systemctl stop vpngate-one-guard 2>/dev/null || true
        systemctl disable vpngate-one-guard 2>/dev/null || true
        rm -f /lib/systemd/system/MichaelVpn.service
        rm -f /lib/systemd/system/vpngate-one-guard.service
        systemctl daemon-reload
        # 清掉策略路由（tun 没了但 ip rule 还在，会劫持其它程序的流量）
        for t in $(seq 200 210) $(seq 100 110); do
            while ip rule del table "$t" 2>/dev/null; do :; done
            ip route flush table "$t" 2>/dev/null || true
        done
        rm -rf /opt/aimilivpn
        rm -f /usr/bin/ml
        rm -f /etc/sysctl.d/99-MichaelVpn.conf
        pkill -f "vpngate_one.py\|proxy_server.py\|vpngate_one_guard.py" 2>/dev/null || true
        echo -e "\033[0;32m卸载完成！\033[0m" ;;
    status)
        echo "=== MichaelVPN One ==="
        panel_api /api/status | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('面板: %s  %s' % (d.get('ui_scheme','http').upper(),
                       d.get('ui_tls_source','') or '-'))
for c in d['channels']:
    s=c['state']; co=c.get('node_country') or '-'; ip=c.get('node_ip') or '-'
    print(f'CH{c[\"index\"]}: {s:15s} {co:20s} IP={ip:16s} :{c[\"proxy_port\"]}  tun={c[\"tun\"]}')
print(f'--- {d[\"node_count\"]} nodes ---')" 2>/dev/null || systemctl status MichaelVpn --no-pager ;;
    guard)   systemctl status vpngate-one-guard --no-pager ;;
    logs)    journalctl -u MichaelVpn --no-pager -n 50 -f ;;
    guardlogs) journalctl -u vpngate-one-guard --no-pager -n 50 -f ;;
    passwd|改密)
        shift
        if [ $# -eq 0 ]; then
            echo "用法: ml passwd <新密码>              只改密码"
            echo "      ml passwd <新账号> <新密码>    同时改账号和密码"
            echo "      (更推荐登录面板 → 右上角\"管理员\"里修改)"
            exit 1
        fi
        python3 /opt/aimilivpn/vpngate_one.py --set-credentials "$@" || exit 1
        systemctl restart MichaelVpn 2>/dev/null
        systemctl restart vpngate-one-guard 2>/dev/null ;;
    *)       echo "用法: ml {start|stop|restart|status|info|guard|logs|guardlogs|passwd|uninstall}" ;;
esac
MLEOF
    chmod +x /usr/bin/ml
    echo -e "${GREEN}  OK${NC}"
}

configure_network() {
    echo -e "${CYAN}配置网络...${NC}"
    cat > /etc/sysctl.d/99-${SERVICE_NAME}.conf << 'SYSCTLEOF'
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
SYSCTLEOF
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 2 > "$f" 2>/dev/null || true; done
    echo -e "${GREEN}  OK${NC}"
}

# === 只补装/更新守护服务 ===
# 为了一个 systemd 单元重跑整套安装（会重装依赖、重拉代码）并不合适，
# 这个入口只写单元 + 起服务，其它什么都不碰。
if [ "${1:-}" = "--guard-only" ] || [ "${1:-}" = "guard-only" ]; then
    echo -e "${CYAN}补装守护服务 ${GUARD_SERVICE}${NC}"
    if [ ! -f "$INSTALL_DIR/vpngate_one_guard.py" ]; then
        echo -e "${RED}找不到 $INSTALL_DIR/vpngate_one_guard.py —— 请先完整安装一次${NC}"
        exit 1
    fi
    if [ "${ML_NO_GUARD:-0}" = "1" ]; then
        echo -e "${YELLOW}ML_NO_GUARD=1，跳过守护服务${NC}"
        exit 0
    fi
    install_guard_service
    systemctl restart ${GUARD_SERVICE} 2>/dev/null || systemctl start ${GUARD_SERVICE} 2>/dev/null || true
    sleep 2
    if systemctl is-active ${GUARD_SERVICE} &>/dev/null; then
        echo -e "${GREEN}守护已运行${NC}（假连接自动换节点；不主动轮换出口 IP）"
        echo -e "  日志: ${CYAN}journalctl -u ${GUARD_SERVICE} -f${NC}  或  ${CYAN}ml guardlogs${NC}"
    else
        echo -e "${YELLOW}守护未启动，查: journalctl -u ${GUARD_SERVICE} -n 30 --no-pager${NC}"
        exit 1
    fi
    exit 0
fi

echo -e "${CYAN}============================"
echo "  MichaelVPN One 部署（单通道 / 单端口）"
echo "============================${NC}"
detect_distro
install_deps

# 从 6 端口版原地切过来时，先把旧服务、旧路由表清掉：
# 旧表里指向 tun1~tun5 的 ip rule 留着，会把本机流量引到不存在的设备上。
echo -e "${CYAN}[0/6] 清理旧版本残留...${NC}"
stop_everything
cleanup_policy_routing
echo -e "${GREEN}  OK${NC}"

deploy_code
install_service
install_guard_service
install_ml
configure_network

echo ""
echo -e "${GREEN}部署完成！启动服务...${NC}"
systemctl start ${SERVICE_NAME} 2>/dev/null || true
sleep 3
systemctl is-active ${SERVICE_NAME} &>/dev/null && echo -e "${GREEN}面板运行中${NC}" || echo -e "${YELLOW}检查: systemctl status ${SERVICE_NAME}${NC}"
[ "${ML_NO_GUARD:-0}" = "1" ] || systemctl start ${GUARD_SERVICE} 2>/dev/null || true
PUBLIC_IP=$(curl -s --connect-timeout 5 api64.ipify.org 2>/dev/null || curl -s --connect-timeout 5 api.ipify.org 2>/dev/null || echo "<公网IP>")

# 面板是 http 还是 https，直接问面板自己（它按机器上有没有现成证书决定），
# 不要在这里猜 —— 猜错了用户点开就是打不开。
PROBE=$(curl -sk --max-time 8 https://127.0.0.1:8787/api/status 2>/dev/null)
[ -z "$PROBE" ] && PROBE=$(curl -s --max-time 8 http://127.0.0.1:8787/api/status 2>/dev/null)
SCHEME=$(printf '%s' "$PROBE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ui_scheme','http'))" 2>/dev/null || echo http)
CERT_DESC=$(printf '%s' "$PROBE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ui_tls_source',''))" 2>/dev/null || echo "")

# NAT 机判定：有内网地址、且它不是唯一地址时，基本可以确定端口要靠商家映射
LANIP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
        | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -1)

echo ""
echo -e "  Web UI:    ${CYAN}${SCHEME}://${PUBLIC_IP}:8787/${NC}"
if [ "$SCHEME" = "https" ]; then
    echo -e "  面板证书:  ${CYAN}${CERT_DESC:-未知}${NC}"
    echo -e "             ${YELLOW}自签证书浏览器会提示不安全，点\"继续访问\"即可；${NC}"
    echo -e "             ${YELLOW}想换成受信任的证书：把它放到 /usr/local/s-ui/cert/ 后重启面板${NC}"
fi
echo -e "  默认账号:  ${CYAN}admin${NC}"
echo -e "  默认密码:  ${CYAN}admin${NC}"
echo -e "  ${YELLOW}请登录后点右上角\"管理员\"立即修改账号和密码${NC} (改完需重新登录)"
echo -e "  忘记密码:  ${CYAN}ml passwd <新密码>${NC}  或  ${CYAN}ml passwd <新账号> <新密码>${NC}"
echo -e "  代理端口:  ${CYAN}7928${NC} (SOCKS5 + HTTP 共用，绑 0.0.0.0，tun0)"
echo -e "  测速端口:  ${CYAN}7929${NC} (只监听回环，不需要映射)"
echo -e "  策略路由:  ${CYAN}table 200~201${NC} (卸载时自动清理)"
if [ -n "$LANIP" ]; then
    echo ""
    echo -e "  ${YELLOW}检测到内网地址 ${LANIP}：这台机器大概率是 NAT 机，端口要靠商家映射${NC}"
    echo -e "  ${YELLOW}在商家面板把公网端口映射到 ${LANIP} 的 7928（面板 8787 同理）${NC}"
    echo -e "  ${YELLOW}客户端里填：公网 IP + 商家给的端口 + 下面的代理账号密码${NC}"
fi
echo -e "  连接信息:  ${CYAN}ml info${NC}"
echo -e "  状态:      ${CYAN}ml status${NC}"
echo -e "  日志:      ${CYAN}ml logs${NC}"
if [ "${ML_NO_GUARD:-0}" = "1" ]; then
    echo -e "  守护:      ${YELLOW}未安装 (ML_NO_GUARD=1)${NC}"
else
    systemctl is-active ${GUARD_SERVICE} &>/dev/null \
        && echo -e "  守护:      ${GREEN}已运行${NC} (假连接自动换节点，不主动轮换 IP)" \
        || echo -e "  守护:      ${YELLOW}已安装但未运行, 查: ml guard${NC}"
fi
echo -e "  卸载:      ${CYAN}ml uninstall${NC}"
echo ""
echo -e "  ${GREEN}代理连接（客户端里填这组，无认证）${NC}"
echo -e "  ┌─────────────────────────────────────────────"
echo -e "  │ 地址: 127.0.0.1  (本机/内网) 或 你的公网映射"
echo -e "  │ 端口: 7928  (SOCKS5 / HTTP)"
echo -e "  │ 认证: 无（和 6/9 通道版一致）"
echo -e "  └─────────────────────────────────────────────"
