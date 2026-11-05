#!/usr/bin/env bash
# 打印工作目录的内容指纹，用来判断验证前后内容有没有变。
#
# 用法: fingerprint.sh <工作目录>
#
# 为什么不用 git status：已修改的文件再被改一次，git status 显示的还是"已修改"，看不出来。
# 哈希是把任意内容算成一串固定长度的字符，内容变一点，这串字符就完全不同。
#
# 打印三行，两次输出完全一样才算没变:
#   head=<当前提交号>
#   tracked=<已跟踪文件相对当前提交的全部改动的哈希>
#   untracked=<没被跟踪也没被忽略的新文件的内容哈希>
set -euo pipefail

cd "${1:?用法: fingerprint.sh <工作目录>}"

head=$(git rev-parse HEAD)
# --binary 让二进制文件的内容也算进去，否则它只输出"文件不同"这句话，内容再变也看不出来
# safecrlf=false 只是关掉换行符警告，Windows 上每个文件都报一遍，会淹没真正的错误
tracked=$(git -c core.safecrlf=false diff HEAD --binary | sha256sum | cut -d' ' -f1)
# -z 和 -0 用空字符分隔文件名，文件名里有空格或中文也不会被拆开；-r 表示没有文件时不运行 sha256sum
untracked=$(git ls-files -o --exclude-standard -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)

printf 'head=%s\ntracked=%s\nuntracked=%s\n' "$head" "$tracked" "$untracked"
