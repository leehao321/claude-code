# 排查命令与故障救援

目录:1. 使用原则 · 2. 只读排查命令 · 3. 锁死防护 · 4. 常见故障速查 · 5. 新盘格式化与挂载 · 6. 独立服务器要点 · 7. OpenWrt 基础检查

原则:先只读、后修改;命令要匹配症状,别一股脑全甩;告诉用户"正常长什么样";不要把破坏性参数串在一起。

## 1. 使用原则

- 小白:每条命令解释关键参数;改完立刻给验证命令。
- 用户贴了日志:先引用决定性的几行,再解释。
- 没有 shell 访问时,让用户回贴**关键段落**。
- **已经连不上的用户没法跑命令也没法贴日志**:直接给控制台步骤(见第 4 节),不要要求他"先看日志"。

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
mtr -rwzbc 100 <目标>
```

`-r` 报告、`-w` 宽输出、`-z` 显示 AS、`-b` 显示 IP、`-c 100` 跑 100 轮(约 100 秒)。没装 mtr 就说明,并给 `traceroute` 作较弱的替代。**不要编造每一跳的归属。**

- **方向要说清**:回程(VPS→国内)在 VPS 上跑 `mtr -rwzbc 100 <用户家宽公网IP>`;用户在 IP 查询站查自己的出口 IP。家用路由器和光猫常丢弃 ICMP,CGNAT 下可能根本不通——此时看联通网内最后一个有回应的跳,或让用户在自己电脑上用 WinMTR/NextTrace 测去程(用户→VPS)。
- **怎么读**:"丢包从哪一跳开始"指某一跳起丢包率变高且**后面每一跳都跟着高**。只在中间某一跳高、后面的跳恢复正常,通常是该路由器对 ICMP 限速,**不算真丢包**。判定以最后一跳(或最后有回应的跳)为准;最后一跳本身不回应时,结论降级,不要硬判。
- **采样**:闲时(如凌晨)和晚高峰(北京时间 20:00–24:00)各跑一次,`mtr -rwzbc 100 <IP> | tee ~/mtr-$(date +%F-%H%M).log`。让用户**贴完整报告**(一般十几行)并写明测试时间。晚高峰数据一次回复里凑不齐:先给 `[PROBABLE]` 工作假设,说明还缺哪组数据。

## 3. 锁死防护

- **防火墙**:先加放行规则,再启用;保持当前 SSH 会话不关,另开会话验证。完整顺序与自动撤销保险见 `security-baseline.md` §4。
- **sshd**:改配置后 `sshd -t` 校验,通过才 reload;写法见 `security-baseline.md` §3。
- **磁盘**:先 `lsblk` 展示,让用户**确认设备名**;永远不要猜 `/dev/sda`。流程见第 5 节。
- **路由器**:先备份 `/etc/config` 或官方配置;型号不对就有变砖风险。
- **救援通道**:动手前确认商家控制台 VNC / 救援模式可用,最好登录过一次。

## 4. 常见故障速查

**ufw enable 后 SSH 断了**(最常见的小白锁死)

- 原因:ufw 启用后默认拒绝入站,若没先放行 SSH 端口,新连接全被挡。**重启没用**(规则开机自动生效)。
- 已经连不上时,不要让用户跑命令或贴日志,直接给控制台步骤:
  1. 到买机器的网站后台,找"VNC / 控制台 / 远程连接 / Console"按钮,点开会出现一个黑屏登录界面。这条通道不走 SSH,不受 ufw 影响。
  2. 如果提示输入 root 密码但用户从没设过(只用密钥登录的镜像):先在同一后台找"重置 root 密码 / Reset Password",重置后(可能要重启一次)再回控制台登录。
  3. 登录后执行:

```bash
ss -lntp | grep -E '"sshd"|"systemd"'      # 看 Local Address 列冒号后的数字,那就是 SSH 实际端口
ufw allow <ssh端口>/tcp                # 把尖括号整个换成上一行看到的数字(没改过才是 22,不要凭记忆写)
ufw status verbose                     # 确认规则已在(此时 ufw 是启用的,能看到规则)
```

  - 白话解释(小白要看):`ufw allow 端口/tcp` = 在防火墙上给这个端口开一扇门,允许外面连进来;端口号是服务的"门牌号",SSH 默认是 22。
  - 输出可能有多行:SSH 那一行的进程名是 `"sshd"`,或是 `"systemd"` 且端口不是 53(53 是系统自带的 DNS 解析,不是 SSH)。
  - 如果上面的 `ss` 命令输出为空,或监听者是 `systemd`:说明系统用的是 `ssh.socket`(Ubuntu 22.10+/24.04 默认),端口以 `systemctl cat ssh.socket` 里的 `ListenStream` 为准,不是 sshd_config 里的 `Port`。

  4. 不行再临时 `ufw disable`。**注意:`ufw disable` 期间整台机器没有主机防火墙,面板、数据库等监听端口会暴露公网,只能作几分钟的应急。** 恢复登录后立刻 `ss -lntp` 检查,再按 `security-baseline.md` §4 的顺序重配,最后确认 `ufw status verbose` 显示 `Status: active`。
- 没有控制台入口、或登不进去:
  1. 先提工单让商家处理(说明"ufw 误开导致 SSH 被挡,请协助进系统关闭防火墙")。
  2. 后台有"救援模式 / Rescue"的话:进救援系统后用 `lsblk` 让用户确认根分区设备名,把根分区挂载到 `/mnt`,编辑其中的 `/mnt/etc/ufw/ufw.conf` 把 `ENABLED=yes` 改成 `ENABLED=no`,卸载后退出救援模式重启(设备名和路径以实际为准)。
  3. 都没有:商家的"重装系统"是最后手段,**会清空全部数据**,先确认数据能不能放弃。
  4. 云厂商若有"重置防火墙/安全组"功能,先确认被挡的是不是它而不是 ufw。
- 下次顺序:查实际 SSH 端口 → `ufw allow <ssh端口>/tcp` → `ufw show added` 确认(未启用时 `ufw status` 看不到规则)→ 加自动撤销保险 → `ufw enable` → 新会话验证 → `ufw status verbose` 复核。云厂商安全组也要放行。

**改了 SSH 端口连不上**:多半是新端口没在防火墙/安全组放行,或 sshd 没重载成功。控制台里 `sshd -t`、`ss -lntp | grep -E '"sshd"|"systemd"'`(监听者是 systemd 说明用了 `ssh.socket`,端口看 `systemctl cat ssh.socket` 的 `ListenStream`,改 `Port` 不够,见 `security-baseline.md` §3(改端口)与 §4(查实际端口))、检查防火墙规则。

**跑分掉一半**:先区分 CPU 被限还是磁盘。`vmstat 1 5` 看 `st`(偷 CPU)与 `wa`(IO 等待);对比历史 NQ/YABS 的单核分与 fio;邻居高负载时间段复测,别只测一次。

**服务起不来**:`systemctl status <服务>` + `journalctl -u <服务> -n 50 --no-pager`,先读报错最独特一行;配置语法错误先用该软件自带的校验命令(如 `xray run -test -c config.json`,以实际版本为准)。

**磁盘满**:`df -hT`、`du -xh --max-depth=1 / 2>/dev/null | sort -h | tail`,先清日志(`journalctl --vacuum-size=50M`)和包缓存,不要上来就 `rm -rf` 未确认目录。

**IP 偶发连不上**:多地同时 ping/tcping 对比;怀疑被封先别折腾内核,考虑换 IP 或走 CDN 救生艇(见 `proxy-recipes.md`)。

## 5. 新盘格式化与挂载

破坏性操作,**确认闸门在前**:

1. **备份**,然后让用户贴 `lsblk -f` 的输出。**在用户确认设备名、该设备未挂载、且为空盘或已备份之前,不给 `mkfs`**。如果它已有文件系统或挂载点(FSTYPE/MOUNTPOINT 非空),明确警告 `mkfs` 不可逆地清空数据并要求用户明确回复"确认清空",否则停止。
   **第一轮回复要预告完整流程**,让用户心里有数:`lsblk -f` 确认设备 → 备份 `/etc/fstab` → `mkfs`(要求目标设备**已卸载**,有挂载点先 `umount`)→ `blkid` 取 UUID 写 fstab 并加 `nofail` → `mount -a` 验证 → `df -hT` 复核。同时在第一轮就警告:`mkfs` 不可逆地清空数据。**确认设备之前,整条回复里不要出现任何 `mkfs ...` 的字面命令**(包括"如果是整盘就用……"这类备选),只用文字描述将要做什么;命令块在用户确认后才给。
2. 确认后,用**确认过的设备**(不是猜的)。新盘常常没有分区(如 VPS 上的 `/dev/vdb` 下没有 `vdb1`):二选一并向用户确认——先分区(如 `parted /dev/vdb mklabel gpt mkpart data ext4 1MiB 100%`,得到 `/dev/vdb1`),或整盘直接 `mkfs.ext4 /dev/vdb`。下面用变量 `DEV` 统一替换,别在各行里分别写设备名:

```bash
DEV=/dev/vdb1                        # 换成用户确认过的设备(分区或整盘),下面所有命令都用它
mkfs.ext4 "$DEV"
mkdir -p /data && mount "$DEV" /data
cp /etc/fstab /etc/fstab.bak.$(date +%F)
echo "UUID=$(blkid -s UUID -o value "$DEV") /data ext4 defaults,nofail 0 2" >> /etc/fstab
tail -n 1 /etc/fstab                 # 确认写进去的是真实 UUID,不是空的
umount /data && mount -a             # 验证 fstab 写对了;报错立刻修,别重启
df -hT /data                         # 验证已挂载
```

`nofail` 让磁盘缺失时机器照样能启动;写错的 fstab 行可能让机器开机进入紧急模式,所以必须先 `mount -a` 验证。

## 6. 独立服务器要点

- **带外管理**:IPMI / iKVM / 商家救援系统是独服的恢复通道,和 VPS 的 VNC 同理——动手前确认能登录。
- **磁盘与 RAID 健康**:`smartctl -a /dev/sdX`(需 smartmontools)看 Reallocated/Pending 扇区;软 RAID 用 `cat /proc/mdstat`、`mdadm --detail /dev/mdX`;硬 RAID 用厂商工具,不确定先问商家。
- **重装系统前**:备份数据,记下静态 IP/网关/子网掩码和网卡名,重装后要重新配置网络,否则装完连不上。
- 具体型号的 BIOS/引导/分区方案差异大,不确定的先检索或问商家。

## 7. OpenWrt 基础检查

```sh
ubus call system board     # 已是 OpenWrt 时的型号/板型检查(原厂固件无 SSH 时跳过,改读后台/标签)
ip route
logread | tail -n 80
```

已运行 OpenWrt 的设备:`ubus call system board` 是固件讨论的前提,镜像名必须与输出匹配。原厂固件(通常还没有 SSH):不要求 ubus;从后台"系统状态"页或机身标签取型号 + 硬件版本 + 当前固件版本,镜像名必须与这些信息及恩山帖子一致。两种情况下型号/硬件版本对不上,都不给刷机命令。更多见 `router-openwrt.md`。
