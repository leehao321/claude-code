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

## 2. 客户端 DNS 泄漏与分流

- 国内域名走国内 DNS、海外域名走代理侧 DNS,是最常见的防泄漏做法;具体字段取决于客户端(Clash/sing-box),以其当前文档为准。
- 判断是否泄漏:在客户端开代理后访问 DNS 泄漏检测站,看显示的解析服务器是不是本地运营商。
- 代理侧不要在服务端对海外域名再套一层不必要的 DNS 转发,能少一跳就少一跳。

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
wg-quick up wg0
wg show                      # 看 latest handshake,有时间说明握手成功
systemctl enable wg-quick@wg0
```

- 对端在 NAT 后:对端加 `PersistentKeepalive = 25`。
- 做全局转发要开 `net.ipv4.ip_forward=1` 并配置 NAT/防火墙;**先确认商家允许转发流量**。把 `AllowedIPs` 设为 `0.0.0.0/0` 会改写默认路由,可能切断你自己的 SSH 会话:先确认有控制台/VNC,并为 SSH 来源地址保留直连路由,再启用。
- UDP 在部分网络/时段会被 QoS:握手正常但速度异常时,对比 TCP 方案(见 `proxy-recipes.md`)。

## 5. 端口转发与中转

- 转发方式选型、链路设计、加密隧道与是否上中转的判断,见 `proxy-recipes.md` §6;本节只补系统层细节。
- 开启转发:`sysctl net.ipv4.ip_forward` 要为 1;确认防火墙放行转发链,别只放行 INPUT。
- **用 ufw 的机器有个坑**:`/etc/ufw/sysctl.conf` 默认 `net/ipv4/ip_forward=0`,ufw 每次启用或重载都会覆盖 `sysctl.d` 里的设置,FORWARD 链默认也是 DROP。要在 `/etc/ufw/sysctl.conf` 里把 `net/ipv4/ip_forward` 设为 1,并把 `/etc/default/ufw` 的 `DEFAULT_FORWARD_POLICY` 改为 `ACCEPT`(或加 `ufw route allow` 规则),否则 ufw 开着时转发不通。

## 6. 隧道 MTU

隧道会增加封装头,MTU 要预留空间(WireGuard 常见做法是把接口 MTU 设得低于物理 MTU,具体数值用 `ping -M do -s` 实测,见 `tuning-playbook.md` 第 5 节)。症状:小请求正常、大响应卡住 → 先怀疑 MTU/MSS。
