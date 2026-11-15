#!/system/bin/sh
##########################################################################
# OmniRoute 3.8.54 — 卸载脚本
#
# 默认清理：
#   - 运行中的 OmniRoute 进程（含守护）
#   - 容器目录 /data/local/omniroute（rootfs + Node + 应用 + 数据）
#   - 持久目录 /data/adb/omniroute（配置 / 日志）
#
# 想保留数据（数据库、密钥、.env）以便重装后继续用，卸载前先执行：
#   su -c "mkdir -p /data/adb/omniroute && touch /data/adb/omniroute/.keep_on_uninstall"
##########################################################################

ROOTFS=/data/local/omniroute
PERSIST=/data/adb/omniroute
KEEP_FLAG=$PERSIST/.keep_on_uninstall
STOP_FLAG=$PERSIST/stopped
GEN_FILE=$PERSIST/watchdog.gen
TAG=omniroute-uninstall

# 安全守卫：ROOTFS 为空或 "/" 时绝不往下走（防变量拼错变成删根目录）
case "$ROOTFS" in
  ""|"/"|"/data"|"/data/local") _log "ROOTFS 非法（$ROOTFS），中止"; exit 1 ;;
esac

_log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
  log -t "$TAG" "$1" 2>/dev/null
}

_log "卸载开始"

# 0. 停止开关 + 删代次标记，让守护自退
mkdir -p "$PERSIST" 2>/dev/null
printf '%s\n' "stopped by uninstall.sh at $(date '+%Y-%m-%d %H:%M:%S')" > "$STOP_FLAG" 2>/dev/null
rm -f "$GEN_FILE" 2>/dev/null

# 1. 停进程
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  [ -r "/proc/$pid/cmdline" ] || continue
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "run-standalone.mjs" && kill "$pid" 2>/dev/null
done
sleep 1
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  [ -r "/proc/$pid/cmdline" ] || continue
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "run-standalone.mjs" && kill -9 "$pid" 2>/dev/null
done

# 2. 清理容器目录（保留数据时只删代码，留下 data）
if [ -f "$KEEP_FLAG" ]; then
  _log "检测到保留标记，只删除应用本体，保留数据"
  rm -rf "$ROOTFS/opt/omniroute/app" 2>/dev/null
  rm -rf "$ROOTFS/opt/node" 2>/dev/null
  rmdir "$ROOTFS/opt/omniroute" 2>/dev/null
  _log "数据仍在: $ROOTFS/opt/omniroute/data"
  _log "彻底删除: su -c \"rm -rf $ROOTFS $PERSIST\""
else
  _log "清理 $ROOTFS"
  rm -rf "$ROOTFS" 2>/dev/null
  _log "清理 $PERSIST"
  rm -rf "$PERSIST" 2>/dev/null
fi

# 3. 无条件收口（放在保留标记判断之外）
rm -f "$GEN_FILE" 2>/dev/null
rm -f "$STOP_FLAG" 2>/dev/null
rm -f /data/adb/service.d/omniroute.sh 2>/dev/null
rm -f /data/local/tmp/omniroute.* 2>/dev/null

_log "卸载完成；重启后模块目录会被 root 管理器自动清除"
