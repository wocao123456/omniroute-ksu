#!/bin/bash
##########################################################################
# 构建 OmniRoute KSU 模块 zip
#
# 用法:
#   ./build-module.sh [仓库路径] [输出目录]
#
# 前置条件（在 arm64 Linux 上）：
#   REPO 里已经跑过
#     npm ci --include=optional --no-audit --no-fund --legacy-peer-deps --ignore-scripts
#     OMNIROUTE_USE_TURBOPACK=0 npm run build
#
# 脚本会依次：
#   1. 校验仓库 package.json 的 version 必须正好是 3.8.54（不是就退出）
#   2. 把 .build/next/standalone 打成 assets/omniroute-3.8.54-app.tar.gz
#   3. 校验 rootfs / node 资产存在
#   4. 生成 OmniRoute-3.8.54-ksu.zip 并打印 sha256
##########################################################################
set -euo pipefail

WANT_VERSION=3.8.54
MODDIR=$(cd "$(dirname "$0")" && pwd)
REPO=${1:-/root/workspace/omniroute}
OUTDIR=${2:-$MODDIR/dist}
ASSETS=$MODDIR/assets
APP_TGZ=$ASSETS/omniroute-$WANT_VERSION-app.tar.gz
STANDALONE=$REPO/.build/next/standalone

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

say "仓库: $REPO"

# ---- 1. 版本校验 --------------------------------------------------------
[ -f "$REPO/package.json" ] || die "找不到 $REPO/package.json"
REPO_VER=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO/package.json" | head -n1)
say "package.json version = $REPO_VER"
[ "$REPO_VER" = "$WANT_VERSION" ] || die "版本不符：期望 $WANT_VERSION，实际 $REPO_VER（不允许打成 3.8.53）"

if [ -d "$REPO/.git" ]; then
  BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
  COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
  say "git 分支 $BRANCH @ $COMMIT"
fi

# ---- 2. standalone 产物 -------------------------------------------------
[ -f "$STANDALONE/server.js" ] || die "缺少 $STANDALONE/server.js，先在仓库里跑 npm run build"
[ -f "$STANDALONE/dev/run-standalone.mjs" ] || die "standalone 缺少 dev/run-standalone.mjs"
APP_VER=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$STANDALONE/package.json" | head -n1)
say "standalone version = ${APP_VER:-?}"
[ "$APP_VER" = "$WANT_VERSION" ] || die "standalone 版本不符：${APP_VER:-空}"

say "打包应用产物（这一步要几分钟，产物几百 MB）"
mkdir -p "$ASSETS"
rm -f "$APP_TGZ"
tar -czf "$APP_TGZ" -C "$STANDALONE" .
say "应用包: $(du -h "$APP_TGZ" | cut -f1)  $APP_TGZ"

# ---- 3. 其它资产 -------------------------------------------------------
[ -f "$ASSETS/rootfs-ubuntu-24.04-arm64.tar.gz" ] || die "缺少 rootfs 资产"
[ -f "$ASSETS/node-linux-arm64-v24.tar.gz" ] || die "缺少 node 资产"
[ -x "$MODDIR/system/bin/rurima" ] || die "缺少 rurima 二进制"

# 权限：脚本必须可执行
chmod 0755 "$MODDIR/customize.sh" "$MODDIR/service.sh" "$MODDIR/action.sh" \
           "$MODDIR/uninstall.sh" "$MODDIR/scripts/"*.sh "$MODDIR/system/bin/rurima"

# ---- 4. 打 zip ---------------------------------------------------------
mkdir -p "$OUTDIR"
ZIP=$OUTDIR/OmniRoute-$WANT_VERSION-ksu.zip
rm -f "$ZIP"
say "生成 $ZIP"
(
  cd "$MODDIR"
  zip -r -q -9 "$ZIP" \
    META-INF module.prop customize.sh service.sh action.sh uninstall.sh \
    README.md scripts system assets
)
say "完成: $(du -h "$ZIP" | cut -f1)"
command -v sha256sum >/dev/null && sha256sum "$ZIP"
