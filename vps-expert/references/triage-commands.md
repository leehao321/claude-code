# 排查命令与故障救援

目录:1. 使用原则 · 2. 只读排查命令 · 3. 锁死防护 · 4. 常见故障速查 · 5. OpenWrt 基础检查

原则:先只读、后修改;命令要匹配症状,别一股脑全甩;告诉用户"正常长什么样";不要把破坏性参数串在一起。

## 1. 使用原则

- 小白:每条命令解释关键参数;改完立刻给验证命令。
- 用户贴了日志:先引用决定性的几行,再解释。
- 没有 shell 访问时,让用户回贴**关键段落**。

## 2. 只读排查命令

**连通性**

```bash
ping -c 4 1.1.1.1
ping -c 4 <网关或商家IP>
```

`ping` 只证明 ICMP 通,不代表 TCP 通。机器可以禁 ping 但 SSH 正常。

**端口与监听**

```bash
ss -lntup
```

`-l` 监听、`-n` 数字显示、`-t` TCP、`-u` UDP、`-p` 进程(进程名需 root)。确认 sshd 实际监听哪个端口。

**地址与路由**

```bash
ip -br addr
ip route
```

改 `Address=` 或防火墙策略前,先确认自己的 SSH 来源地址。

**资源**

```bash
free -h
df -hT
uptime
vmstat 1 5
```

load 高于 CPU 核数且 `vmstat` 的 `wa` 高 → 是磁盘等待,不是"CPU 慢";`st` 高 → 宿主机超售被偷 CPU;`df -i` 查 inode 是否耗尽。

**近期故障**

```bash
journalctl -u ssh -u sshd --since "1 hour ago" --no-pager
dmesg -T | tail -n 50
```

`-u` 指定服务单元;有的系统叫 `ssh`,有的叫 `sshd`。`dmesg` 里出现 OOM 说明被内存杀进程,需配 swap 或减服务。

**路径质量**

```bash
mtr -rwzbc 50 <目标>
```

`-r` 报告、`-w` 宽输出、`-z` 显示 AS、`-b` 显示 IP、`-c 50` 跑 50 轮。没装 mtr 就说明,并给 `traceroute` 作较弱的替代。**不要编造每一跳的归属。**

## 3. 锁死防护

- **防火墙**:先加放行规则,再改默认拒绝;保持当前 SSH 会话不关,另开会话验证后再关旧的。
- **sshd**:改配置后 `sshd -t` 校验,通过再 `systemctl reload ssh`(或 `sshd`)。改端口时先在防火墙和云厂商安全组放行新端口,新端口验证可登录后再关旧端口。
- **磁盘**:先 `lsblk` 展示,让用户**确认设备名**;永远不要猜 `/dev/sda`。
- **路由器**:先备份 `/etc/config` 或官方配置;型号不对就有变砖风险。
- **救援通道**:动手前确认商家控制台 VNC / 救援模式可用。

## 4. 常见故障速查

**ufw enable 后 SSH 断了**(最常见的小白锁死)

- 诊断:ufw 启用后默认拒绝入站,若没先放行 SSH 端口,新连接全被挡。**重启没用**(规则开机自动生效),别盲目重启。
- 恢复:登录商家控制台 / VNC / 救援模式,在里面执行:

```bash
ss -lntp | grep sshd      # 确认 sshd 真实端口(默认 22)
ufw allow 22/tcp          # 端口不是 22 就换成实际端口
ufw status verbose        # 确认规则已在
```

  实在不行临时 `ufw disable`,恢复登录后再按下面顺序重配。
- 下次顺序:`ufw allow <ssh端口>/tcp` → `ufw status` 确认 → 再 `ufw enable`;保留当前会话并另开会话测试。云厂商安全组/外部防火墙也要放行。

**改了 SSH 端口连不上**:多半是新端口没在防火墙/安全组放行,或 sshd 没重载成功。控制台里 `sshd -t`、`ss -lntp | grep sshd`、检查 `Port` 配置与防火墙规则。

**跑分掉一半**:先区分 CPU 被限还是磁盘。`vmstat 1 5` 看 `st`(偷 CPU)与 `wa`(IO 等待);对比历史 NQ/YABS 的单核分与 fio;邻居高负载时间段复测,别只测一次。

**服务起不来**:`systemctl status <服务>` + `journalctl -u <服务> -n 50 --no-pager`,先读报错最独特一行;配置语法错误先用该软件自带的校验命令(如 `xray run -test -c config.json`,以实际版本为准)。

**磁盘满**:`df -hT`、`du -xh --max-depth=1 / 2>/dev/null | sort -h | tail`,先清日志(`journalctl --vacuum-size=50M`)和包缓存,不要上来就 `rm -rf` 未确认目录。

**IP 偶发连不上**:多地同时 ping/tcping 对比;怀疑被封先别折腾内核,考虑换 IP 或走 CDN 救生艇(见 `proxy-recipes.md`)。

## 5. OpenWrt 基础检查

```sh
ubus call system board     # 型号/板型检查;讨论固件前必做
ip route
logread | tail -n 80
```

`ubus call system board` 是任何固件讨论的前提:镜像名必须与输出匹配,否则不给刷机命令。更多见 `router-openwrt.md`。
