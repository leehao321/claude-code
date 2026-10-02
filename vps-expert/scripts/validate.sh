#!/usr/bin/env bash
# 结构自检:frontmatter、references 链接、evals JSON、敏感信息。用法:bash scripts/validate.sh
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
err(){ echo "FAIL: $*"; fail=1; }

head -1 SKILL.md | grep -q '^---$' || err "SKILL.md 缺少 frontmatter"
grep -q '^name: vps-expert$' SKILL.md || err "name 字段缺失或不是 vps-expert"
grep -q '^description: ' SKILL.md || err "description 缺失"

# SKILL.md 索引里引用的 references 必须存在,存在的 references 必须被索引
for f in $(grep -o 'references/[a-z0-9-]*\.md' SKILL.md | sort -u); do [ -f "$f" ] || err "SKILL.md 引用了不存在的 $f"; done
for f in references/*.md; do grep -q "$f" SKILL.md || err "$f 未在 SKILL.md 中索引"; done

# reference 之间的交叉引用
for f in $(grep -oh '`[a-z0-9-]*\.md`' references/*.md | tr -d '`' | sort -u); do
  [ -f "references/$f" ] || err "references 内引用了不存在的 $f"; done

python3 - <<'PY' || fail=1
import json,sys
ok=True
for n in ("evals","triggers"):
    try: d=json.load(open(f"evals/{n}.json",encoding="utf-8"))
    except Exception as e: print("FAIL: evals/%s.json: %s"%(n,e)); ok=False; continue
    if not d.get("test_cases"): print("FAIL: %s 无用例"%n); ok=False
sys.exit(0 if ok else 1)
PY

# 疑似真实密钥/IP(示例占位符除外)
grep -rEn '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' . --include='*.md' && err "发现疑似真实 UUID"

[ $fail -eq 0 ] && echo "OK" || exit 1
