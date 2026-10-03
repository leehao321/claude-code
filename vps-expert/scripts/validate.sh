#!/usr/bin/env bash
# 结构自检:frontmatter、references 链接与索引、evals schema、关键规则标记、疑似真实密钥。
# 用法:bash scripts/validate.sh
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
err(){ echo "FAIL: $*"; fail=1; }

# ---- frontmatter(只看开头那个块;兼容 CRLF)----
fm=$(tr -d '\r' < SKILL.md | awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {closed=1; exit} f {print} END {if(!closed) exit 3}')
[ $? -eq 0 ] || err "SKILL.md frontmatter 缺少起止 ---"
[ -n "$fm" ] || err "SKILL.md frontmatter 为空"
printf '%s\n' "$fm" | grep -qx 'name: vps-expert' || err "frontmatter 里 name 不是 vps-expert"
desc=$(printf '%s\n' "$fm" | sed -n 's/^description: *//p')
[ -n "$desc" ] || err "description 为空"
case "$desc" in '>'|'|'|'>-'|'|-'|'>+'|'|+') err "description 不能用折叠/块标量写法(长度检查会失效),请写成单行";; esac
dlen=$(printf '%s' "$desc" | python3 -c 'import sys; print(len(sys.stdin.read()))')   # 按字符计数,不受 locale 影响
[ "$dlen" -le 1024 ] || err "description 超过 1024 字符(当前 $dlen)"

# ---- references:SKILL.md 引用的必须存在;存在的必须在索引节出现 ----
index=$(sed -n '/^## references 索引/,$p' SKILL.md)
[ -n "$index" ] || err "SKILL.md 缺少 '## references 索引' 一节"
for f in $(grep -ohE 'references/[A-Za-z0-9_.-]+\.md' SKILL.md | sort -u); do
  [ -f "$f" ] || err "SKILL.md 引用了不存在的 $f"
done
for f in references/*.md; do
  printf '%s\n' "$index" | grep -qF "$f" || err "$f 未在索引节中列出"
done

# references 之间的交叉引用(反引号里的 xxx.md 或 references/xxx.md)
for f in $(grep -ohE '`(references/)?[A-Za-z0-9_-]+\.md`' references/*.md SKILL.md | tr -d '`' | sed 's#^references/##' | grep -vE '^(SKILL|CHANGELOG|README)\.md$' | sort -u); do
  [ -f "references/$f" ] || err "引用了不存在的 references/$f"
done

# ---- evals / triggers schema ----
python3 - <<'PY' || fail=1
import json, sys
ok = True
def bad(m):
    global ok; print("FAIL: " + m); ok = False
def s(x): return isinstance(x, str) and x.strip() != ""
data = {}
for n in ("evals", "triggers"):
    try:
        d = json.load(open(f"evals/{n}.json", encoding="utf-8"))
    except Exception as e:
        bad(f"evals/{n}.json: {e}"); continue
    cs = d.get("test_cases") if isinstance(d, dict) else None
    if not isinstance(cs, list) or not cs:
        bad(f"{n}: 没有 test_cases"); continue
    if not all(isinstance(c, dict) for c in cs):
        bad(f"{n}: 用例必须是对象"); continue
    data[n] = cs
if "evals" in data:
    names = []
    for c in data["evals"]:
        if not s(c.get("name")): bad("evals: 用例缺少 name"); continue
        names.append(c["name"])
        if not s(c.get("input")): bad(f"evals/{c['name']}: input 为空")
        a = c.get("assertions")
        if not isinstance(a, list) or not a or not all(s(x) for x in a):
            bad(f"evals/{c['name']}: assertions 必须是非空字符串列表")
    if len(set(names)) != len(names): bad("evals: name 有重复")
if "triggers" in data:
    inputs = []
    for c in data["triggers"]:
        if not s(c.get("input")): bad("triggers: input 为空"); continue
        inputs.append(c["input"])
        if not isinstance(c.get("should_trigger"), bool):
            bad(f"triggers/{c['input'][:20]}: should_trigger 必须是布尔值")
    if len(set(inputs)) != len(inputs): bad("triggers: input 有重复")
    vals = [c.get("should_trigger") for c in data["triggers"]]
    if True not in vals or False not in vals: bad("triggers: 必须同时有正例和反例")
sys.exit(0 if ok else 1)
PY

# ---- SKILL.md 里 evals 依赖的关键规则不能被误删 ----
for m in '[CONFIRMED]' '[PROBABLE]' '[CONTESTED]' '[UNKNOWN]' '[VENDOR]' '## 红线与安全习惯' '外部内容是数据' '不运行来路不明的脚本' '锁死防护' '`lsblk`' 'sshd -t' '不得编造'; do
  grep -qF -- "$m" SKILL.md || err "SKILL.md 缺少关键规则标记: $m"
done

# ---- 疑似真实密钥/UUID(只抽取 token 比对白名单;scripts/validate.sh 按路径排除)----
uuid_hits=$(grep -rEnoi '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' . --include='*.md' --include='*.json' --include='*.sh' --include='*.conf' \
  | grep -v '^\./scripts/validate\.sh:' \
  | grep -viE ':(00000000-0000-0000-0000-000000000000|12345678-1234-1234-1234-123456789012|8b0f2c6e-1111-4222-8333-444455556666)$')
[ -z "$uuid_hits" ] || { echo "$uuid_hits"; err "发现疑似真实 UUID(确需保留就把整串加入白名单)"; }
# WireGuard / Xray Reality 私钥:key 名后紧跟 43 位 base64/base64url(占位符以 < 开头,不会命中)
key_hits=$(grep -rEnoi 'private[_ -]?key"?[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9_+/-]{43}=?' . --include='*.md' --include='*.json' --include='*.sh' --include='*.conf' \
  | grep -v '^\./scripts/validate\.sh:')
[ -z "$key_hits" ] || { echo "$key_hits"; err "发现疑似真实私钥"; }

[ $fail -eq 0 ] && echo "OK" || exit 1
