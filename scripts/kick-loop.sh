#!/usr/bin/env bash
# 拉起主力子 agent（沙箱内）写代码；它每写完一轮，本脚本在沙箱外跑构建和验收测试，
# 把结果交回去让它修；直到测试通过或到轮数上限，最后代它提交。
#
# 为什么在沙箱外跑测试：子 agent 在沙箱里常常跑不了构建或测试（写不了产物、起不了子进程），
# 自测只能靠猜。曾实测过沙箱里退出码正常、报告全部成功，读回产物却是空的。
# 所以把"构建 + 测试"这两件固定的事放到沙箱外跑，沙箱本身保持开着。
#
# 只在专用 worktree 里跑：提交时用 git add -A，在主工作目录跑会把别人没提交的文件一起带上。
#
# 用法: kick-loop.sh <专用 worktree> <提示词文件> [最大轮数=3]
#
# 环境变量（也可以写进 local.env，命令行上的优先）:
#   LOOP_TEST_CMD   验收测试命令，退出码 0 = 通过（必填）
#   LOOP_BUILD_CMD  构建命令（可空）
#   LOOP_WORK_DIR   反馈与日志的存放目录（相对工作目录），默认 out。脚本会把它排除出提交
#   WORKER_MODEL    不设时用子 agent 自己的默认模型
#   WORKER_EFFORT   不设时用子 agent 自己的默认强度
#   KICK_TIMEOUT    每轮墙钟上限（秒），默认 3600
#   IMPL_AUTHOR     代提交时的 author，默认 "Sub-agent <sub-agent@local>"
#
# 退出码: 0 测试通过且已提交 | 10 没有任何改动 | 11 提交失败 | 12 到轮数上限测试仍未通过（已提交，主路由决定）
#         13 子 agent 额度用完（不提交，不要重试，主路由接手）
#         15 子 agent 报 blocked（不提交，工作区保留，主路由看回执后决定）
#         2 参数或配置错误 | 124 超时 | 其它 子 agent 自身失败
#
# 日志里 LOOP 开头的行是进度标记；KICK_ 开头的行只在结束时输出。
set -u

IMPL_DIR="${1:?用法: kick-loop.sh <专用 worktree> <提示词文件> [最大轮数]}"
PROMPT_FILE="${2:?}"
MAX_ROUNDS="${3:-3}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f "$HERE/../local.env" ] || { echo "KICK_ERROR 没有 local.env。复制 local.env.example，写上怎么调用你的子 agent"; exit 2; }
# shellcheck disable=SC1091
. "$HERE/../local.env"
type worker_run > /dev/null 2>&1 || { echo "KICK_ERROR local.env 里没有定义 worker_run，见 local.env.example"; exit 2; }

: "${LOOP_TEST_CMD:?必须设置 LOOP_TEST_CMD（验收测试命令，退出码 0 = 通过）}"
LOOP_BUILD_CMD="${LOOP_BUILD_CMD:-}"
LOOP_WORK_DIR="${LOOP_WORK_DIR:-out}"
TIMEOUT="${KICK_TIMEOUT:-3600}"
IMPL_AUTHOR="${IMPL_AUTHOR:-Sub-agent <sub-agent@local>}"
export WORKER_MODEL="${WORKER_MODEL:-}"
export WORKER_EFFORT="${WORKER_EFFORT:-}"

[ -f "$PROMPT_FILE" ] || { echo "KICK_ERROR 提示词文件不存在: $PROMPT_FILE"; exit 2; }
# 进工作目录之前转成绝对路径，否则相对路径到了里面就找不到了
PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"
IMPL_DIR="$(cd "$IMPL_DIR" 2>/dev/null && pwd)" || { echo "KICK_ERROR 进不去工作目录"; exit 2; }
cd "$IMPL_DIR" || exit 2
mkdir -p "$LOOP_WORK_DIR"
FEEDBACK="$LOOP_WORK_DIR/loop-feedback.txt"
RECEIPT="$LOOP_WORK_DIR/receipt.txt"
MSG_FILE=".impl-commit-msg.txt"

# 日志和提交消息文件不能进提交。写进 info/exclude 而不是 .gitignore：这样不改用户的仓库文件，
# 用户的 .gitignore 没写 out/ 时也不会把日志提交进去。
EXCLUDE_FILE=$(git rev-parse --git-path info/exclude) || { echo "KICK_ERROR 工作目录不是 git 仓库"; exit 2; }
mkdir -p "$(dirname "$EXCLUDE_FILE")"
for pat in "$MSG_FILE" "$LOOP_WORK_DIR/"; do
  grep -qxF "$pat" "$EXCLUDE_FILE" 2>/dev/null || echo "$pat" >> "$EXCLUDE_FILE"
done

# 子 agent 非正常结束时调用。额度用完单独报 KICK_QUOTA（退出码 13），重试没用。$1 = 退出码，$2 = 本轮日志，$3 = 轮次说明
fail_exit() {
  if grep -qiE "usage limit" "$2" 2>/dev/null; then
    echo "KICK_QUOTA 子 agent 额度用完（$3），不提交，主路由接手：$(grep -oiE 'try again at [^.]*' "$2" | tail -1)"
    exit 13
  fi
  echo "KICK_EXIT=$1 子 agent $3 非正常结束，不提交"
  exit "$1"
}

# 回执最后一个非空行只写 blocked，就算子 agent 报告卡住。
# 这时不能接着叫它修：它可能正是因为要改范围外的文件才停下来，再催就是把它推向越界。
is_blocked() {
  [ -f "$RECEIPT" ] || return 1
  local last
  last="$(tr -d '\r' < "$RECEIPT" | grep -v '^[[:space:]]*$' | tail -1 | tr -d '[:space:]`*' | tr '[:upper:]' '[:lower:]')"
  [ "$last" = "blocked" ]
}

# 沙箱外构建 + 测试。结果写进 $FEEDBACK，返回 0 表示通过。
build_and_test() {
  {
    if [ -n "$LOOP_BUILD_CMD" ]; then
      echo "### $LOOP_BUILD_CMD"
      bash -c "$LOOP_BUILD_CMD" > "$LOOP_WORK_DIR/build.log" 2>&1; local brc=$?
      echo "退出码 $brc"; tail -25 "$LOOP_WORK_DIR/build.log"
      [ "$brc" -ne 0 ] && return 1
      echo
    fi
    echo "### $LOOP_TEST_CMD"
    bash -c "$LOOP_TEST_CMD" > "$LOOP_WORK_DIR/test.log" 2>&1; local trc=$?
    echo "退出码 $trc"; head -120 "$LOOP_WORK_DIR/test.log"
    return "$trc"
  } > "$FEEDBACK" 2>&1
}

# ---- 第 1 轮
echo "LOOP 第 1 轮：子 agent 写代码（沙箱内）"
# 标准输入必须是个会结束的文件：stdin 一直开着时，有的 CLI 会一直等，看起来和"正在干活"一模一样。
timeout "$TIMEOUT" bash "$HERE/adapter.sh" worker_run workspace-write "$IMPL_DIR" "$RECEIPT" "" \
  < "$PROMPT_FILE" 2>&1 | tee "$LOOP_WORK_DIR/round1.log"
rc=${PIPESTATUS[0]}
[ "$rc" -ne 0 ] && fail_exit "$rc" "$LOOP_WORK_DIR/round1.log" "第 1 轮"

# 能续接同一个会话就续接，它还记得上一轮做了什么。不能续接就开新一轮，把原派工单和反馈一起发过去。
SESSION=""
if type worker_resume > /dev/null 2>&1 && type worker_session_id > /dev/null 2>&1; then
  SESSION="$(worker_session_id "$LOOP_WORK_DIR/round1.log")"
fi
[ -n "$SESSION" ] && echo "LOOP 会话 $SESSION"

next_round() { # $1 = 反馈文字，$2 = 本轮日志
  local round_rc
  if [ -n "$SESSION" ]; then
    # < /dev/null 同样是为了不让它等标准输入
    timeout "$TIMEOUT" bash "$HERE/adapter.sh" worker_resume "$SESSION" "$1" "$RECEIPT" < /dev/null 2>&1 | tee "$2"
    round_rc=${PIPESTATUS[0]}
  else
    { cat "$PROMPT_FILE"; printf '\n\n# 上一轮的结果\n\n%s\n' "$1"; } > "$LOOP_WORK_DIR/next-prompt.md"
    timeout "$TIMEOUT" bash "$HERE/adapter.sh" worker_run workspace-write "$IMPL_DIR" "$RECEIPT" "" \
      < "$LOOP_WORK_DIR/next-prompt.md" 2>&1 | tee "$2"
    round_rc=${PIPESTATUS[0]}
  fi
  return "$round_rc"
}

round=1; passed=0
while true; do
  if is_blocked; then
    echo "KICK_BLOCKED 子 agent 第 $round 轮报 blocked，不提交，工作区保留。回执: $IMPL_DIR/$RECEIPT"
    exit 15
  fi
  echo "LOOP 第 $round 轮结束：沙箱外构建 + 测试"
  if build_and_test; then passed=1; else passed=0; fi
  echo "LOOP 测试$([ $passed = 1 ] && echo 通过 || echo 未通过)：$(grep -E '退出码' "$FEEDBACK" | tr '\n' ' ' | cut -c1-120)"

  [ "$passed" = 1 ] && break
  [ "$round" -ge "$MAX_ROUNDS" ] && break
  round=$((round + 1))

  # 去掉非法 UTF-8：测试输出混进别的编码时，有的 CLI 会拒收参数
  ask="包装脚本在沙箱外替你跑了构建和验收测试，结果如下。请据此修复，只改可写路径内的文件，不要尝试在沙箱里构建。不改范围外的文件就修不好时，不要动手，在最后一条消息的最后一行只写 blocked。修完更新 $MSG_FILE 和回执，然后结束本轮，包装脚本会再跑一遍。

$(iconv -c -f UTF-8 -t UTF-8 "$FEEDBACK")"
  echo "LOOP 第 $round 轮：把结果交回子 agent"
  next_round "$ask" "$LOOP_WORK_DIR/round$round.log"
  rc=$?
  [ "$rc" -ne 0 ] && fail_exit "$rc" "$LOOP_WORK_DIR/round$round.log" "第 $round 轮"
done

# ---- 代它提交：作者写子 agent，提交者留本机身份。沙箱通常不让它写 .git，所以它自己提交不了
git add -A
if git diff --cached --quiet; then echo "KICK_NOCHANGE 子 agent 跑完了，但没有任何改动"; exit 10; fi
if [ -s "$MSG_FILE" ]; then
  sed -i '1s/^\xEF\xBB\xBF//' "$MSG_FILE"   # 有的工具写的 UTF-8 带 BOM
  git commit -q --author="$IMPL_AUTHOR" -F "$MSG_FILE"; crc=$?; rm -f "$MSG_FILE"
else
  git commit -q --author="$IMPL_AUTHOR" -m "impl: 未提供提交消息（见回执）"; crc=$?
  echo "LOOP 子 agent 没写 $MSG_FILE，用了占位消息"
fi
[ "$crc" -ne 0 ] && { echo "KICK_COMMITFAIL 提交失败，退出码 $crc"; exit 11; }
echo "KICK_COMMITTED $(git rev-parse HEAD) 轮数=$round 测试=$([ $passed = 1 ] && echo 通过 || echo 未通过)"
if [ "$passed" = 1 ]; then echo "KICK_EXIT=0"; exit 0; fi
echo "KICK_EXIT=12 到轮数上限测试仍未通过"; exit 12
