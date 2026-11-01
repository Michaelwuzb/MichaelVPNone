# MichaelVPN One

> 基于 VPNGate 的**单通道**独立出口 VPN 网关（MichaelVPN One）
> 一台机器只跑一条 OpenVPN 隧道、一个虚拟网卡(tun0)、一个代理端口、一个出站 IP，
> 专门为 **NAT 机 / 小内存 VPS** 设计 —— 只需映射一个公网端口即可使用。

---

## 🚀 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Michaelwuzb/MichaelVPNone/main/install.sh)
```

安装后访问 `https://<IP>:8787/` 进入管理面板。

面板**默认就走 HTTPS**：优先复用这台机器上已有的证书（s-ui / acme.sh / Let's Encrypt / 宝塔
的证书都认），找不到才自签一份。自签时浏览器会提示"不安全"，点继续访问即可；
想用受信任的证书，见下方 [面板 HTTPS](#-面板-https) 一节。

默认账号密码从 `ui_auth.json` 读取，可在 `/opt/aimilivpn/vpngate_data/ui_auth.json` 中修改。

### NAT 机重点：只需要映射一个端口

单通道版整机只对外提供 **1 个代理端口（默认 7928，SOCKS5 + HTTP 共用）**，绑在
`0.0.0.0`。NAT 机（无独立公网 IP 的家宽 / 中转机）只要在商家面板把公网端口映射到
内网机器的 `7928` 即可，客户端直接连这个映射出来的公网地址。

面板 `8787` 同理（不想暴露就不映射，通过内网或跳板访问）。

---

## 🗑️ 一键卸载

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Michaelwuzb/MichaelVPNone/main/install.sh) uninstall
```

卸载所有文件、服务、策略路由表和 TUN 设备。

---

## 💡 快速使用

### 1. 登录管理面板

浏览器打开 `https://<IP>:8787/`，输入账号密码登录。
（面板默认 HTTPS；如果你显式关掉了 TLS，那就是 `http://`，看下面那节。）

### 2. 获取节点

点击 **获取节点** 按钮拉取 VPNGate 可用节点。

### 3. 连接出口

面板上只有一个通道卡片（`tun0` / 端口 `7928`）：

- 选好国家 + IP 类型（住宅/机房/移动）→ 点击 **连接**
- 或从下方节点表直接点 **切换**
- 顶部**连接信息**徽标会显示 `SOCKS5/HTTP  0.0.0.0:7928`，**点一下即复制**，直接填进客户端
  （默认无认证，和 6/9 通道版一致；只有手动开了 `proxy_auth.json` 才会显示账号密码）

### 4. 使用代理

| 通道 | tun | 代理端口 | SOCKS5 |
|------|-----|---------|--------|
| CH0 | tun0 | 7928 | socks5://<IP>:7928 |

> **7929 是「测带宽」的内部专用口**（tun1）：只监听 127.0.0.1、面板上不显示，
> 仅在节点实测期间临时建隧道用。它不对外提供服务，防火墙不用管它。

```bash
# 示例：让本机命令走这个代理（出口为所选国家）
export http_proxy=http://127.0.0.1:7928
export https_proxy=http://127.0.0.1:7928
curl ifconfig.me   # 显示所选国家的 IP
```

---

## 🎛️ 管理命令

```bash
ml status   # 查看通道状态（会自动按 http/https 探测面板）
ml restart  # 重启面板 + 守护
ml logs     # 查看面板实时日志
ml guard    # 查看守护服务状态
ml guardlogs# 查看守护实时日志
ml stop     # 停止面板 + 守护
ml start    # 启动面板 + 守护
ml passwd <新密码>            # 改面板密码（忘记密码时的救援入口）
ml passwd <新账号> <新密码>    # 同时改面板账号和密码
```

---

## ⚙️ 核心功能

### 单通道出口管理

- 一条 OpenVPN 隧道，独立虚拟网卡 `tun0`
- 一个 HTTP/SOCKS5 代理端口 `7928`（绑 `0.0.0.0`，NAT 映射直接用）
- 另有一个**测速专用口 7929 / tun1**：只给「测带宽」用，面板上不显示、不影响正式出口
- 独立策略路由表，不会劫持本机其它程序的流量

### 出口节点选择

通道卡片上有**国家/地区下拉**，选好之后点「连接」，设置写入 `channels.json`，重启后依然生效。

**默认跳过中国节点**：VPNGate 上的 CN 节点基本都是境内志愿者家宽，拿它当境外出口没有意义。
改法：`VPNGATE_EXCLUDE_COUNTRIES=china,xxx`（留空表示不排除）。

### 精确到县 / 都道府县（再往下细分一层）

「选择国家」是国家级。如果连**国家内部**的位置都要卡住 ——
比如出口 IP 必须在**日本东京都**，而不是"日本随便哪里" —— 用这一层。

VPNGate 的节点列表里**只有国家级**（`CountryLong=Japan`），没有更细的行政区，
所以这一层是靠 IP 情报（ip-api 的 `region` / `regionName` / `lat` / `lon`）补出来的：

- 日本用 **JIS 都道府县码**做匹配键（`JP-01`~`JP-47`），与语言无关；面板显示中文名，
  手输 `东京` / `東京都` / `Tokyo` / `Tokyo-to` / `13` / `JP-13` 都认
- 每个县都带**县厅坐标**，节点带 IP 经纬度，"就近"是算出来的球面距离，不是猜的
- 其它国家（美国州、韩国道…）没有预置表，就用 `国家码:区名` 当键，并用同区节点的平均坐标估中心点

**降级顺序（关键行为）**

选了「东京都」之后，不是只能全中或者全失败，而是按这个顺序自动往下走：

```
① 东京都内有可用节点           -> 用东京都
② 东京都"看起来"没节点了       -> 先重扫一次当前地区（见下）：
                                 拉到新上线的东京都节点就继续留在东京都，不降级
③ 重扫后确认真的没货           -> 固定顺序递补：埼玉县 -> 神奈川县 -> 千叶县 -> 山梨县
④ 名单也走完                   -> 同一大区（关东：茨城/栃木/群马）里按距离由近到远
⑤ 关东也没了                   -> 全国按距离由近到远（大阪 395km、冲绳 1554km……）
⑥ 日本全池都没可用节点         -> 放宽到其它国家（原有行为，不会卡死）
```

> 每一步里的"可用节点"都按你选的「出口 IP 类型」算：选了**住宅**，机房节点在这一整条
> 链路上都不存在（不算有货、不会被选中）。

**降级之后不会切回去**

一条通道一旦因为目标县没节点退到了别处（比如埼玉），后端的 `region_lock` 就记下这个县：

- 通道掉线重连时**先回那个县**，即使东京都又冒出新 IP 也不切回（`region_lock` 落盘，重启后依然生效）
- 那个县也没货了，就沿固定顺序继续往后（神奈川 -> 千叶 -> 山梨 -> 关东 -> 全国），仍然不回东京都
- 只有整条链都没货、只剩东京都时才回去
- 你在面板上重新指定县时，锁定自动失效，按新目标重新算

这样的目的是**不让出口 IP 反复跳**：东京都节点时有时无，如果每次恢复都切回去，
业务侧看到的出口 IP 会一直在变。

**节点失效才换，同城优先（不做定时轮换）**

- 不会定时跳 IP：守护 `VPNGATE_ROTATE_EVERY=0`（默认关掉定时轮换），唯一换节点的情况就是「当前这个 IP 真的不能用了」
- 换的时候**首选同一城市**（都道府县）：城市里还有可用 IP，就留在原地不动
- 城市里真没了才按固定顺序 / 由近到远就近换

**指定「住宅 IP」后，机房 IP 不参与降级**

VPNGate 上很多节点是跑在 VPS 上的机房 IP（SoftEther 机房）。「出口 IP 类型」选了
**住宅** 之后，机房节点不是"备胎"，而是**直接不参与**：

```
住宅模式判断"东京都还有没有货"时：
  东京都 3 个机房 + 0 个住宅  ->  等于没货（不是"还有 3 个"）
     -> 先重扫东京都（只算住宅） -> 还是没有 -> 埼玉 -> 神奈川 -> 千叶 -> 山梨 -> 关东 -> 全国
     -> 全日本都没有住宅 -> 放宽到其它国家，但**仍然只要住宅**
     -> 全站都没有住宅 -> 报"没有可用的住宅节点"，通道保持原状，**不拿机房顶上**
```

IP 类型不会再被悄悄改掉：旧实现在"该县没有这个类型"时会**静默放宽成全类型**，
于是「我明明设了住宅，出口却是机房」。现在这种"放宽"只可能发生在**国家**这一层。

### 节点管理与筛选
- **全部节点 / 只看新节点 / 可用节点 / 失效节点 / 已实测 / 未实测** 筛选
- **国家筛选**：日本、韩国、美国、泰国等；选定国家后**县/州筛选**会跟着变成该国的行政区
- **IP类型筛选**：住宅IP / 机房IP / 移动网络
- **排序**：最新发现优先 / 实测延迟最低 / 实测带宽最高 / 官方速度最高
- 每个节点显示：物理位置、**县/州**、运营主体(ISP)、ASN、IP类型、**实测延迟、官方速度、实测带宽、发现时间**
- IP类型旁边鼠标悬停可看到**判定依据**

### 新节点标记（刷新出来的新节点会被标出来）
- 后台每 `FETCH_INTERVAL`（默认 600 秒）刷新一次节点池，**首次见到的节点会记下时间**，
  在表格里给它打上绿色「新」徽标 + 浅绿底行
- 「发现时间」列显示每个节点是多久之前第一次出现的；筛选 **只看新节点** 可把这一轮新上线的挑出来
- 首现记录落在 `vpngate_data/nodes_seen.json`，**重启不会丢**
- 默认 **24 小时**内算新（`NEW_NODE_TTL_HOURS` 可调）；看腻了点 **清除新标记** 一键清掉
- 顶部「节点: N · 新 M」直接显示当前有多少个新节点

### 节点测速

面板上有三个入口，测的东西完全不同，别混：

| 入口 | 测什么 | 怎么测 | 影响 |
|---|---|---|---|
| 节点表 **测延迟** | 节点 IP:端口 的 TCP 握手 RTT | 32 并发直连探测，**零流量** | 不碰任何通道，几秒~几十秒 |
| 节点表 **测带宽** | 真实下载带宽 | 用**测速专用口**（7929 / tun1）建隧道，经它实测下载 | 不占用正式通道 |
| 通道卡片 **测速** | 该通道当前出口的真实带宽 | 直接走这条通道自己的 SOCKS 口，不用另建隧道 | 只影响该通道，十几秒 |

- **测带宽**：先在表格里勾选节点（不勾选则默认测「新节点」，单次最多 20 个）。任务串行跑，
  进度条显示第几个 / 总共几个 / 正在测哪个 IP，随时可点 **停止** 收工
- 测带宽走**专用测速口**：端口就是正式端口之后的 7929，配一条独立的 tun1。
  它不在 `channels` 里，因此**面板上不会多出一条通道**、不写进 `channels.json`、
  也不受看门狗管
- 实测结果写回节点表并落盘，**下一轮节点刷新不会把它冲掉**；失败的节点记下失败原因
- 三列数字怎么读：
  - **实测延迟** —— 从这台服务器到节点 IP 的真实 RTT。比官方 Ping 字段靠谱（官方那个是从日本测的）
  - **官方速度** —— VPNGate 在节点上线时测的带宽，仅作参考，经常严重虚高
  - **实测带宽** —— 真拿这条隧道下载跑出来的速度，**这个才是能不能用的依据**

### IP 信息富集
- 物理位置（国家、地区、城市）
- 运营主体 / ISP（如 KDDI、SoftEther、LG Uplus）
- IP 类型（住宅、机房、移动、**未知**）+ **置信度**（高 / 中 / 低）
- 数据来源：ip-api.com + 本地 PTR 反查

> **IP 类型是怎么判的（重要）**
>
> 不能直接用 ip-api 的 `hosting` / `proxy` 字段：
> - `proxy=true` 只说明"这是个 VPN/代理出口"。VPNGate 的节点**不论宿主是家宽还是机房，这个字段几乎都是 true**，拿它当机房判据会把 SoftBank、KT 这些家宽全部误标成"机房IP"。
> - `hosting` 字段漏报严重。
>
> 所以本项目改为「ASN/机构关键词 + PTR 反向域名特征」为主：
> 1. 先看 ASN/ISP/机构名里的移动运营商特征 → 移动（置信度**高**）
> 2. 再看云/机房/IDC 特征（digitalocean、softether、hosted、hosting…）→ 机房（**高**）
> 3. 再看消费级宽带运营商特征（softbank、kddi、korea telecom、virgin media…）→ 住宅（**高**）
> 4. 关键词判不出来的，再做一次 PTR 反查，看是不是 `*.bbtec.net`、`*.dynamic.*`、`*-pool-*` 这类家宽/动态池特征 → 住宅/机房（**中**）
> 5. 都没有时才退回 ip-api 的 hosting/mobile 标记（**中**）
> 6. **还是没有依据 → 标成「未知」+ 低置信度，不再假装是住宅**
>
> **「未知」只是没判出来，不影响节点可用性，也不影响不指定类型时的自动分配。**
> 判定规则在 `vpn_utils.py` 顶部的关键词表里，想加自己的 ISP 直接往对应元组里塞就行；
> 改完把 `_CLS_VER` 加一，旧缓存会自动失效并重新查询。

### 面板 HTTPS

面板**默认启用 HTTPS**。证书按这个顺序找，找到哪个用哪个：

1. **你在 `ui_tls.json` 或环境变量里显式指定的** `cert` / `key`
2. **这台机器上现成的证书**，按下面的顺序扫：
   - `/usr/local/s-ui/cert/` ← **s-ui 默认就在这**
   - `/root/.acme.sh/<域名>[_ecc]/`（acme.sh）
   - `/etc/letsencrypt/live/<域名>/`（certbot）
   - `/www/server/panel/vhost/cert/<域名>/`（宝塔）
   - Xray / sing-box / v2ray-agent 的证书目录、`/root/cert/`
3. 都没有 → 用 `openssl` **自签**一份，放 `vpngate_data/ui_cert/`（有效期 825 天，临期自动重签）

几个已经处理掉的坑：

- **不碰别人的证书**：只读。自签产物只写在自己的目录里
- **过期和公私钥不匹配的证书会被跳过**
- **`.key` / `chain.pem` 这类文件不会被误当成证书**
- 复用 s-ui 的证书 = 你那个域名的证书直接生效，浏览器是绿的；**续期后不用重启、不用配 hook**
  （面板每 60 秒自检证书文件的 mtime/size，变了就热重载 SSLContext，隧道不断）
- 面板跑 HTTPS 时，`ml status` / `ml logs` / 守护脚本都会**自动切到 https**

想让面板换个域名的证书，或者干脆用回明文：

```bash
vi /opt/aimilivpn/vpngate_data/ui_tls.json
```
```json
{
  "enabled": "auto",
  "cert": "/usr/local/s-ui/cert/fullchain.pem",
  "key": "/usr/local/s-ui/cert/privkey.pem"
}
```

| 配置项 | 环境变量 | 说明 |
|---|---|---|
| `enabled` | `VPNGATE_UI_TLS` | `auto`（默认，等价于"能上就上"）/ `off`（强制明文 http） |
| `cert` / `key` | `VPNGATE_UI_CERT` / `VPNGATE_UI_KEY` | 指定证书和私钥路径，优先级最高 |
| `domain` | `VPNGATE_UI_DOMAIN` | 自签时用的域名（默认取本机 FQDN） |
| `cert_dirs` | `VPNGATE_UI_CERT_DIRS` | 追加扫描目录（逗号分隔） |
| — | `VPNGATE_UI_TLS=off` | 关掉 HTTPS，回到明文 http |

### 只接受域名访问（IP 直连返回 403）

面板跑的是**域名证书**时：

- 用的是**公共 CA 签发的域名证书**时，面板**自动只放行证书里的域名**（含 SAN 里的每个域名）
- 用 IP、或用不在证书里的域名访问 → 直接 **403**
- **回环永远放行**（`127.0.0.1` / `::1` / `localhost`）
- 用**自签证书**或没开 HTTPS 的部署**不限制**（IP 访问正是自签场景的刚需）

管理员确实需要用 IP 打开时（比如域名解析还没生效）：

```bash
touch /opt/aimilivpn/vpngate_data/allow_ip_host   # 立即生效，不用重启
rm /opt/aimilivpn/vpngate_data/allow_ip_host      # 立即重新收紧
```

### 安全登录
- 账号密码认证，密码以 **PBKDF2-SHA256 哈希**存储（旧版明文会在首次启动时自动升级）
- Cookie 会话管理（24小时有效期）
- **GET 与 POST 接口都校验会话**（写操作未登录一律 401）
- 登录失败限速：同一 IP 连续 5 次失败锁定 5 分钟

### 修改管理账号 / 密码
登录面板 → 右上角 **管理员**：
- **当前账号 + 当前密码**：校验身份
- **新账号**（留空不改）：3~32 位，仅字母/数字/`_`/`.`/`-`
- **新密码**（留空不改）：至少 8 位，不能与账号相同、不能是常见弱口令

忘记密码时在服务器上执行：
```bash
ml passwd <新密码>              # 只改密码
ml passwd <新账号> <新密码>      # 账号密码一起改
```

> **代理口认证（默认关闭）**：单通道版把 7928 绑在 `0.0.0.0`（NAT 映射要求），所以**默认无认证**，
> 和 6/9 通道版一样，`127.0.0.1:7928` 直接连即可。只有当你要把 7928 映射到公网、担心被白嫖时，
> 才需要手动补一份认证，方法见 `install.sh` 里的注释（生成 `vpngate_data/proxy_auth.json` 后重启）。
> 一旦存在 `proxy_auth.json`，面板顶部「连接信息」徽标就会显示账号密码，点一下复制。

### 稳定性机制

- **连接就绪判定**：标记"已连接"之前依次确认 —— 隧道能通 → 策略路由真的写进内核 →
  本地代理端口真的在监听。原来只验隧道就宣布已连接，存在一个"面板说已连接、流量却从物理网卡直接出去"的窗口期
- **端口预检**：启动时先把面板口 + 代理口 + 测速口都探一遍，日志里直接列出冲突
- **只清理自己的进程**：启动时按「命令行里含本程序配置目录路径」精确匹配残留 openvpn，
  不会误杀这台机器上别的 openvpn
- **卸载清干净策略路由**：卸载时清空本程序用的 `ip rule` / `ip route`。
  tun 设备会随进程消失，但规则会留在内核里继续劫持其它程序的流量
- **节点源多级回退**：官方 HTTPS → 官方 HTTP → 本地快照，源站被墙时仍能用上次那批节点建隧道

---

## ⚠️ 常见问题

### Web UI 无法访问
- **先确认协议**：面板默认是 `https://<IP>:8787/`。用 `http://` 打开会连不上
- 自签证书被浏览器拦下时，点"继续访问"
- 想换回明文：`VPNGATE_UI_TLS=off`，或 `ui_tls.json` 里 `"enabled": false`
- 检查防火墙：`ufw allow 8787/tcp && ufw allow 7928/tcp`
- 云服务商安全组放行 8787、7928 端口（NAT 机则映射这两个口）

### 节点列表为空
- 取节点是**多级回退**：官方 HTTPS → 官方 HTTP → 本地快照。
  每次成功拉取都会存一份到 `vpngate_data/nodes_snapshot.json`
- 面板顶部状态栏出现「· 用的是本地快照」就是在走回退
- 真的一个节点都没有时：检查 DNS `echo "nameserver 8.8.8.8" > /etc/resolv.conf`，
  或手动点 **获取节点**

### 通道显示"已连接"，但连上去没网 / 出口 IP 不对
- 标记"已连接"之前会依次确认：隧道能通、策略路由写进内核、代理端口在监听。
  任何一项不过就落到 `error` 并写明原因
- 卡片上出现红色的「代理 :端口 未监听」，说明端口被别的程序占着。
  换端口或停掉占用方后重启服务

### 忘了面板账号 / 密码
```bash
ml passwd <新密码>              # 只改密码
ml passwd <新账号> <新密码>      # 账号密码一起改
```

### 改完账号密码后，守护脚本会失效吗
不会。守护脚本用的是独立的 `vpngate_data/guard_token`，改面板凭据、清会话都不影响它。

### IP类型显示不准（比如家宽被标成"机房"）
- 已修复根因：旧版把 ip-api 的 `proxy=true` 当成机房判据
- 现在按机构关键词 + PTR 判定，判定依据和**置信度**显示在面板上
- **看到"未知"是正常的**：不影响节点可用性，也不影响不指定类型时的自动分配
- 某个小众运营商仍判错时：在 `vpn_utils.py` 的 `RESIDENTIAL_ISP_KEYS` / `HOSTING_KEYS` 里补关键词，然后把 `_CLS_VER` 加一
- 想立刻强制重判：删掉 `/opt/aimilivpn/vpngate_data/ip_cache.json`，再点面板"刷新"

### TUN/TAP 设备错误
- LXC/OpenVZ VPS 需要在控制面板启用 TUN/TAP

---

## 📦 文件结构

```
/opt/aimilivpn/
├── vpngate_one.py          # 单通道管理器 + 节点管理 UI
├── proxy_server.py         # 代理（SOCKS5 + HTTP）
├── vpn_utils.py            # IP信息富集（类型判定 + 行政区/坐标）
├── region_geo.py           # 行政区定位：日本 47 都道府县表 + 别名归一 + 球面距离
├── ui_tls.py               # 面板 HTTPS：证书发现 / 自签
├── speedtest_utils.py      # 测速（SOCKS5 + HTTP 下载）
├── vpngate_one_guard.py    # 通道守护脚本（install.sh 自动装成服务）
├── install.sh              # 部署脚本
├── LICENSE                 # GPL-3.0 许可证全文
├── NOTICE                  # 来源、衍生关系与改造说明
├── tests/                  # 测试脚本（逻辑 / 前端 / 端到端，用法见 tests/README.md）
├── vpngate_data/
│   ├── login.html          # 登录页面
│   ├── ui_auth.json        # 管理账号 + 密码哈希（chmod 600）
│   ├── guard_token         # 守护脚本长效令牌（chmod 600）
│   ├── proxy_auth.json     # 代理口账号密码（默认不存在=无认证；映射公网时才手动加）
│   ├── ip_cache.json       # IP 信息缓存
│   ├── nodes_seen.json     # 节点首现时间记录
│   ├── nodes_snapshot.json # 上次成功拉取的完整节点（含配置）
│   ├── ui_tls.json         # 面板 HTTPS 配置（可选）
│   ├── ui_cert/            # 自签证书
│   └── nodes.json          # 节点缓存（含实测延迟 / 实测带宽）
```

> `nodes.json` 是给面板看的，刻意剥离了节点配置文本；`nodes_snapshot.json` 才带配置，
> 回退时拿到它才能建隧道。两者不要混用。

---

## 🧬 来源与许可

本仓库是 [`baoweise-bot/aimili-vpngate`](https://github.com/baoweise-bot/aimili-vpngate)
的衍生作品（经 `Michaelwuzb/aimili-vpngate` 中转），上游以 **GPL-3.0** 发布；
本仓库在此基础上做了「6 通道 → 单通道」的 NAT 机精简改造，同样以 **GPL-3.0-or-later** 分发，
完整文本见 `LICENSE`，衍生关系与改造清单见 `NOTICE`。

---

## 📢 社区

- Telegram: [@arestemple](https://t.me/arestemple)

---

## 🛡️ 通道守护脚本 (vpngate_one_guard.py)

自动保活通道：定时检查，发现 `error` / 假连接（connected 但 socks5 实测无流量）自动换节点重连。

### 安装

**不用手动装** —— `install.sh` 会自动把守护写成 `vpngate-one-guard.service` 并启动，
排在被守护的面板服务之后启动，崩溃无限重启：

```bash
ml guard      # 看守护状态
```

不想装就在安装时加个开关：

```bash
ML_NO_GUARD=1 bash install.sh
```

> 卸载（`ml uninstall`）会自动停掉并删掉它。

### 行为说明

- 每 60 秒检查一轮通道
- **假连接检测**：面板显示 `connected` 但 SOCKS5 实测拿不到出口 IP → 连续 2 轮都拿不到才换节点
- **沿用面板里设置的国家 / IP 类型**，不再统一改成日本
- **掉线（state != connected）默认交给面板内置 watchdog 处理**，守护脚本只管"假连接"（定时轮换默认已关闭）
- **手动关闭的通道不会被动重连**
- **认证走面板生成的守护令牌** `/opt/aimilivpn/vpngate_data/guard_token`，
  所以**面板里改账号密码、清会话，都不会让守护失联**
- **代理端口直接取面板返回的 `proxy_port`**，不自己推算
- 同一通道两次重连之间有 `RECONNECT_COOLDOWN` 冷却，避免反复抖动
- **面板地址自动适配 http / https**
- 日志：`journalctl -u vpngate-one-guard -f`（或 `ml guardlogs`）

### 可调参数（脚本顶部 / 环境变量）

| 变量 | 默认 | 说明 |
|------|------|------|
| `CHECK_EVERY` | 60 | 检查间隔（秒） |
| `VPNGATE_ROTATE_EVERY` | **0** | 每 N 轮主动换节点切 IP；**0 = 不主动切** |
| `FAIL_TOLERANCE` | 2 | 连续 N 轮测不到流量才判定假连接 |
| `RECONNECT_COOLDOWN` | 120 | 同通道两次重连最小间隔（秒） |
| `HANDLE_DISCONNECTED` | False | 是否连"掉线"也由本脚本重连 |
| `PANEL` | 自动探测 | 面板地址 |
| `GUARD_TOKEN_FILE` | `/opt/aimilivpn/vpngate_data/guard_token` | 守护令牌 |
| `AUTH_FILE` | `/opt/aimilivpn/vpngate_data/ui_auth.json` | 兜底凭据文件 |

---

## 🔬 可调参数

给 `MichaelVpn.service` 加 `Environment=` 即可覆盖（改完 `systemctl daemon-reload && systemctl restart MichaelVpn`）。

| 变量 | 默认 | 说明 |
|------|------|------|
| `FETCH_INTERVAL` | 600 | 节点池刷新间隔（秒） |
| `NEW_NODE_TTL_HOURS` | 24 | 首现多久之内算"新节点"，`0` = 关闭 |
| `SEEN_KEEP_DAYS` | 30 | 首现记录保留天数 |
| `PING_WORKERS` | 32 | 延迟测试并发数 |
| `PING_TIMEOUT` | 3 | 单个节点 TCP 探测超时（秒） |
| `SPEEDTEST_MAX_NODES` | 20 | 单次批量测带宽的节点数上限 |
| `VPNGATE_SPEEDTEST_PORT` | 7929 | 「测带宽」专用口端口号 |
| `SPEEDTEST_URL` | `https://speed.cloudflare.com/__down?bytes={bytes}` | 测速目标地址 |
| `SPEEDTEST_BYTES` | 10000000 | 单次下载字节数（10MB） |
| `SPEEDTEST_TIMEOUT` | 30 | 单次测速最长耗时（秒） |
| `SPEEDTEST_WARMUP` | 0.6 | 丢掉开头这段再算稳定带宽 |
| `VPNGATE_POLICY_TABLE_BASE` | 200 | 策略路由表基准值 |
| `VPNGATE_PROXY_LISTEN` | 0.0.0.0 | 代理口监听地址（NAT 机用 0.0.0.0） |
| `VPNGATE_STRICT_TLS` | 1 | 设 `0` 关闭 `--remote-cert-tls server` |
| `VPNGATE_EXCLUDE_COUNTRIES` | `china` | 自动分配时跳过的国家 |
| `CONNECT_TIMEOUT` | 45 | 单次建隧道的等待上限（秒） |
| `WATCHDOG_INTERVAL` | 15 | 通道巡检间隔（秒） |
| `FAIL_TOLERANCE` | 3 | 连续 N 轮探测不通才重连 |
| `RECONNECT_COOLDOWN` | 90 | 同通道两次重连的最小间隔（秒） |
| `MAX_RECONNECT_BACKOFF` | 1800 | 通道**指数退避**上限（秒） |
| `NO_NODE_LOG_INTERVAL` | 1800 | "没有可用节点"告警的节流间隔（秒） |
| `NODE_SKIP_TTL` | 300 | 刚连不上的节点**短期跳过**时长（秒） |
| `NODE_SKIP_MAX` | 200 | 跳过表最多记录条数 |

---

*基于 baoweise-bot/aimili-vpngate 改造，精简为单通道 NAT 机专用版本*
