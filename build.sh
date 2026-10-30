#!/usr/bin/env bash
#
# 生成整合版 linux-tools.sh（方案一）：把 menu.sh 和所有子脚本合成一个文件。
#
# 用法：bash build.sh
#
# 修改了 menu.sh 或任何子脚本之后，都要重新运行一次，再把 linux-tools.sh 一起提交。
# 本脚本只读取仓库里的文本文件、写出 linux-tools.sh，不会修改系统，不需要 root。
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
