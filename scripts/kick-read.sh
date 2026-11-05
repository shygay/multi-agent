#!/usr/bin/env bash
# 派一个只读任务给主力子 agent：它能读文件、下结论，但写不了任何东西。
# 只读靠沙箱保证，不靠提示词。怎么调用它写在 local.env 的 worker_run 里。
#
# 用法: kick-read.sh <工作目录> <提示词文件> <结果文件>
# 路径都用绝对路径，结果文件放在工作区外。
#
# 环境变量（也可以写进 local.env，命令行上的优先）:
#   WORKER_MODEL   不设时用子 agent 自己的默认模型
#   WORKER_EFFORT  默认 medium
#   READ_TIMEOUT   墙钟上限（秒），默认 1200
#   READ_SCHEMA    JSON schema 文件，要求按固定格式输出（可空）
#
# 退出码: 0 完成 | 13 额度用完（不要重试）| 124 超时 | 2 参数或配置错误 | 其它 子 agent 自身失败
# 结束时打印一行 READ_DONE / READ_QUOTA / READ_EXIT。日志在 <结果文件>.log。
set -u

WORK="${1:?用法: kick-read.sh <工作目录> <提示词文件> <结果文件>}"
PROMPT="${2:?}"
OUT="${3:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f "$PROMPT" ] || { echo "READ_EXIT 2 提示词文件不存在: $PROMPT"; exit 2; }
[ -f "$HERE/../local.env" ] || { echo "READ_EXIT 2 没有 local.env。复制 local.env.example，写上怎么调用你的子 agent"; exit 2; }
# shellcheck disable=SC1091
. "$HERE/../local.env"
type worker_run > /dev/null 2>&1 || { echo "READ_EXIT 2 local.env 里没有定义 worker_run，见 local.env.example"; exit 2; }

export WORKER_EFFORT="${WORKER_EFFORT:-medium}"
export WORKER_MODEL="${WORKER_MODEL:-}"
LIMIT="${READ_TIMEOUT:-1200}"
LOG="$OUT.log"

# 提示词走标准输入：走命令行参数在 Windows 上有长度上限，派工单一长就会失败
timeout "$LIMIT" bash "$HERE/adapter.sh" worker_run read-only "$WORK" "$OUT" "${READ_SCHEMA:-}" < "$PROMPT" > "$LOG" 2>&1
CODE=$?

# 只在子 agent 非正常结束时才认额度报错：日志里有它的正文，调研内容本身可能提到这个词
if [ "$CODE" -ne 0 ] && grep -qiE "usage limit" "$LOG" 2>/dev/null; then
  echo "READ_QUOTA 子 agent 额度用完，不要重试，主路由接手：$(grep -oiE 'try again at [^.]*' "$LOG" | tail -1)"
  exit 13
fi
MODEL_NOTE="${WORKER_MODEL:-默认}"
if [ "$CODE" -eq 0 ]; then
  echo "READ_DONE 模型=$MODEL_NOTE 强度=$WORKER_EFFORT 结果=$OUT"
else
  echo "READ_EXIT $CODE 模型=$MODEL_NOTE 强度=$WORKER_EFFORT 日志=$LOG"
fi
exit "$CODE"
