# 系统调优手册

目录:1. 调优前检查 · 2. BDP 与缓冲区 · 3. sysctl 模板 · 4. 分虚拟化 / 分内存策略 · 5. MTU/MSS · 6. swap/zram · 7. 回滚

原则:先备份,小步改,每步验证。模板里每一项都有理由,不适用的删掉,不要整段硬套。

## 1. 调优前检查

```bash
uname -r                                   # 内核版本
systemd-detect-virt                        # 虚拟化类型
sysctl net.ipv4.tcp_available_congestion_control   # bbr 是内核模块,未加载时不会列出,见第 4 节 modprobe tcp_bbr
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
free -h; nproc; df -h
ip -br a; ip route                         # 网卡、MTU、路由
ss -s                                      # 连接概况
```

## 2. BDP 与缓冲区

BDP(带宽延迟积)= 带宽 × RTT,是"管道里同时能装多少数据"。TCP 缓冲区上限要能覆盖 BDP,否则跑不满;设得过大则白占内存。

换算:`BDP(KB) ≈ 带宽(Mbps) × RTT(ms) ÷ 8`

| 带宽 | RTT | BDP | 缓冲区上限建议 |
|---|---|---|---|
| 100 Mbps | 200 ms | 约 2.5 MB | 8 MB |
| 500 Mbps | 150 ms | 约 9.4 MB | 16–32 MB |
| 1 Gbps | 200 ms | 约 25 MB | 32–64 MB |

小内存机器(≤1G)把上限压在 8–16 MB;并发连接多时,总占用 = 连接数 × 缓冲区,要留余量。

## 3. sysctl 模板(KVM)

先备份现有配置,再写入 `/etc/sysctl.d/99-tuning.conf`,`sysctl --system` 生效。

```conf
# 拥塞控制:BBR + fq
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 缓冲区上限(按第 2 节的 BDP 改数值,下例为 32MB)
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# 连接与握手
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0   # 空闲后不重置拥塞窗口,对长连接代理有利
net.ipv4.tcp_mtu_probing = 1             # 路径 MTU 黑洞时自动探测
net.ipv4.tcp_notsent_lowat = 16384       # 降低发送队列堆积,减少排队延迟(可选)
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600

# 队列与端口
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_syncookies = 1
```

文件句柄:`/etc/security/limits.d/99-nofile.conf` 或 systemd 服务里 `LimitNOFILE=1048576`(代理服务的 unit 里设最直接)。

## 4. 分虚拟化 / 分内存策略

**KVM**:上面模板可用。启用 BBR 后务必验证,不要只看配置文件:

```bash
modprobe tcp_bbr 2>/dev/null; lsmod | grep bbr
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc   # 期望 bbr / fq
sysctl net.ipv4.tcp_available_congestion_control                # 里面要有 bbr
```

内核 ≥ 4.9 才有 BBR;想上 BBRv3 或更新队列需要换内核,属高风险,见 SKILL.md Step 3。

**LXC / OpenVZ**:`sysctl -w` 多数会报只读。此时:
- 不要折腾内核参数,把精力放在协议选择、入口线路和客户端侧。
- 拥塞控制取决于宿主机,先 `sysctl net.ipv4.tcp_congestion_control` 看当前是什么。
- 在应用层优化:合理开 mux、减少链式层数、选对端口与协议。

**NAT VPS**:公网端口有限,先确认商家分配的端口范围,协议和端口要落在可用范围内。

**IPv6-only / 双栈**:确认出站是否有 NAT64;双栈机器要检查 IPv6 路由质量是否反而更差,必要时让代理优先 IPv4(或反过来),以实测为准。

**内存分档**

| 内存 | 做法 |
|---|---|
| ≤ 512M | 配 swap/zram;不装重面板;优先轻量内核服务,缓冲区上限 ≤ 8MB;关闭不用的服务 |
| 1–2G | 面板可装但要看常驻内存;缓冲区 16MB 左右 |
| ≥ 4G | 按 BDP 放开缓冲区;可以跑多服务,但仍要限制日志体积 |

## 5. MTU / MSS

怀疑 MTU 问题的典型表现:小请求正常、大响应卡住,或某些站点打不开。

```bash
# 探测路径 MTU(从大到小试,不分片)
ping -M do -s 1472 -c 3 <目标>     # 1472 + 28 = 1500
```

不通就降低 `-s` 数值直到通。确定有效 MTU 后,可以在网卡设置 MTU,或用防火墙做 MSS 钳制(`iptables -t mangle ... TCPMSS --clamp-mss-to-pmtu` 或 nftables 对应规则)。隧道/中转场景要为额外头部预留空间。

## 6. swap / zram

```bash
# swap 文件(示例 1G)
swapon --show; df -h /; ls -l /swapfile 2>&1      # 先确认没有现成 swap、空间够、文件不存在
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
cp /etc/fstab /etc/fstab.bak.$(date +%F)
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=10' >> /etc/sysctl.d/99-tuning.conf && sysctl --system   # 持久化;只写 sysctl -w 重启就丢
```

btrfs 上不能直接用 `fallocate` 建 swap 文件:用 `btrfs filesystem mkswapfile --size 1g /swapfile`(btrfs-progs ≥ 6.1),或 `truncate -s 0 /swapfile; chattr +C /swapfile; dd if=/dev/zero of=/swapfile bs=1M count=1024`,再 `chmod 600`、`mkswap`、`swapon`。

zram 示例(Debian/Ubuntu,装包方式因发行版而异,先确认内核有 zram 模块):

```bash
apt install -y zram-tools && systemctl enable --now zramswap   # 包名/服务名以发行版为准
swapon --show; free -h                                         # 验证
```

LXC/OpenVZ 常不允许自建 swap;KVM 小内存也可以考虑 zram(压缩内存,适合 IO 慢的小鸡)。限制日志:`journalctl --vacuum-size=50M`,并在 `journald.conf` 设 `SystemMaxUse=50M`。

## 7. 回滚

- sysctl:删除 `/etc/sysctl.d/99-tuning.conf` 后 `sysctl --system`,或恢复备份的 `/etc/sysctl.conf`。
- 服务配置:改前 `cp config.json config.json.bak`,出问题直接还原并重启服务。
- 防火墙:改前导出规则(`nft list ruleset > /root/nft.bak` 或 `iptables-save > /root/ipt.bak`)。
- 换内核:保留旧内核并确认 GRUB 能选回;提前确认商家救援模式可用。
