#!/system/bin/sh
##########################################################################
# OmniRoute 3.8.54 — late_start service
#
# 通过 rurima ruri 进入 Ubuntu 24.04 容器（chroot，不建 namespace）启动
# Next.js standalone server（dev/run-standalone.mjs）。
#
# chroot 没有 PID namespace：容器里的 node 在宿主 /proc 里同样可见，
# 所以「是否已在运行」既可用 /proc/net/tcp 判断端口，也可用 pgrep。
##########################################################################

export PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

MODDIR=${MODDIR:-/data/adb/modules/omniroute}
[ ! -d "$MODDIR" ] && MODDIR=/data/adb/magisk/modules/omniroute
[ ! -d "$MODDIR" ] && MODDIR=/sbin/.magisk/modules/omniroute
[ ! -d "$MODDIR" ] && MODDIR=$(dirname "$0")

BASE=/data/local/omniroute
ROOTFS=$BASE/rootfs
PERSIST=/data/adb/omniroute
CONF=$PERSIST/omniroute.conf
LOG=$PERSIST/service.log
APP_LOG=$PERSIST/app.log
STOP_FLAG=$PERSIST/stopped
GEN_FILE=$PERSIST/watchdog.gen
PID_FILE=$PERSIST/omniroute.pid
RURIMA=$MODDIR/system/bin/rurima
BOOT=/opt/omniroute/boot.sh

mkdir -p "$PERSIST"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG" 2>/dev/null
}

# 日志滚动
for f in "$LOG" "$APP_LOG"; do
  if [ -f "$f" ]; then
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [ "${size:-0}" -gt 2097152 ] && mv -f "$f" "$f.old" 2>/dev/null
  fi
done

# ---- 手动停止开关：存在则不启动（跨重启保持）---------------------------
if [ -f "$STOP_FLAG" ]; then
  log "检测到停止开关 $STOP_FLAG，跳过启动"
  exit 0
fi

if [ ! -f "$ROOTFS/etc/os-release" ]; then
  log "!! 找不到 rootfs: $ROOTFS，模块可能未完成安装，请重装模块"
  exit 1
fi
if [ ! -x "$RURIMA" ]; then
  log "!! 找不到 rurima: $RURIMA"
  exit 1
fi
chmod 0755 "$RURIMA" 2>/dev/null

# ---- 配置 --------------------------------------------------------------
OMNIROUTE_PORT=20128
OMNIROUTE_HOSTNAME=127.0.0.1
OMNIROUTE_MEMORY_MB=1024
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

case "$OMNIROUTE_PORT" in
  ''|*[!0-9]*) log "!! 配置端口非法（$OMNIROUTE_PORT），回退 20128"; OMNIROUTE_PORT=20128 ;;
esac
[ "$OMNIROUTE_PORT" -ge 1 ] 2>/dev/null || OMNIROUTE_PORT=20128
[ "$OMNIROUTE_PORT" -le 65535 ] 2>/dev/null || OMNIROUTE_PORT=20128
case "$OMNIROUTE_HOSTNAME" in
  ''|*[!0-9a-zA-Z.:_-]*) OMNIROUTE_HOSTNAME=127.0.0.1 ;;
esac
case "$OMNIROUTE_MEMORY_MB" in
  ''|*[!0-9]*) OMNIROUTE_MEMORY_MB=1024 ;;
esac

# 每次启动按配置重写容器内 runtime.env（它是生成物，不是用户手改文件）
mkdir -p "$ROOTFS/opt/omniroute"
cat > "$ROOTFS/opt/omniroute/runtime.env" << EOF
OMNIROUTE_PORT=$OMNIROUTE_PORT
OMNIROUTE_HOSTNAME=$OMNIROUTE_HOSTNAME
OMNIROUTE_MEMORY_MB=$OMNIROUTE_MEMORY_MB
EOF

# ---- 端口监听探测（不依赖 nc，直接读 /proc/net/tcp*）-------------------
port_listening() {
  _hexport=$(printf '%04X' "$1" 2>/dev/null)
  [ -n "$_hexport" ] || return 1
  { cat /proc/net/tcp /proc/net/tcp6 2>/dev/null; } | awk -v p="$_hexport" '
    $4 == "0A" { split($2, a, ":"); if (a[2] == p) { found = 1; exit } }
    END { exit(found ? 0 : 1) }
  '
}

# starts_omniroute <pid> : 该 pid 的 cmdline 是否是本容器的 omniroute
is_omniroute_pid() {
  [ -r "/proc/$1/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q "run-standalone.mjs" && return 0
  return 1
}

find_omniroute_pid() {
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    if is_omniroute_pid "$pid"; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

start_app() {
  log "启动 OmniRoute 容器进程 (port=$OMNIROUTE_PORT, bind=$OMNIROUTE_HOSTNAME, heap=${OMNIROUTE_MEMORY_MB}MB)"
  nohup "$RURIMA" ruri -p -N -S -A "$ROOTFS" /bin/sh "$BOOT" >> "$APP_LOG" 2>&1 &
  _bg_pid=$!
  sleep 1
  # ruri 自身是父进程，真正的 node 是它的子进程；记下 ruri pid 便于观察
  echo "$_bg_pid" > "$PID_FILE" 2>/dev/null
  log "已拉起 ruri PID=$_bg_pid"
}

log "========================================="
log "OmniRoute 模块启动 (MODDIR=$MODDIR, ROOTFS=$ROOTFS)"
log "========================================="

# 已经在跑就不重复拉起
_running_pid=$(find_omniroute_pid)
if [ -n "$_running_pid" ]; then
  log "OmniRoute 已在运行 (PID=$_running_pid)，跳过启动"
elif port_listening "$OMNIROUTE_PORT"; then
  log "端口 $OMNIROUTE_PORT 已在监听（非本模块进程），跳过启动"
else
  start_app

  # 等就绪：Next standalone 在手机上首启 10~40 秒
  _ok=0
  for _i in $(seq 1 30); do
    sleep 2
    if port_listening "$OMNIROUTE_PORT"; then _ok=1; break; fi
  done
  if [ "$_ok" = "1" ]; then
    log "启动成功：http://127.0.0.1:$OMNIROUTE_PORT"
  else
    log "!! 60 秒内端口 $OMNIROUTE_PORT 未监听，详见 $APP_LOG"
  fi
fi

# ---- 守护代次标记：每次 service.sh 跑一次写新值，老守护读到值变了就自退 ----
_token="$(date '+%s')-$$"
echo "$_token" > "$GEN_FILE" 2>/dev/null

WATCHDOG=$MODDIR/scripts/watchdog.sh
if [ -x "$WATCHDOG" ]; then
  log "拉起源码守护（代次 $_token）"
  nohup "$WATCHDOG" "$_token" >> "$LOG" 2>&1 &
else
  log "!! 缺少 $WATCHDOG，跳过守护"
fi

exit 0
