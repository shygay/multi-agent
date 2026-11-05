#!/usr/bin/env bash
# 让主力子 agent 按同一份规则把判定用例判一遍，检查规则写得清不清楚。
#
# 用法: run-routing.sh <工作区外的输出目录> [次数=2]
#
# 环境变量:
#   GLOBAL_RULES_FILE  全局规则文件（可空）。只取里面讲多 agent 的那一节，见 README 的"全局规则"
#
# 它测的是规则有没有歧义，不是主路由实际会怎么判断。真实判定要开新会话，见 routing-cases.md。
set -u

OUT="${1:?用法: run-routing.sh <工作区外的输出目录> [次数]}"
RUNS="${2:-2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../scripts"

mkdir -p "$OUT/repo"
OUT="$(cd "$OUT" && pwd)"
# 有的 CLI 要求工作目录是 git 仓库，给它一个空的，它也就读不到无关的东西
git -C "$OUT/repo" init -q

PROMPT="$OUT/prompt.md"
{
  cat <<'EOF'
你是主路由（主会话）。下面先是你的规则，后面是 16 条用户消息。
这是一次路由判定测试：不要执行任务，不要读其他文件，只按规则判断。规则里提到的脚本和文件都存在。
每条输出一行，格式如下，不要输出别的内容：
<编号> | 判定：<不派；或者派给谁、几个、做什么、什么模型和强度；或者转哪个 skill 或工具> | 先问用户：<要或不要>

# 规则一：全局规则

EOF
  GLOBAL=""
  if [ -n "${GLOBAL_RULES_FILE:-}" ] && [ -f "$GLOBAL_RULES_FILE" ]; then
    GLOBAL="$(awk '/^## .*多 agent/ {on=1; print; next} on && /^## / {exit} on' "$GLOBAL_RULES_FILE")"
  fi
  printf '%s\n' "${GLOBAL:-（没有）}"
  printf '\n# 规则二：multi-agent skill\n\n'
  cat "$HERE/../SKILL.md"
  printf '\n# 用户消息\n\n'
  # 只取编号和用户的话，不带期望判定
  awk -F'|' '/^\| *[0-9]+ *\|/ {
    id = $2; text = $3
    gsub(/^ +| +$/, "", id); gsub(/^ +| +$/, "", text)
    print id ". " text
  }' "$HERE/routing-cases.md"
} > "$PROMPT"

for r in $(seq 1 "$RUNS"); do
  bash "$SCRIPTS/kick-read.sh" "$OUT/repo" "$PROMPT" "$OUT/answer-$r.txt" &
done
wait
echo "ROUTING_DONE 结果在 $OUT/answer-*.txt"
