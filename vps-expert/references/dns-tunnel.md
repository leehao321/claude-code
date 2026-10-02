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
wg-quick up wg0
wg show                      # 看 latest handshake,有时间说明握手成功
systemctl enable wg-quick@wg0
```

- 对端在 NAT 后:对端加 `PersistentKeepalive = 25`。
- 做全局转发要开 `net.ipv4.ip_forward=1` 并配置 NAT/防火墙;**先确认商家允许转发流量**。
- UDP 在部分网络/时段会被 QoS:握手正常但速度异常时,对比 TCP 方案(见 `proxy-recipes.md`)。

## 5. 端口转发与中转

- 最简单:`realm` / `gost` / nftables DNAT 做端口转发;需要加密时用 Xray/sing-box 链式出站(见 `proxy-recipes.md` 第 6 节)。
- 开启转发:`sysctl net.ipv4.ip_forward`;确认防火墙放行转发链,别只放行 INPUT。
- 每多一层增加延迟和故障点;用"直连 vs 经中转"的三网实测数字决定要不要上。

## 6. 隧道 MTU

隧道会增加封装头,MTU 要预留空间(WireGuard 常见做法是把接口 MTU 设得低于物理 MTU,具体数值用 `ping -M do -s` 实测,见 `tuning-playbook.md` 第 5 节)。症状:小请求正常、大响应卡住 → 先怀疑 MTU/MSS。
