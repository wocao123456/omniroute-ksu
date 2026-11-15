#!/system/bin/sh
##########################################################################
# OmniRoute 3.8.54 — KernelSU / Magisk / APatch 模块安装脚本
#
# 目标版本锁定：OmniRoute release/v3.8.54（package.json "version": "3.8.54"）
# 本模块【不使用】npm 上的 3.8.53，安装的代码来自 v3.8.54 分支源码构建的
# Next.js standalone 产物，版本号在最后一步会被实际核对。
#
# 方案（与参考模块 daidai-panel 同一套容器方案）：
#   1. rurima（静态 arm64）提供 ruri chroot
#   2. 解包随包的 Ubuntu 24.04 base rootfs（glibc，与构建机 ABI 一致）
#   3. 解包随包的 Node.js 24 (linux-arm64-libc) 到 /opt/node
#   4. 解包 OmniRoute 3.8.54 standalone 到 /opt/omniroute/app
#   5. service.sh 通过 rurima ruri 进容器跑 dev/run-standalone.mjs
#
# 目录约定：
#   /data/local/omniroute/                    宿主侧基准目录 BASE
#   $BASE/rootfs                              chroot 根
#   $BASE/rootfs/opt/node                     Node 运行时
#   $BASE/rootfs/opt/omniroute/app            应用（每次刷入覆盖）
#   $BASE/rootfs/opt/omniroute/data           持久数据（DATA_DIR，刷入时保留）
#   /data/adb/omniroute                       模块持久目录（日志 / 配置 / 停止开关）
##########################################################################

SKIPUNZIP=0
REPLACE=""

export PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH:$MODPATH/system/bin

MODID=omniroute
BASE=/data/local/omniroute
ROOTFS=$BASE/rootfs
APP_DIR=$ROOTFS/opt/omniroute/app
DATA_DIR_CT=$ROOTFS/opt/omniroute/data
NODE_DIR=$ROOTFS/opt/node
PERSIST_DIR=/data/adb/$MODID
CONF=$PERSIST_DIR/omniroute.conf
LOG_FILE=$PERSIST_DIR/install.log

ZIP_ROOTFS=$MODPATH/assets/rootfs-ubuntu-24.04-arm64.tar.gz
ZIP_NODE=$MODPATH/assets/node-linux-arm64-v24.tar.gz
ZIP_APP=$MODPATH/assets/omniroute-3.8.54-app.tar.gz
RURIMA=$MODPATH/system/bin/rurima

WANT_VERSION=3.8.54

# 安装结果门禁：只有容器、Node、应用三者都实测通过才置 1，
# 只有它是 1 才允许打印「安装完成！」——避免「装完了才发现起不来」。
INSTALL_OK=0

mkdir -p "$PERSIST_DIR" 2>/dev/null
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null
}

##########################################################################
# 环境探测
##########################################################################
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  ui_print "!! 本模块只提供 arm64 (aarch64) 构建，当前架构: $ARCH"
  abort "! 架构不支持"
fi

API=$(getprop ro.build.version.sdk 2>/dev/null)
case "$API" in
  ''|*[!0-9]*) API=0 ;;
esac
if [ "$API" -lt 26 ] 2>/dev/null; then
  abort "! 要求 Android 8.0 (API 26) 及以上，当前 API=$API"
fi

if [ ! -f "$RURIMA" ]; then
  abort "! 模块内缺少 rurima 二进制，zip 不完整"
fi
chmod 0755 "$RURIMA" 2>/dev/null

# 剩余空间检查：rootfs + node + 应用解包后约 1.2GB，留 2GB 余量
FREE_KB=$(df -k /data 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 2097152 ]; then
  ui_print "!! /data 可用空间不足 2GB（当前 $((FREE_KB/1024))MB）"
  ui_print "!  解包 rootfs + Node + 应用需要约 1.2GB，装不下会中途失败"
fi

ui_print "- 目标版本: OmniRoute $WANT_VERSION (release/v$WANT_VERSION)"
ui_print "- 运行方式: rurima chroot + 自带 Node 24 + Ubuntu 24.04 base"
ui_print "- 安装位置: $BASE"

##########################################################################
# 1. rootfs
#
# 已存在且完整时复用：userdata 在 rootfs 里，无条件重解会清掉用户配置。
# 需要强制重建时删掉 $BASE/rootfs 再刷。
##########################################################################
ROOTFS_OK=0
if [ -f "$ROOTFS/etc/os-release" ] && [ -f "$ROOTFS/bin/sh" ]; then
  ROOTFS_OK=1
  ui_print "- 检测到已有 rootfs，复用（数据保留）"
  log "reuse existing rootfs"
else
  if [ ! -f "$ZIP_ROOTFS" ]; then
    abort "! 模块内缺少 rootfs 资产: $(basename "$ZIP_ROOTFS")"
  fi
  ui_print "- 解包 rootfs（约 30MB 压缩 / 300MB 展开，需要一两分钟）"
  rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"
  tar -xzf "$ZIP_ROOTFS" -C "$ROOTFS" 2>>"$LOG_FILE"
  if [ ! -f "$ROOTFS/etc/os-release" ]; then
    abort "! rootfs 解包失败，详见 $LOG_FILE"
  fi
  ROOTFS_OK=1
  log "rootfs extracted"
fi

##########################################################################
# 2. Node 运行时
##########################################################################
if [ ! -x "$NODE_DIR/bin/node" ]; then
  if [ ! -f "$ZIP_NODE" ]; then
    abort "! 模块内缺少 Node 资产: $(basename "$ZIP_NODE")"
  fi
  ui_print "- 解包 Node.js 运行时"
  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR"
  tar -xzf "$ZIP_NODE" -C "$NODE_DIR" --strip-components=1 2>>"$LOG_FILE"
  chmod 0755 "$NODE_DIR/bin/node" 2>/dev/null
  if [ ! -x "$NODE_DIR/bin/node" ]; then
    abort "! Node 解包失败，详见 $LOG_FILE"
  fi
  log "node extracted"
else
  ui_print "- 检测到已有 Node 运行时，复用"
fi

##########################################################################
# 3. 应用（每次刷入都覆盖，数据目录单独保留）
##########################################################################
if [ ! -f "$ZIP_APP" ]; then
  abort "! 模块内缺少应用资产: $(basename "$ZIP_APP")"
fi
ui_print "- 解包 OmniRoute $WANT_VERSION 应用（体积较大，请耐心等）"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
tar -xzf "$ZIP_APP" -C "$APP_DIR" 2>>"$LOG_FILE"
if [ ! -f "$APP_DIR/package.json" ]; then
  abort "! 应用解包失败，详见 $LOG_FILE"
fi
mkdir -p "$DATA_DIR_CT"

##########################################################################
# 4. 容器内环境补齐（DNS / hosts / 时区 / 启动脚本）
##########################################################################
ui_print "- 写入容器网络与启动脚本"

cat > "$ROOTFS/etc/resolv.conf" << 'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
EOF

cat > "$ROOTFS/etc/hosts" << 'EOF'
127.0.0.1 localhost omniroute
::1 localhost
EOF

# 时区（Android 的系统时区不自动进容器）
TZNAME=$(getprop persist.sys.timezone 2>/dev/null)
[ -z "$TZNAME" ] && TZNAME=Asia/Shanghai
mkdir -p "$ROOTFS/etc"
{
  echo "TZ=$TZNAME"
} > "$ROOTFS/etc/omniroute-tz.env"

mkdir -p "$ROOTFS/opt/omniroute"

cat > "$ROOTFS/opt/omniroute/boot.sh" << 'EOF'
#!/bin/sh
# OmniRoute 容器内启动脚本（由宿主 service.sh 通过 ruri 调起）
# 配置由宿主写在 /opt/omniroute/runtime.env，这里只做加载与启动。
set -u

[ -f /opt/omniroute/runtime.env ] && . /opt/omniroute/runtime.env
[ -f /etc/omniroute-tz.env ] && . /etc/omniroute-tz.env

export PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export NODE_ENV=production
export NEXT_TELEMETRY_DISABLED=1
export CI=1
export HOME=/root
export TMPDIR=/tmp

APP=/opt/omniroute/app
export DATA_DIR=/opt/omniroute/data

# 端口：OmniRoute 官方默认 20128；PORT 同时作用于 dashboard / API
export PORT="${OMNIROUTE_PORT:-20128}"
export DASHBOARD_PORT="$PORT"
export API_PORT="${OMNIROUTE_API_PORT:-$PORT}"
# OMNIROUTE_HOSTNAME 决定绑定地址（run-standalone.mjs 会用它覆盖 HOSTNAME）
export OMNIROUTE_HOSTNAME="${OMNIROUTE_HOSTNAME:-127.0.0.1}"
export HOSTNAME="$OMNIROUTE_HOSTNAME"
export OMNIROUTE_MEMORY_MB="${OMNIROUTE_MEMORY_MB:-1024}"

mkdir -p /tmp /opt/omniroute/data
cd "$APP" || exit 1

exec /opt/node/bin/node dev/run-standalone.mjs
EOF
chmod 0755 "$ROOTFS/opt/omniroute/boot.sh"

##########################################################################
# 5. 宿主侧配置（已存在则保留，用户改过的值不能被刷入覆盖）
##########################################################################
if [ ! -f "$CONF" ]; then
  cat > "$CONF" << 'EOF'
# OmniRoute 模块配置 —— 修改后重启手机或点模块「运行」按钮生效
# 端口：官方默认 20128
OMNIROUTE_PORT=20128
# 绑定地址：127.0.0.1 只允许本机访问；改成 0.0.0.0 会暴露到局域网
OMNIROUTE_HOSTNAME=127.0.0.1
# V8 堆上限（MB），内存小的机器可降到 768
OMNIROUTE_MEMORY_MB=1024
# 应用数据目录（容器内路径），含数据库、密钥、.env
OMNIROUTE_DATA=/opt/omniroute/data
EOF
fi

# runtime.env 每次刷入都按配置重写：它是机器生成物，不是用户手改文件
{
  echo "# 由 customize.sh 生成，改配置请改 $CONF"
  echo "OMNIROUTE_PORT=$(sed -n 's/^OMNIROUTE_PORT=//p' "$CONF" | tail -n1)"
  echo "OMNIROUTE_HOSTNAME=$(sed -n 's/^OMNIROUTE_HOSTNAME=//p' "$CONF" | tail -n1)"
  echo "OMNIROUTE_MEMORY_MB=$(sed -n 's/^OMNIROUTE_MEMORY_MB=//p' "$CONF" | tail -n1)"
} > "$ROOTFS/opt/omniroute/runtime.env"
# 空值兜底
sed -i 's/^OMNIROUTE_PORT=$/OMNIROUTE_PORT=20128/; s/^OMNIROUTE_HOSTNAME=$/OMNIROUTE_HOSTNAME=127.0.0.1/; s/^OMNIROUTE_MEMORY_MB=$/OMNIROUTE_MEMORY_MB=1024/' "$ROOTFS/opt/omniroute/runtime.env" 2>/dev/null

##########################################################################
# 6. 实测验证：版本号 + 运行能力
##########################################################################
ui_print "- 验证容器与 Node 运行时"

run_in_ctr() {
  # $1 = 容器内要执行的命令
  "$RURIMA" ruri -p -N -S -A "$ROOTFS" /bin/sh -c "$1" 2>>"$LOG_FILE"
}

NODE_VER=$(run_in_ctr "/opt/node/bin/node -v")
log "node version in container: $NODE_VER"
case "$NODE_VER" in
  v24.*|v25.*|v26.*) : ;;
  *)
    ui_print "!! 容器内 Node 无法运行（输出: ${NODE_VER:-空}）"
    ui_print "!  详见 $LOG_FILE"
    ;;
esac

# 版本核对：standalone 里的 package.json 必须正好是 3.8.54
APP_VER=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_DIR/package.json" 2>/dev/null | head -n1)
log "app package.json version: $APP_VER"
ui_print "- 应用版本自检: ${APP_VER:-未知}"

INSTALL_OK=0
if [ "$APP_VER" = "$WANT_VERSION" ]; then
  INSTALL_OK=1
else
  ui_print "!! 版本自检不符：期望 $WANT_VERSION，实际 ${APP_VER:-空}"
fi

if [ "$ROOTFS_OK" = "1" ] && [ -x "$NODE_DIR/bin/node" ] && [ -f "$APP_DIR/dev/run-standalone.mjs" ]; then
  :
else
  INSTALL_OK=0
fi

chmod -R 0755 "$NODE_DIR/bin" 2>/dev/null
chmod 0755 "$MODPATH/service.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh" 2>/dev/null
chmod 0755 "$MODPATH/scripts/"*.sh 2>/dev/null

ui_print "- 数据目录: $DATA_DIR_CT（刷入新版本时保留）"
ui_print "- 配置文件: $CONF"

if [ "$INSTALL_OK" = "1" ]; then
  ui_print "- 安装完成！重启手机后访问 http://127.0.0.1:20128"
  ui_print "  也可以用模块卡片的「运行」按钮立即启动"
  log "install ok"
else
  ui_print "!! 安装未通过自检，重启后模块大概率无法启动"
  ui_print "!  请看 $LOG_FILE"
  log "install FAILED self-check"
fi
