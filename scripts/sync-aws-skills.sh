#!/usr/bin/env bash
# 维护者脚本：从 aws/agent-toolkit-for-aws 的固定 commit 同步运维 skills 到 vendor/agent-toolkit-for-aws。
# 安装器只从该目录复制，不联网；升级 skills 时运行本脚本、审阅 git diff 后提交。
#   bash scripts/sync-aws-skills.sh [REF]     # 默认使用 SOURCE 中记录的 ref
# 同步的是 full 集合（lib/skills.sh 的 PI_SKILLS_FULL）；安装时默认只装其中的 core 子集。
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/skills.sh
. "$ROOT/lib/skills.sh"

VENDOR="$ROOT/$PI_SKILLS_VENDOR_REL"
REPO="${PI_AWS_TOOLKIT_REPO:-aws/agent-toolkit-for-aws}"
REF="${1:-$(vendor_field "$VENDOR" REF)}"
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || die "REF 必须是 40 位 commit SHA（当前: ${REF:-空}）"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "非法的仓库名: $REPO"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
log_info "下载 $REPO@${REF:0:7}"
download "https://codeload.github.com/$REPO/tar.gz/$REF" "$work/toolkit.tgz" || die "下载失败"
mkdir -p "$work/src" "$work/stage/skills"
tar -xzf "$work/toolkit.tgz" -C "$work/src" --no-same-owner --no-same-permissions
src="$(find "$work/src" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -d "$src/skills" ] || die "压缩包中没有 skills 目录"

for s in $PI_SKILLS_FULL; do
  [ -d "$src/skills/$s" ] || die "上游未找到 skill: $s"
  mkdir -p "$work/stage/skills/$(dirname "$s")"
  cp -R "$src/skills/$s" "$work/stage/skills/$s"
done
mkdir -p "$work/stage/rules"
for f in rules/aws-agent-rules.md LICENSE NOTICE; do
  [ -f "$src/$f" ] && [ ! -L "$src/$f" ] || die "上游缺少 $f（或为符号链接）"
  cp "$src/$f" "$work/stage/$f"
done
# 不保留符号链接（可指向任意文件）与可执行位
find "$work/stage" -type l -delete
find "$work/stage" -type f -exec chmod 0644 {} +

manifest="$(skills_manifest "$work/stage")"
{
  printf '# 由 scripts/sync-aws-skills.sh 生成，请勿手工编辑。MANIFEST 为 skills/ 与 rules/ 的内容清单哈希（见 lib/skills.sh）。\n'
  printf 'REPO=%s\nREF=%s\nSKILLS=%s\nMANIFEST=%s\n' "$REPO" "$REF" "$PI_SKILLS_FULL" "$manifest"
} >"$work/stage/SOURCE"

rm -rf "$VENDOR"
mkdir -p "$(dirname "$VENDOR")"
mv "$work/stage" "$VENDOR"
log_info "已同步 $(find "$VENDOR/skills" -name SKILL.md | wc -l | tr -d ' ') 个 skills 到 ${VENDOR#"$ROOT"/}（manifest ${manifest:0:12}…），请审阅 git diff 后提交"
