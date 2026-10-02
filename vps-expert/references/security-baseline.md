# 安全基线(SSH / 防火墙 / 面板)

目录:1. 顺序原则 · 2. SSH 密钥登录 · 3. 加固 sshd · 4. 防火墙 · 5. 防爆破与更新 · 6. 面板与服务暴露 · 7. 验收清单

原则:**任何一步都要保留当前会话,另开会话验证后再关旧的**。顺序固定:密钥 → 验证 → 再禁密码。

**硬前提**:动手前确认商家控制台/VNC 能用,最好**实际登录一次**(很多镜像只用密钥、没设过 root 密码,控制台会卡在登录界面)。进不去控制台就不要改端口、禁密码、启用防火墙。

## 1. 顺序原则

1. 备份:`cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F)`
2. 配好密钥并**用新会话验证能登录**
3. 防火墙先放行(含新 SSH 端口),再启用
4. `sshd -t` 通过再 reload
5. 新会话验证 → 再收紧

## 2. SSH 密钥登录

在**本地电脑**生成并上传(已有密钥可跳过生成):

```bash
ssh-keygen -t ed25519 -C "vps-$(date +%F)"
ssh-copy-id -p <ssh端口> <用户>@<服务器IP>
```

在**新终端**强制只用密钥验证(不会回退到服务器密码):

```bash
ssh -p <ssh端口> -o PreferredAuthentications=publickey -o PasswordAuthentication=no <用户>@<服务器IP> 'echo KEY_OK; id'
```

- **必须看到 `KEY_OK` 才算密钥可用**。会要你输入"密钥口令"是正常的(那是你本地私钥的口令,不是服务器密码)。
- 出现 `Permission denied (publickey)` 就停下,回去查服务器上 `~/.ssh/authorized_keys` 的权限(目录 700、文件 600)和属主,**不要往下做**。
- 如果以后用非 root 用户管理服务器,在旧会话里先确认 `sudo -v` 可用,再关旧会话。

## 3. 加固 sshd

**前置条件(硬性)**:第 2 节命令已在另一个终端输出 `KEY_OK`,且当前旧会话保持打开,否则不要写入下面的配置。

sshd 对每个关键字**只取第一个读到的值**,drop-in 按文件名字典序读取,所以用 `00-` 开头才能压过 Ubuntu 云镜像自带的 `50-cloud-init.conf`(常含 `PasswordAuthentication yes`)。写入前先查冲突、查主配置是否读 drop-in:

```bash
grep -riE 'passwordauthentication|permitrootlogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null
grep -i '^Include' /etc/ssh/sshd_config      # 没有输出(如 CentOS 7)说明不读 drop-in,直接改 /etc/ssh/sshd_config
```

有冲突项就改掉或删掉,然后写入并校验、重载:

```bash
cat >/etc/ssh/sshd_config.d/00-hardening.conf <<'CONF'
PasswordAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
CONF
if sshd -t; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
else
  echo "sshd 配置有误,未重载;修好 00-hardening.conf(或删掉它)后再试,当前会话保持不动"
fi
sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|^port'   # 以生效值为准
```

- `sshd -t` 有任何报错就**不要 reload**。
- 改端口:先在防火墙和云安全组放行新端口 → 加 `Port <新端口>`(此时保留旧端口)→ 新会话验证新端口 → 再删旧端口。改端口只是减少日志噪音,不是安全措施本体。
- 有些发行版 SSH 由 socket 激活(`ssh.socket`),改端口要改 socket 单元,先 `systemctl status ssh.socket` 看是否在用。

## 4. 防火墙

以 ufw 为例(nftables/iptables 同理:先放行,再收紧)。

**第一步:从实际在用的端口取值,不要凭记忆写 22**

```bash
echo $SSH_CONNECTION | awk '{print "当前会话连的服务器端口:", $4}'   # 最可靠,含 ssh.socket 场景
sshd -T | grep -i '^port'                                              # 配置值
ss -lntp | grep -E 'sshd|systemd'                                      # 监听者(ssh.socket 时属主是 systemd)
```

**第二步:先放行,启用前确认规则已添加**

```bash
ufw allow <ssh端口>/tcp          # 必须与上面输出一致
ufw allow <节点端口>/tcp         # 按实际协议放行 tcp/udp
ufw show added                   # 启用前列出已添加规则(未启用时 ufw status 只显示 inactive)
```

**第三步:启用前加"自动撤销"保险,验证后取消**

```bash
systemd-run --on-active=5m --unit=ufw-rollback ufw disable   # 5 分钟后自动关闭防火墙,防止把自己锁在外面
ufw enable                       # 会提示"可能中断现有 ssh 连接",输入 y 确认(放行规则已加,所以没问题)
# 另开新会话,确认能用 <ssh端口> 登录;成功后取消保险并复核:
systemctl stop ufw-rollback.timer
ufw status verbose
```

没有 systemd 的环境改用 `at` 或另一个保持打开的会话兜底;**没有保险、没有控制台就不要启用防火墙**。

- Docker 发布的端口会绕过 ufw 规则,面板/容器要自己确认监听地址(`127.0.0.1` 还是 `0.0.0.0`)。
- 云厂商安全组/外部防火墙也要同步放行。

## 5. 防爆破与更新

```bash
apt install -y fail2ban           # Debian/Ubuntu;其他系统用对应包管理器
cat >/etc/fail2ban/jail.d/sshd.local <<'CONF'
[sshd]
enabled  = true
port     = <实际ssh端口>
ignoreip = 127.0.0.1/8 ::1 <你的固定IP>
CONF
systemctl enable --now fail2ban && systemctl restart fail2ban
fail2ban-client status sshd
```

- 端口必须与实际 SSH 端口一致,否则不生效。没有固定公网 IP 就不要把会过期的 IP 写进 `ignoreip`,并知道自己有被封的风险。
- 改端口、换密钥的试错期容易把自己封掉(ssh-agent 一次提供多把密钥也会触发 `Too many authentication failures`)。测试登录时用 `ssh -o IdentitiesOnly=yes -i <指定密钥> -p <端口> ...`。
- 自救:用商家控制台/VNC(或换一个 IP)登录后执行 `fail2ban-client set sshd unbanip <你的IP>`。
- 自动安全更新(可选):Debian/Ubuntu 用 `unattended-upgrades`;**内核更新后可能需要重启**,生产机器要安排窗口。

## 6. 面板与服务暴露

- **面板默认只监听 127.0.0.1**(面板设置里的监听地址,用 `ss -lntp` 验证),通过 SSH 隧道访问:`ssh -N -L 8443:127.0.0.1:<面板端口> <用户>@<服务器IP>`,然后浏览器开 `http://127.0.0.1:8443`。
- 确需公网访问:必须 TLS(域名证书或反代)+ 改默认端口/账号/强口令 + 限制来源 IP,否则不得对公网开放。3x-ui 之类面板默认 HTTP 明文,口令会被明文传输。订阅端口通常要对客户端开放,单独走 TLS,不套用来源 IP 白名单。
- Docker 部署:`-p 127.0.0.1:<端口>:<端口>`(ufw 管不到 Docker 发布的端口);若用 `--network host`,该写法无效,须改面板自身监听地址。
- 面板的一键安装脚本同样是 `curl | bash` 来源:先下载阅读、核对官方 README 当前命令,再执行。
- 不要把面板地址、订阅链接、Token 贴到公开场合(见 `community-research.md` 脱敏清单)。
- 节点端口之外的服务(数据库、Redis 等)不要监听公网:`ss -lntup` 逐个检查监听地址。

## 7. 验收清单

- [ ] 新会话用密钥登录成功;`sshd -T` 生效值符合预期
- [ ] 防火墙只放行必要端口;云安全组一致;自动撤销保险已取消
- [ ] fail2ban 或等价机制在跑,`ignoreip`/端口正确
- [ ] `ss -lntup` 里没有不该暴露的监听
- [ ] 回滚办法已记录(sshd 配置备份、防火墙导出),控制台/VNC 可用
