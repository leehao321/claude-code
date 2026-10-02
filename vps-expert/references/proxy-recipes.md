# 代理方案定制手册

目录:1. 协议选型矩阵 · 2. Xray Reality 服务端示例 · 3. Reality 的 dest 怎么选 · 4. Hysteria2 / TUIC 要点 · 5. CDN 备用方案 · 6. 中转与分线路入口 · 7. 客户端侧 · 8. 上线检查清单

配置字段会随版本变化。**写配置前核对对应项目当前文档**(Xray、sing-box、Hysteria 官方文档),下面示例用于说明结构。

## 1. 协议选型矩阵

| 场景 | 首选 | 备选 | 理由与注意点 |
|---|---|---|---|
| 优质回程(CN2 GIA / 9929 / CMIN2),求稳 | VLESS + Reality + Vision(TCP) | SS-2022 | 无需域名和证书,握手开销小,延迟低 |
| 普通线路、晚高峰丢包明显 | Hysteria2 | TUIC v5 | UDP + 激进拥塞控制,抗丢包好;但运营商可能对 UDP 做 QoS,且带宽参数配错会自己造成丢包 |
| IP 被封、需要救活 | VLESS + WS 或 XHTTP 过 CDN | gRPC | IP 藏在 CDN 后面;速度取决于 CDN 到用户的路径,通常不如直连 |
| 小内存(≤512M) | 裸 Xray / sing-box 配置 | — | 不装重面板,省内存 |
| 单核弱 CPU | Reality + Vision(减少二次加密) | — | Vision 流控避免 TLS-in-TLS 的重复加密开销 |

## 2. Xray Reality 服务端示例

结构示例(`config.json`),占位符都需替换:

```json
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "<UUID>", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "<dest域名>:443",
          "serverNames": ["<dest域名>"],
          "privateKey": "<xray x25519 生成的私钥>",
          "shortIds": ["<2~16位偶数长度十六进制>"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
```

生成密钥、UUID 与 shortId:

```bash
xray x25519      # 输出私钥/公钥,私钥放服务端,公钥给客户端
xray uuid
openssl rand -hex 8   # shortId:长度必须是偶数位(0~16 位十六进制,可留空),奇数位 Xray 会启动报错
```

较新的 Xray 版本里 `dest` 也可写作 `target`,以所装版本的文档为准。客户端侧需要:服务器地址、端口、UUID、`flow`、`serverName`、`publicKey`、`shortId`,以及 uTLS 指纹(如 chrome)。

### 安装与启动(小白路径,Xray)

1. **安装**:用 XTLS 官方的 Xray-install 安装脚本,**命令从当前 XTLS/Xray-install 的 README 复制,不要凭记忆**;先下载、读一遍再执行(`curl -L <README 里的脚本地址> -o install.sh && less install.sh`)。不要用顺手改防火墙和系统调优的"全家桶"脚本。
2. **配置文件**:以安装脚本打印的路径为准,通常是 `/usr/local/etc/xray/config.json`。用上面的 `xray x25519`、`xray uuid` 生成密钥和 UUID,按输出里的标签区分私钥与公钥(输出格式随版本变化),填进上面的模板;`dest` 先按下一节选好。
3. **校验再启动**:

```bash
ss -lntp | grep ':443'                    # 443 已被占用(如 nginx)就换端口或先停掉占用者
xray run -test -c /usr/local/etc/xray/config.json   # 语法校验(参数以所装版本为准);必须通过
systemctl enable --now xray
systemctl status xray --no-pager          # 期望 active (running)
ss -lntp | grep xray                      # 确认监听端口
```

4. **放行端口**:防火墙(ufw 等)和商家云防火墙/安全组都要放行节点端口(顺序与防锁死见 `security-baseline.md`)。
5. **客户端填写**:服务器地址、端口、UUID、flow(`xtls-rprx-vision`)、serverName(= dest 域名)、publicKey、shortId、uTLS 指纹(如 chrome)。
6. **首次验证**:客户端连上后,访问 IP 查询站,显示的应是这台 VPS 的出口 IP;连不上先看 `journalctl -u xray -n 50 --no-pager` 里最独特的一行。

## 3. Reality 的 dest 怎么选

条件:支持 TLS 1.3 和 H2、可正常访问、不是自己的站点。

**关键:实测从这台 VPS 到候选 dest 的 RTT。**

```bash
for h in <候选1> <候选2> <候选3>; do
  echo "== $h"
  # 握手耗时 + 实际协商的 HTTP 版本(期望 http=2)
  curl -so /dev/null --http2 -w "http=%{http_version} connect=%{time_connect} tls=%{time_appconnect}\n" https://$h
  # TLS 版本与 ALPN(期望 Protocol: TLSv1.3,ALPN protocol: h2)
  echo | openssl s_client -connect $h:443 -servername $h -tls1_3 -alpn h2 2>/dev/null | grep -E 'Protocol|ALPN'
done
```

通过条件:`http=2`、`TLSv1.3`、`ALPN protocol: h2` 三项都满足才留作候选,再在候选里挑握手耗时最低的;任何一项不满足就丢弃。

- 优先选与 VPS **同地区、同机房网络**、握手时间很低的站点。
- 握手耗时与"该站点真实所在位置"明显不符(例如 VPS 在洛杉矶,dest 却是远在欧洲的站点),可能成为被主动探测识别的特征。这是圈内一直在讨论的点,没有一劳永逸的答案,所以**每台机器单独实测、定期复查**。
- 不要多台机器共用同一个冷门 dest,也不要选自己控制的域名。
- 选好后记录到机器档案,方便以后被封时对比换 dest 的效果。

## 4. Hysteria2 / TUIC 要点

- **带宽参数要如实填**:Hysteria2 的 Brutal 拥塞控制按你声明的速率发包,声明值远高于线路实际容量,会制造大量丢包反而更慢。填你实测的真实可用速率,宁可略保守。
- **UDP QoS**:部分运营商(尤其晚高峰)对 UDP 限速或丢弃。先对比 TCP 方案和 UDP 方案在**同一时段**的实测,再定主力。
- **端口**:443/UDP 常用;部分网络对高位 UDP 端口更敏感,可测试端口跳跃(port hopping)是否有改善。
- 需要证书(自签或真实域名)时,按官方文档配置,并配好伪装(masquerade)。
- 不确定的参数,去查官方文档或论坛近期帖子,不要凭印象填。

## 5. CDN 备用方案(VLESS + WS/XHTTP)

适合 IP 被封或想隐藏源站的备用线路。注意:
- 需要域名并托管到 CDN,服务端用 TLS 或由 CDN 回源。
- 走 CDN 后的路径不再由 VPS 线路决定;速度和稳定性要实测,常见做法是选优选 IP,但这会增加维护成本。
- 作为主力前先测晚高峰;它更常用作"主线路被封时的救生艇"。
- 遵守 CDN 服务商的使用条款。

## 6. 中转与分线路入口

场景:落地机回程普通、晚高峰差,但有优质入口或专线可用。

- **链路**:国内入口(中转机/专线)→ 落地 VPS。入口到落地段的线路质量(如 IPLC/IEPL、CN2/9929 优质回程的中转机)决定整体体验。
- **按运营商分入口**:电信、联通、移动用户各接对应更优的入口,再汇到同一落地。配置上是同一落地多个入口地址,订阅里分组。
- **转发方式**:端口转发(iptables/nftables/realm/gost)最简单;需要加密隧道时用 Xray/sing-box 的链式出站(Xray 用 `streamSettings.sockopt.dialerProxy`,sing-box 用 outbound 的 `detour`,Clash/mihomo 的同类字段才叫 `dialer-proxy`;字段名以所装版本文档为准)。**每多一层,延迟和故障点都增加**,能少一层就少一层。
- **成本与条款**:专线和中转有成本,确认商家允许转发流量,别把对方机器当成无限量。
- **验证**:对比"直连"和"经中转"在三网各自的晚高峰延迟、丢包、速度,用数字决定要不要上中转。

## 7. 客户端侧

- 分流规则:国内直连、国外走代理,DNS 防泄漏与分流要一并配置。
- 订阅管理:按用户现有流程来(例如 Sub-Store 转换为 Clash 订阅、私有仓库托管 YAML 并用受限权限的访问令牌拉取)。令牌与订阅地址都属于敏感信息,不要贴到公开场合。
- 路由器端(如 OpenWrt/ImmortalWrt 上的 PassWall):注意 CPU 加密能力,弱路由别开重协议和过多规则集。
- 多节点:按"三网最优入口 + 备用节点"分组,自动测速选择,并设置故障切换。

## 8. 上线检查清单

- [ ] 服务端防火墙只放行必要端口,SSH 已加固
- [ ] 服务以 systemd 托管,开机自启,崩溃自动重启
- [ ] 日志级别和体积已限制
- [ ] 三网各至少一次闲时 + 一次晚高峰实测并记录
- [ ] 已准备备用节点或备用协议
- [ ] 配置与密钥已备份到安全位置(不在公开仓库)
- [ ] 机器档案已更新(协议、端口、dest、测速数据)
