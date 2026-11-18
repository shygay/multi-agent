#!/usr/bin/env bash
# 派一个小任务给轻量子 agent，并记账控制额度。怎么调用它写在 local.env 的 light_run 里。
#
# 用法: kick-light.sh <专用 worktree> <提示词文件> [墙钟上限秒=1200]
#
# 为什么要记账：很多 CLI 的输出里没有用量数字，只能靠"次数 + 时长"自己控。
# 每次调用都追加一行到账本，超过单日上限就拒绝再派。
#
# 环境变量（也可以写进 local.env，命令行上的优先）:
#   LIGHT_MODEL         不设时调 local.env 的 light_latest_model 现查最新型号；查不到用它自己的默认模型
#   LIGHT_STRONG_MODEL  更强的模型。设了 LIGHT_USE_STRONG=1 时用它
#   LIGHT_DAILY_MAX     单日最多调用次数，默认 8
#   LIGHT_LEDGER        账本路径，默认 skill 根目录的 light-ledger.tsv
#   LIGHT_PAUSE_FILE    暂停标记路径，默认 skill 根目录的 light-paused-on
#
# 退出码: 0 完成 | 13 额度或权限报错（当天自动暂停，不要重试）| 14 超过单日上限或当天已暂停
#         124 超时 | 2 参数或配置错误 | 其它 子 agent 自身失败
#
# 输出: <工作目录>/out/light-<时间>.out（完整输出）、out/light-receipt.txt（回执）；
#       结束时打印一行 LIGHT_DONE / LIGHT_QUOTA / LIGHT_CAP / LIGHT_EXIT。
#
# 安全：轻量子 agent 可能没有沙箱，也不经确认就执行工具。只在专用 git 工作区里跑，跑完主路由必须查
# git status，确认没碰可写路径以外的文件；它不提交，由主路由代提交。

set -u
WORK="${1:?用法: kick-light.sh <专用 worktree> <提示词文件> [秒]}"
PROMPT_FILE="${2:?}"
LIMIT="${3:-1200}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

[ -f "$ROOT/local.env" ] || { echo "LIGHT_EXIT 2 没有 local.env。复制 local.env.example，写上怎么调用你的子 agent"; exit 2; }
# shellcheck disable=SC1091
. "$ROOT/local.env"
type light_run > /dev/null 2>&1 || { echo "LIGHT_EXIT 2 local.env 里没有定义 light_run。轻量子 agent 是可选的，没有时小活给主力子 agent"; exit 2; }

[ "${LIGHT_USE_STRONG:-}" = 1 ] && LIGHT_MODEL="${LIGHT_STRONG_MODEL:-${LIGHT_MODEL:-}}"
[ -z "${LIGHT_MODEL:-}" ] && type light_latest_model > /dev/null 2>&1 && LIGHT_MODEL="$(light_latest_model 2>/dev/null)"
export LIGHT_MODEL="${LIGHT_MODEL:-}"
MAX="${LIGHT_DAILY_MAX:-8}"
LEDGER="${LIGHT_LEDGER:-$ROOT/light-ledger.tsv}"
PAUSE="${LIGHT_PAUSE_FILE:-$ROOT/light-paused-on}"
TODAY="$(date +%F)"

[ -f "$PROMPT_FILE" ] || { echo "LIGHT_EXIT 2 提示词文件不存在: $PROMPT_FILE"; exit 2; }
# 有的 CLI 只能从命令行参数收提示词，太长会被截断。细节写进文件让它自己读
[ "$(wc -c < "$PROMPT_FILE")" -le 12000 ] || { echo "LIGHT_EXIT 2 提示词超过 12KB，把细节写进文件让它自己读"; exit 2; }
PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"
if [ -f "$PAUSE" ] && [ "$(cat "$PAUSE")" = "$TODAY" ]; then
  echo "LIGHT_CAP 今天已因额度报错暂停（$PAUSE），明天再派或改由主力子 agent、主路由做"; exit 14
fi
[ -f "$LEDGER" ] || printf '日期\t时间\t工作目录\t提示词\t退出码\t秒\t工具调用\t回答条数\t会话\n' > "$LEDGER"
USED=$(awk -F'\t' -v d="$TODAY" '$1==d' "$LEDGER" | wc -l)
if [ "$USED" -ge "$MAX" ]; then
  echo "LIGHT_CAP 今天已调用 $USED 次，达到上限 $MAX（LIGHT_DAILY_MAX）"; exit 14
fi

cd "$WORK" || { echo "LIGHT_EXIT 2 进不去 $WORK"; exit 2; }
mkdir -p out
# out/ 是这个脚本放日志的目录，不能算进子 agent 的改动。写进 info/exclude，不改用户的 .gitignore
if EXCLUDE_FILE=$(git rev-parse --git-path info/exclude 2>/dev/null); then
  mkdir -p "$(dirname "$EXCLUDE_FILE")"
  grep -qxF "out/" "$EXCLUDE_FILE" 2>/dev/null || echo "out/" >> "$EXCLUDE_FILE"
fi

STAMP="$(date +%H%M%S)"
STREAM="out/light-$STAMP.out"
ERR="out/light-$STAMP.err"
RECEIPT="out/light-receipt.txt"
START=$(date +%s)
echo "LIGHT_START 今天第 $((USED + 1))/$MAX 次 模型=${LIGHT_MODEL:-默认} 上限=${LIMIT}s"
timeout "$LIMIT" bash "$HERE/adapter.sh" light_run "$PROMPT_FILE" < /dev/null > "$STREAM" 2> "$ERR"
CODE=$?
SECS=$(( $(date +%s) - START ))

TOOLS=0
if type light_tool_count > /dev/null 2>&1; then TOOLS="$(light_tool_count "$STREAM" 2>/dev/null || echo 0)"; fi
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\n' "$TODAY" "$(date +%T)" "$WORK" "$(basename "$PROMPT_FILE")" \
  "$CODE" "$SECS" "${TOOLS:-0}" >> "$LEDGER"

# 回执：能从输出里取最后一条回答就取，取不了就用整份输出
if type light_receipt > /dev/null 2>&1; then
  light_receipt "$STREAM" "$RECEIPT" 2>/dev/null || cp "$STREAM" "$RECEIPT"
else
  cp "$STREAM" "$RECEIPT"
fi

# 只看错误输出且要有明确措辞：裸的 429 会被输出里的 4294967294 这类数字误判
if grep -qiE "provider.auth_error|usage limit|rate limit|too many requests|quota exceeded|subscription does not have access|HTTP 429|status 429" "$ERR" 2>/dev/null; then
  echo "$TODAY" > "$PAUSE"
  echo "LIGHT_QUOTA 额度或权限报错，今天暂停派它：$(grep -hiE 'error' "$ERR" | head -1)"
  exit 13
fi
if [ "$CODE" -eq 0 ]; then
  echo "LIGHT_DONE ${SECS}s 工具调用 ${TOOLS:-0} 次 回执 $RECEIPT"
else
  echo "LIGHT_EXIT $CODE ${SECS}s $(tail -1 "$ERR" 2>/dev/null)"
fi
exit "$CODE"
