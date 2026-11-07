#!/usr/bin/env bash
#
# 生成整合版 linux-tools.sh（方案一）：把 menu.sh 和所有子脚本合成一个文件。
#
# 用法：bash build.sh
#
# 修改了 menu.sh、lib/ 或任何子脚本之后，都要重新运行一次，再把改动和 linux-tools.sh 一起提交。
# 它先把 lib/ 里的公共界面代码同步进 menu.sh 和各子脚本，再生成整合版。
# 本脚本只读写仓库里的文本文件，不会修改系统，不需要 root。
#
# 每个子脚本会变成一个函数，例如 Debian/clear.sh -> payload_Debian_clear_sh，
# 函数用带引号的 here-document 原样输出文件内容；menu.sh 里的 fetch_script 会优先用它们。

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OUT="linux-tools.sh"
MARKER="# @@LT_PAYLOADS@@"
DELIM="__LT_PAYLOAD_END__"

die() { echo "错误：$*" >&2; exit 1; }

grep -qxF "$MARKER" menu.sh || die "menu.sh 里找不到标记行：$MARKER"

shopt -s nullglob

# ---- 第一步：把 lib/ 里的公共代码同步进各脚本 ----
# 每个脚本都要能单独下载运行，所以公共的界面代码在每个脚本里各有一份，
# 夹在 "# >>> lib/xxx.sh >>>" 和 "# <<< lib/xxx.sh <<<" 两行之间。这里用 lib/ 的最新内容替换它们。
synced=0
for lib in lib/*.sh; do
  start="# >>> $lib >>>"
  end="# <<< $lib <<<"
  [[ $(head -n 1 "$lib") == "$start" && $(tail -n 1 "$lib") == "$end" ]] \
    || die "$lib 的第一行和最后一行必须是 $start / $end"
  for f in menu.sh Debian/*.sh ssh-check.sh; do
    grep -qxF "$start" "$f" || continue
    grep -qxF "$end" "$f" || die "$f 里有 $start 但没有 $end"
    awk -v lib="$lib" -v start="$start" -v end="$end" '
      $0 == start { while ((getline l < lib) > 0) print l; close(lib); skip = 1; next }
      skip && $0 == end { skip = 0; next }
      !skip { print }
    ' "$f" > "$f.sync"
    if cmp -s "$f.sync" "$f"; then
      rm -f "$f.sync"
    else
      cat "$f.sync" > "$f"   # 用 cat 写回，保留原文件的权限
      rm -f "$f.sync"
      bash -n "$f" || die "同步 $lib 后 $f 有语法错误"
      echo "已同步 $lib -> $f"
      synced=$(( synced + 1 ))
    fi
  done
done
echo "公共代码同步完成：更新了 $synced 处"

# ---- 第二步：生成整合版 ----
files=(Debian/* ssh-check.sh update-motd/*)
(( ${#files[@]} )) || die "没有找到任何子脚本"

for f in "${files[@]}"; do
  [[ -f $f ]] || die "不是普通文件：$f"
  # 文件里如果正好有一行等于结束标记，here-document 会提前结束
  ! grep -qxF "$DELIM" "$f" || die "$f 中包含结束标记 $DELIM，请换一个标记"
  ! grep -q $'\r' "$f" || die "$f 是 Windows 换行（CRLF），请先转换成 LF"
done

tmp="$OUT.tmp"
{
  head -n 1 menu.sh
  echo "#"
  echo "# ============================================================================="
  echo "#  Linux-tools 整合版：所有子脚本都已内置在本文件里，单独下载这一个文件即可使用。"
  echo "#  本文件由 build.sh 自动生成，请不要直接修改。"
  echo "#  要改功能，请修改 menu.sh 或对应的子脚本，然后重新运行 bash build.sh。"
  echo "# ============================================================================="
  # menu.sh 标记行之前的部分（去掉第一行 shebang）
  sed -n "2,/^${MARKER}\$/p" menu.sh | sed '$d'

  echo "# ---- 以下为内置子脚本（共 ${#files[@]} 个） ----"
  for f in "${files[@]}"; do
    printf '%s() {\ncat <<'"'"'%s'"'"'\n' "payload_${f//[^A-Za-z0-9]/_}" "$DELIM"
    cat "$f"
    # 文件末尾没有换行时补一个，否则结束标记会和最后一行连在一起
    [[ -z $(tail -c 1 "$f") ]] || echo
    printf '%s\n}\n\n' "$DELIM"
  done

  # menu.sh 标记行之后的部分
  sed "1,/^${MARKER}\$/d" menu.sh
} > "$tmp"

bash -n "$tmp" || { rm -f "$tmp"; die "生成的文件有语法错误"; }
mv -f "$tmp" "$OUT"
chmod +x "$OUT"
echo "已生成 $OUT：内置 ${#files[@]} 个子脚本，$(wc -c < "$OUT") 字节"
