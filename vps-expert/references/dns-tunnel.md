# DNS 与隧道

目录:1. DNS 排查 · 2. 客户端 DNS 泄漏与分流 · 3. 流媒体/AI 解锁 DNS 的取舍 · 4. WireGuard 隧道要点 · 5. 端口转发与中转 · 6. 隧道 MTU

只覆盖自己主机/自己网络内的 DNS 与隧道。语法类稳定知识可直接答;"某商家/某解锁服务当前是否可用"属于需场景证据,走 `community-research.md`。

## 1. DNS 排查

```bash
cat /etc/resolv.conf
resolvectl status 2>/dev/null | head -30      # systemd-resolved 系统
dig +short example.com                         # 没有 dig:apt install dnsutils / yum install bind-utils
dig +short example.com @1.1.1.1                # 指定上游对比
dig +trace example.com | tail -20              # 从根逐级查,定位哪一级出问题
```

- 指定上游能解析、默认不能 → 本机/商家 DNS 有问题,改 resolver 或上游。
- 都不能 → 先查网络连通(`triage-commands.md`),别在 DNS 上打转。
- `/etc/resolv.conf` 可能由 systemd-resolved、NetworkManager 或云初始化覆盖;**改之前确认谁在管它**,否则重启后失效。
- 机房 DNS 偶发慢:换就近的公共 DNS 并实测 `dig` 耗时(`Query time`)。
- 如果打算用第三方/公共/"解锁"DNS 当解决办法,先读第 3 节:它会把部分流量交给第三方,可用性也不能承诺。

## 2. 客户端 DNS 泄漏与分流

- 国内域名走国内 DNS、海外域名走代理侧 DNS,是最常见的防泄漏做法;具体字段取决于客户端(Clash/sing-box),以其当前文档为准。
- 判断是否泄漏:在客户端开代理后访问 DNS 泄漏检测站,看显示的解析服务器是不是本地运营商。
- 代理侧不要在服务端对海外域名再套一层不必要的 DNS 转发,能少一跳就少一跳。
- 排查"DNS 被污染"时给出的任何第三方 DNS 方案,都要同时说明:流量会经过第三方、该方案是否仍有效属时效性问题(未核对前标 `[UNKNOWN]`)。

## 3. 流媒体/AI 解锁 DNS 的取舍

- "解锁 DNS / 分流"通常是把特定域名的解析指到第三方机器;好处是简单,风险是**把部分流量交给不可控的第三方**,且解锁状态随时变。
- 建议:优先用自己的出口(换 IP / 原生 IP 落地机);必须用第三方时,告知用户风险、只对必要域名生效、定期复测。
- 是否可用是时效性问题,不凭记忆承诺。
- 解锁流媒体/AI 可能违反对应服务的 ToS 或地区授权,风险由用户自担;只讲连通与复测方法,不教规避账号风控、批量养号或绕过地区授权校验。

## 4. WireGuard 隧道要点

用途:把两台机器(如落地机与中转机、家里与 VPS)打通。语法与行为稳定,可直接答,但**密钥不要贴到公开场合**。

```bash
umask 077
wg genkey | tee privatekey | wg pubkey > publickey
```

最小骨架(`/etc/wireguard/wg0.conf`,占位符自行替换):

```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <本机私钥>

[Peer]
PublicKey = <对端公钥>
AllowedIPs = 10.8.0.2/32
```

```bash
chmod 600 /etc/wireguard/wg0.conf   # 含私钥,权限过宽 wg-quick 会警告
ufw allow 51820/udp                # 与 ListenPort 一致(监听端);云厂商安全组也要放行这个 UDP 端口
wg-quick up wg0
wg show                      # 看 latest handshake,有时间说明握手成功;没有就先查本机防火墙和云安全组是否放行 UDP,再查密钥/Endpoint/AllowedIPs,最后才怀疑 UDP QoS
systemctl enable wg-quick@wg0
```

- 对端在 NAT 后:对端加 `PersistentKeepalive = 25`。
- 做全局转发要开 `net.ipv4.ip_forward=1` 并配置 NAT/防火墙;**先确认商家允许转发流量**。把 `AllowedIPs` 设为 `0.0.0.0/0`(全局隧道)会改写默认路由,可能切断你自己的 SSH 会话。**全局隧道的必做清单**:
  1. 先确认有控制台/VNC。
  2. `wg-quick up` 之前加定时自救:`systemd-run --on-active=5m --unit=wg-rollback wg-quick down wg0`。
  3. 为 SSH 来源地址保留直连路由:`ip route add <SSH来源IP>/32 via <原网关> dev <原网卡>`(也可写进 wg0.conf 的 `PostUp`)。
  4. 新开一个 SSH 会话验证成功后,取消自救:`systemctl stop wg-rollback.timer`。
  5. 验证通过之前**不要** `systemctl enable wg-quick@wg0`,否则配置有问题时每次重启都会再锁一次。
- UDP 在部分网络/时段会被 QoS:**握手正常**但速度异常时,才对比 TCP 方案(见 `proxy-recipes.md`)。
- 全局转发还需要 ufw 的转发规则和 NAT,见第 5 节。

## 5. 端口转发与中转

- 转发方式选型、链路设计、加密隧道与是否上中转的判断,见 `proxy-recipes.md` §6;本节只补系统层细节。
- 开启转发:`sysctl net.ipv4.ip_forward` 要为 1;确认防火墙放行转发链,别只放行 INPUT。
- **用 ufw 的机器有个坑**:`/etc/ufw/sysctl.conf` 默认把 `net/ipv4/ip_forward` 注释掉(不设置),真正默认挡住转发的是 `/etc/default/ufw` 里的 `DEFAULT_FORWARD_POLICY="DROP"`。**保持 `DROP`,只放行你要的那条路径**:
  1. 取消注释 `/etc/ufw/sysctl.conf` 里的 `net/ipv4/ip_forward=1`(ufw 启用/重载时会应用它,若 `sysctl.d` 里设了不同值,以后应用者为准)。
  2. 放行从隧道口到外网口的转发:`ufw route allow in on <wg接口> out on <外网网卡>`。
  3. NAT/MASQUERADE 写在 `/etc/ufw/before.rules` 文件开头(`*filter` 之前)的 `*nat` 段:

```
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.8.0.0/24 -o <外网网卡> -j MASQUERADE
COMMIT
```

  4. `ufw reload`,用 `sysctl net.ipv4.ip_forward` 验证。
  - `DEFAULT_FORWARD_POLICY="ACCEPT"` 只是最后手段:它会让整台机器在所有网卡之间(公网口、wg0、Docker 网桥)无过滤转发,公网 VPS 会变成开放路由器。

## 6. 隧道 MTU

隧道会增加封装头,MTU 要预留空间(WireGuard 常见做法是把接口 MTU 设得低于物理 MTU,具体数值用 `ping -M do -s` 实测,见 `tuning-playbook.md` 第 5 节)。症状:小请求正常、大响应卡住 → 先怀疑 MTU/MSS。
