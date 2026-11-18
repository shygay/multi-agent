#!/usr/bin/env bash
# 装完自检：用假的子 agent 测脚本的控制流。不花额度，不需要登录，也不碰你的配置。
#
# 用法: self-check.sh
# 退出码: 0 全部通过 | 1 有项目不通过
#
# 它在临时目录里放一份副本，换上假的 local.env，再把 HOME 换成空目录，所以结果不受本机配置影响。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$(mktemp -d)"
trap 'rm -rf "$C"' EXIT
mkdir -p "$C/home"
cp -r "$ROOT" "$C/multi-agent"
rm -rf "$C/multi-agent/.git"
rm -f "$C/multi-agent/local.env" "$C/multi-agent/light-ledger.tsv" "$C/multi-agent/light-paused-on"
export HOME="$C/home"
M="$C/multi-agent"
K="$M/scripts"

BAD=0
check() { # 名称 实际 期望
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1：实际=[$2] 期望=[$3]"; BAD=$((BAD + 1)); fi
}

new_repo() {
  rm -rf "$1"; mkdir -p "$1"
  (
    cd "$1" || exit 1
    git init -q
    git config user.name 测试; git config user.email test@local
    printf 'export const v = 1;\n' > app.mjs
    printf '# 测试\n' > README.md
    git add app.mjs README.md
    git commit -q -m "基线"
  ) > /dev/null 2>&1
}

echo "=== 1 运行环境 ==="
check "bash 4 或更新" "$([ "${BASH_VERSINFO[0]}" -ge 4 ] && echo 是)" "是"
for tool in git timeout sha256sum iconv awk sed; do
  check "有 $tool" "$(command -v "$tool" > /dev/null 2>&1 && echo 有)" "有"
done
check "xargs 支持 -r" "$(printf '' | xargs -r echo 没跑 2>/dev/null; echo 支持)" "支持"

echo "=== 2 脚本语法 ==="
for f in "$K"/*.sh "$M"/evals/*.sh "$M/local.env.example"; do
  bash -n "$f" || { echo "FAIL 语法 $f"; BAD=$((BAD + 1)); }
done
echo "PASS 语法检查跑完"

echo "=== 3 还没配置时的报错 ==="
printf 'x\n' > "$C/p.md"
new_repo "$C/r0"
bash "$K/kick-read.sh" "$C/r0" "$C/p.md" "$C/out.txt" > /dev/null 2>&1
check "没有 local.env 时只读派工退出码" "$?" "2"
LOOP_TEST_CMD=true bash "$K/kick-loop.sh" "$C/r0" "$C/p.md" > /dev/null 2>&1
check "没有 local.env 时写入派工退出码" "$?" "2"
bash "$K/kick-light.sh" "$C/r0" "$C/p.md" > /dev/null 2>&1
check "没有 local.env 时轻量派工退出码" "$?" "2"

# 假的子 agent。接口和 local.env.example 一样，行为由 FAKE_ 开头的环境变量决定
cat > "$M/local.env" <<'EOF'
fake_step() { # 是否后续轮 结果文件
  case "$FAKE_MODE:$1" in
    normal:0)
      printf 'export const v = 2;\n' > app.mjs
      printf 'feat: 假提交\n' > .impl-commit-msg.txt
      printf '完成\n' > "$2" ;;
    fix:0)
      printf 'export const v = 3;\n' > app.mjs
      printf '第一轮\n' > "$2" ;;
    fix:1)
      printf 'export const v = 2;\n' > app.mjs
      printf 'feat: 修好了\n' > .impl-commit-msg.txt
      printf '修好了\n' > "$2" ;;
    blocked:0)
      printf 'export const v = 9;\n' > app.mjs
      printf '要改范围外的文件才能完成。\r\n\r\n`blocked`\r\n' > "$2" ;;
    lateblock:0)
      printf 'export const v = 3;\n' > app.mjs
      printf '第一轮\n' > "$2" ;;
    lateblock:1)
      printf '不改范围外的文件修不好。\nBLOCKED\n' > "$2" ;;
    mention:0)
      printf 'export const v = 2;\n' > app.mjs
      printf 'feat: 提到了这个词\n' > .impl-commit-msg.txt
      printf '这次没有 blocked，已完成。\n' > "$2" ;;
    quota:*)
      echo "You've hit your usage limit. try again at 19:44."
      exit 1 ;;
  esac
}
worker_run() {
  local mode="$1" work="$2" result="$3" prompt
  prompt="$(cat)"
  [ "${FAKE_SLEEP:-}" = 1 ] && exec sleep 30
  if [ "$mode" = read-only ]; then
    [ -n "${FAKE_READ_LOG:-}" ] && echo "$FAKE_READ_LOG"
    [ -n "${FAKE_READ_EXIT:-}" ] && exit "$FAKE_READ_EXIT"
    printf '%s\n' "${FAKE_VERDICT:-只读结果}" > "$result"
    exit 0
  fi
  echo "session id: fake-session"
  cd "$work" || exit 2
  case "$prompt" in
    *"上一轮的结果"*) fake_step 1 "$result" ;;
    *) fake_step 0 "$result" ;;
  esac
}
worker_resume() { fake_step 1 "$3"; }
worker_session_id() { grep -m1 -oE 'session id: [a-z-]+' "$1" | awk '{print $3}'; }
light_run() {
  printf '%s\n' "${LIGHT_MODEL:-默认}" > "$FAKE_ARGS"
  if [ "${FAKE_QUOTA:-}" = 1 ]; then echo "error: usage limit reached" >&2; exit 1; fi
  echo "假回答"
}
if [ "${FAKE_NO_RESUME:-}" = 1 ]; then unset -f worker_resume worker_session_id; fi
if [ -n "${FAKE_LATEST:-}" ]; then
  worker_latest_model() { echo "$FAKE_LATEST"; }
  light_latest_model() { echo "$FAKE_LATEST"; }
fi
EOF

echo "=== 4 内容指纹 ==="
new_repo "$C/fp"
printf 'two\n' > "$C/fp/app.mjs"
S1="$(git -C "$C/fp" status --porcelain)"; F1="$(bash "$K/fingerprint.sh" "$C/fp" 2>/dev/null)"
printf 'three\n' > "$C/fp/app.mjs"
S2="$(git -C "$C/fp" status --porcelain)"; F2="$(bash "$K/fingerprint.sh" "$C/fp" 2>/dev/null)"
check "已修改的文件再改一次，git status 看不出来" "$([ "$S1" = "$S2" ] && echo 相同)" "相同"
check "已修改的文件再改一次，指纹看得出来" "$([ "$F1" != "$F2" ] && echo 不同)" "不同"

echo "=== 5 只读派工 ==="
new_repo "$C/r2"
bash "$K/kick-read.sh" "$C/r2" "$C/p.md" "$C/read.txt" > /dev/null 2>&1
check "只读派工退出码" "$?" "0"
check "结果写到结果文件" "$(cat "$C/read.txt" 2>/dev/null)" "只读结果"
FAKE_SLEEP=1 READ_TIMEOUT=1 bash "$K/kick-read.sh" "$C/r2" "$C/p.md" "$C/read2.txt" > /dev/null 2>&1
check "超时退出码" "$?" "124"
FAKE_READ_LOG="正文提到 usage limit" bash "$K/kick-read.sh" "$C/r2" "$C/p.md" "$C/read3.txt" > /dev/null 2>&1
check "正文提到 usage limit 不算额度用完" "$?" "0"
FAKE_READ_LOG="You've hit your usage limit" FAKE_READ_EXIT=1 bash "$K/kick-read.sh" "$C/r2" "$C/p.md" "$C/read4.txt" > /dev/null 2>&1
check "真的额度用完退出码" "$?" "13"
FAKE_LATEST=new-model bash "$K/kick-read.sh" "$C/r2" "$C/p.md" "$C/read5.txt" > "$C/read5.out" 2>&1
check "没指定模型时用现查的最新型号" "$(grep -o '模型=[^ ]*' "$C/read5.out")" "模型=new-model"
FAKE_LATEST=new-model WORKER_MODEL=pinned bash "$K/kick-read.sh" "$C/r2" "$C/p.md" "$C/read6.txt" > "$C/read6.out" 2>&1
check "指定了模型时不现查" "$(grep -o '模型=[^ ]*' "$C/read6.out")" "模型=pinned"

echo "=== 6 独立验证：脚本的硬校验 ==="
verify() { # 名称 提交号 命令 假判读
  local dir="$C/v-$1"
  new_repo "$dir"
  printf '%s\n' "$3" > "$C/cmds-$1.txt"
  local sha="$2"
  [ "$sha" = HEAD ] && sha="$(git -C "$dir" rev-parse HEAD)"
  VERIFY_SHA="$sha" VERIFY_CMDS="$C/cmds-$1.txt" FAKE_VERDICT="$4" \
    bash "$K/kick-verify.sh" "$dir" "$C/p.md" "$C/e-$1" > /dev/null 2>&1
  VERIFY_RC=$?
  if [ -f "$C/e-$1/verdict.json" ]; then CALLED=调了模型; else CALLED=没调模型; fi
}
ALLPASS='{"status":"ready","criteria":[{"criterion":"a","result":"pass","evidence":"b"}],"notes":"","human_action":""}'
verify wrong 0000000 "" "$ALLPASS"
check "版本不对" "$VERIFY_RC:$CALLED" "20:没调模型"
verify cmdfail HEAD "false" "$ALLPASS"
check "验收命令失败" "$VERIFY_RC:$CALLED" "21:没调模型"
verify changed HEAD "echo x >> app.mjs" "$ALLPASS"
check "命令改了已跟踪文件" "$VERIFY_RC:$CALLED" "22:没调模型"
verify untracked HEAD "echo x > new.txt" "$ALLPASS"
check "命令新建了文件" "$VERIFY_RC:$CALLED" "22:没调模型"
verify good HEAD "true" "$ALLPASS"
check "全部通过" "$VERIFY_RC:$CALLED" "0:调了模型"
verify lie HEAD "true" '{"status":"ready","criteria":[{"criterion":"a","result":"not_verified","evidence":""}],"notes":"","human_action":""}'
check "模型写 ready 却有标准没核实，降级成 blocked" "$VERIFY_RC" "20"
verify empty HEAD "true" '{"status":"ready","criteria":[],"notes":"","human_action":""}'
check "模型写 ready 却没有任何标准，降级成 blocked" "$VERIFY_RC" "20"
verify lie2 HEAD "true" '{"status":"ready","criteria":[{"criterion":"a","result":"fail","evidence":""}],"notes":"","human_action":""}'
check "模型写 ready 却有标准不满足，降级成 failed" "$VERIFY_RC" "21"

echo "=== 7 轻量派工：记账、out 排除、回执、上限、额度暂停、强模型、现查型号 ==="
export FAKE_ARGS="$C/fake-args"
new_repo "$C/r1"
L="$M/light-ledger.tsv"
LIGHT_DAILY_MAX=1 bash "$K/kick-light.sh" "$C/r1" "$C/p.md" > /dev/null 2>&1
check "正常退出码" "$?" "0"
check "账本写在 skill 根目录" "$([ -f "$L" ] && echo 有)" "有"
check "out 不算改动" "$(git -C "$C/r1" status --short)" ""
check "回执写好" "$(tr -d '\r' < "$C/r1/out/light-receipt.txt" 2>/dev/null)" "假回答"
LIGHT_DAILY_MAX=1 bash "$K/kick-light.sh" "$C/r1" "$C/p.md" > /dev/null 2>&1
check "到单日上限退出码" "$?" "14"
LIGHT_DAILY_MAX=5 FAKE_QUOTA=1 bash "$K/kick-light.sh" "$C/r1" "$C/p.md" > /dev/null 2>&1
check "额度报错退出码" "$?" "13"
LIGHT_DAILY_MAX=5 bash "$K/kick-light.sh" "$C/r1" "$C/p.md" > /dev/null 2>&1
check "额度报错后当天暂停" "$?" "14"
rm -f "$M/light-paused-on"
LIGHT_DAILY_MAX=9 LIGHT_USE_STRONG=1 LIGHT_MODEL=weak LIGHT_STRONG_MODEL=strong bash "$K/kick-light.sh" "$C/r1" "$C/p.md" > /dev/null 2>&1
check "LIGHT_USE_STRONG 用强模型" "$(cat "$FAKE_ARGS")" "strong"
LIGHT_DAILY_MAX=9 FAKE_LATEST=new-light bash "$K/kick-light.sh" "$C/r1" "$C/p.md" > /dev/null 2>&1
check "轻量派工没指定模型时用现查的最新型号" "$(cat "$FAKE_ARGS")" "new-light"

echo "=== 8 写入派工：blocked 停下、out 不进提交、多轮、额度 ==="
loop() { # 场景
  new_repo "$C/r-$1"
  FAKE_MODE="$1" LOOP_TEST_CMD='grep -q "v = 2" app.mjs' \
    bash "$K/kick-loop.sh" "$C/r-$1" "$C/p.md" 3 > "$C/loop-$1.log" 2>&1
  LOOP_RC=$?
}
commits() { git -C "$C/r-$1" rev-list --count HEAD; }

loop normal
check "正常任务退出码" "$LOOP_RC" "0"
check "正常任务有新提交" "$(commits normal)" "2"
check "正常任务一轮通过" "$(grep -c '轮数=1' "$C/loop-normal.log")" "1"
check "提交只含 app.mjs（日志和提交消息文件都不进）" "$(git -C "$C/r-normal" show --name-only --format= HEAD)" "app.mjs"

loop fix
check "测试没过时交回去修，两轮通过" "$LOOP_RC:$(grep -c '轮数=2' "$C/loop-fix.log")" "0:1"

export FAKE_NO_RESUME=1
loop fix
check "不能续接会话时开新一轮，两轮通过" "$LOOP_RC:$(grep -c '轮数=2' "$C/loop-fix.log")" "0:1"
unset FAKE_NO_RESUME

loop blocked
check "报 blocked 时退出码" "$LOOP_RC" "15"
check "报 blocked 时没有新提交" "$(commits blocked)" "1"
check "报 blocked 时没跑测试" "$([ -f "$C/r-blocked/out/test.log" ] && echo 跑了 || echo 没跑)" "没跑"
check "报 blocked 时工作区保留" "$(git -C "$C/r-blocked" status --short)" " M app.mjs"

loop lateblock
check "第 2 轮才报 blocked 也会停下" "$LOOP_RC:$(commits lateblock)" "15:1"

loop mention
check "正文提到 blocked 不算卡住" "$LOOP_RC" "0"

loop quota
check "额度用完退出码" "$LOOP_RC:$(commits quota)" "13:1"

echo "=== 结果：不通过 $BAD 项 ==="
[ "$BAD" -eq 0 ]
