# 安全基线(SSH / 防火墙 / 面板)

目录:1. 顺序原则 · 2. SSH 密钥登录 · 3. 加固 sshd · 4. 防火墙 · 5. 防爆破与更新 · 6. 面板与服务暴露 · 7. 验收清单

原则:**任何一步都要保留当前会话,另开会话验证后再关旧的**;动手前确认商家控制台/VNC 可用。顺序固定:密钥 → 验证 → 再禁密码。

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
ssh -p <ssh端口> <用户>@<服务器IP>      # 新开终端验证:不再问服务器密码(会问密钥口令是正常的)
```

## 3. 加固 sshd

写入 drop-in 文件,不直接乱改主配置(部分系统 `/etc/ssh/sshd_config.d/` 优先级高于主文件,以 `sshd -T` 实际生效值为准):

```bash
cat >/etc/ssh/sshd_config.d/99-hardening.conf <<'CONF'
PasswordAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
CONF
sshd -t && systemctl reload ssh || systemctl reload sshd
sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|^port'   # 确认生效值
```

- **只有确认密钥登录成功后才能禁密码**;否则等于自己锁门。
- 改端口:先在防火墙和云安全组放行新端口 → 加 `Port <新端口>`(此时可保留旧端口)→ 新会话验证新端口 → 再删旧端口。改端口不是安全措施本体,只是减少日志噪音。
- 有些发行版 SSH 由 socket 激活(`ssh.socket`),改端口要改 socket 单元,先 `systemctl status ssh.socket` 看是否在用。

## 4. 防火墙

以 ufw 为例(nftables/iptables 同理,先放行后默认拒绝):

```bash
ufw allow <ssh端口>/tcp
ufw allow <节点端口>/tcp        # 按实际协议放行 tcp/udp
ufw status verbose              # 确认规则在,再启用
ufw enable
```

- Docker 发布的端口会绕过 ufw 规则,面板/容器要自己确认监听地址(`127.0.0.1` 还是 `0.0.0.0`)。
- 云厂商安全组/外部防火墙也要同步放行。

## 5. 防爆破与更新

```bash
apt install -y fail2ban           # Debian/Ubuntu;其他系统用对应包管理器
systemctl enable --now fail2ban
fail2ban-client status sshd
```

- fail2ban 配的端口要与实际 SSH 端口一致,否则不生效。
- 自动安全更新(可选):Debian/Ubuntu 用 `unattended-upgrades`;**内核更新后可能需要重启**,生产机器要安排窗口。

## 6. 面板与服务暴露

- 面板(3x-ui 等)改掉默认端口、默认账号和弱口令;优先只监听本地并用 SSH 隧道访问,或限制来源 IP。
- 不要把面板地址、订阅链接、Token 贴到公开场合(见脱敏清单)。
- 节点端口之外的服务(数据库、Redis 等)不要监听公网:`ss -lntup` 逐个检查监听地址。

## 7. 验收清单

- [ ] 新会话用密钥登录成功;`sshd -T` 生效值符合预期
- [ ] 防火墙只放行必要端口;云安全组一致
- [ ] fail2ban 或等价机制在跑
- [ ] `ss -lntup` 里没有不该暴露的监听
- [ ] 回滚办法已记录(sshd 配置备份、防火墙导出),控制台/VNC 可用
