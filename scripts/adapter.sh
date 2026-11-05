#!/usr/bin/env bash
# 在子进程里调用 local.env 定义的函数。
#
# 为什么要多这一层：shell 函数不能直接交给 timeout，放进子进程才能设墙钟上限。
#
# 用法: adapter.sh <函数名> [参数...]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../local.env" || exit 2
"$@"
