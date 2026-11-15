#!/system/bin/sh
##########################################################################
# OmniRoute 3.8.54 — 快捷操作（停止 / 启动 切换 + 状态摘要）
#
# 调用约定（Magisk v26+ / KernelSU / APatch 一致）：无参数、单次执行、
# 只回显 stdout，不能传参也不能交互。所以点一下按当前状态决定做什么。
#
# 跨重启的手动停止开关：$STOP_FLAG 存在 = 用户停过，service.sh 与守护都不拉起。
##########################################################################

MODDIR=${0%/*}
BASE=/data/local/omniroute
ROOTFS=$BASE/rootfs
PERSIST=/data/adb/omniroute
CONF=$PERSIST/omniroute.conf
LOG=$PERSIST/service.log
APP_LOG=$PERSIST/app.log
STOP_FLAG=$PERSIST/stopped
GEN_FILE=$PERSIST/watchdog.gen
BOOT=/opt/omniroute/boot.sh
RURIMA=$MODDIR/system/bin/rurima

if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() { echo "$1"; }
fi

OMNIROUTE_PORT=20128
OMNIROUTE_HOSTNAME=127.0.0.1
OMNIROUTE_MEMORY_MB=1024
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
case "$OMNIROUTE_PORT" in ''|*[!0-9]*) OMNIROUTE_PORT=20128 ;; esac

port_listening() {
  _hexport=$(printf '%04X' "$1" 2>/dev/null)
  [ -n "$_hexport" ] || return 1
  { cat /proc/net/tcp /proc/net/tcp6 2>/dev/null; } | awk -v p="$_hexport" '
    $4 == "0A" { split($2, a, ":"); if (a[2] == p) { found = 1; exit } }
    END { exit(found ? 0 : 1) }
  '
}

find_omniroute_pid() {
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "/proc/$pid/cmdline" ] || continue
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "run-standalone.mjs"; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

app_version() {
  sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOTFS/opt/omniroute/app/package.json" 2>/dev/null | head -n1
}

show_status() {
  ui_print "OmniRoute 模块状态"
  ui_print "  版本: $(app_version || echo 未知)"
  ui_print "  地址: http://127.0.0.1:$OMNIROUTE_PORT  (绑定 $OMNIROUTE_HOSTNAME)"
  _pid=$(find_omniroute_pid)
  if [ -n "$_pid" ]; then
    ui_print "  进程: 运行中 PID=$_pid"
  else
    ui_print "  进程: 未运行"
  fi
  if port_listening "$OMNIROUTE_PORT"; then
    ui_print "  端口: $OMNIROUTE_PORT 已监听"
  else
    ui_print "  端口: $OMNIROUTE_PORT 未监听"
  fi
  if [ -f "$STOP_FLAG" ]; then
    ui_print "  开关: 已手动停止（点「运行」恢复）"
  else
    ui_print "  开关: 自动启动"
  fi
}

stop_app() {
  ui_print "- 停止 OmniRoute..."
  printf '%s\n' "stopped by action.sh at $(date '+%Y-%m-%d %H:%M:%S')" > "$STOP_FLAG"
  # 让守护自退：删代次标记，守护读到空值即退
  rm -f "$GEN_FILE" 2>/dev/null

  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "/proc/$pid/cmdline" ] || continue
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "run-standalone.mjs"; then
      kill "$pid" 2>/dev/null
    fi
  done
  sleep 2
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "/proc/$pid/cmdline" ] || continue
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "run-standalone.mjs"; then
      kill -9 "$pid" 2>/dev/null
    fi
  done
  ui_print "- 已停止（重启后保持停止；再点一次「运行」恢复）"
}

start_app() {
  ui_print "- 启动 OmniRoute..."
  rm -f "$STOP_FLAG" 2>/dev/null

  if [ ! -f "$ROOTFS/etc/os-release" ]; then
    ui_print "!! rootfs 缺失，请重新刷入模块"
    return 1
  fi
  chmod 0755 "$RURIMA" 2>/dev/null

  mkdir -p "$ROOTFS/opt/omniroute"
  {
    echo "OMNIROUTE_PORT=$OMNIROUTE_PORT"
    echo "OMNIROUTE_HOSTNAME=$OMNIROUTE_HOSTNAME"
    echo "OMNIROUTE_MEMORY_MB=$OMNIROUTE_MEMORY_MB"
  } > "$ROOTFS/opt/omniroute/runtime.env"

  nohup "$RURIMA" ruri -p -N -S -A "$ROOTFS" /bin/sh "$BOOT" >> "$APP_LOG" 2>&1 &

  _ok=0
  for _i in $(seq 1 25); do
    sleep 2
    if port_listening "$OMNIROUTE_PORT"; then _ok=1; break; fi
  done
  if [ "$_ok" = "1" ]; then
    ui_print "- 启动成功：http://127.0.0.1:$OMNIROUTE_PORT"
  else
    ui_print "!! 50 秒内端口未监听"
    ui_print "  最近日志（$APP_LOG 末尾 15 行）："
    tail -n 15 "$APP_LOG" 2>/dev/null
  fi

  # 重新拉起守护（新代次）
  _token="$(date '+%s')-$$"
  echo "$_token" > "$GEN_FILE"
  [ -x "$MODDIR/scripts/watchdog.sh" ] && nohup "$MODDIR/scripts/watchdog.sh" "$_token" >> "$LOG" 2>&1 &
  return 0
}

if [ -f "$STOP_FLAG" ]; then
  show_status
  ui_print ""
  start_app
else
  show_status
  ui_print ""
  stop_app
fi

ui_print ""
ui_print "日志: $LOG / $APP_LOG"
