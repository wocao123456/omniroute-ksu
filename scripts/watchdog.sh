#!/system/bin/sh
##########################################################################
# OmniRoute 3.8.54 — 存活守护
#
# 由 service.sh 以「代次标记」拉起：
#   - 每轮先看 $GEN_FILE，值变了（说明又跑了一次 service.sh）就自退，
#     避免同一台机器上叠出多条守护互相抢着拉起应用。
#   - 用户手动停止（$STOP_FLAG 存在）立即自退。
#   - 连续失败 5 次（每次间隔 30s）就放弃并写日志，防止崩溃循环把电量烧光。
##########################################################################

TOKEN="${1:-none}"

BASE=/data/local/omniroute
ROOTFS=$BASE/rootfs
PERSIST=/data/adb/omniroute
CONF=$PERSIST/omniroute.conf
LOG=$PERSIST/service.log
STOP_FLAG=$PERSIST/stopped
GEN_FILE=$PERSIST/watchdog.gen
BOOT=/opt/omniroute/boot.sh

MODDIR=$(dirname "$0")
[ -d "$MODDIR/.." ] && MODDIR=$(cd "$MODDIR/.." && pwd)
RURIMA=$MODDIR/system/bin/rurima

INTERVAL=30
MAX_FAILS=5
FAILS=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] $1" >> "$LOG" 2>/dev/null
}

OMNIROUTE_PORT=20128
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

app_alive() {
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "/proc/$pid/cmdline" ] || continue
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "run-standalone.mjs"; then
      return 0
    fi
  done
  return 1
}

log "守护启动，代次 $TOKEN"

while :; do
  sleep $INTERVAL

  [ -f "$STOP_FLAG" ] && { log "检测到停止开关，自退"; exit 0; }

  _cur=$(cat "$GEN_FILE" 2>/dev/null)
  if [ "$_cur" != "$TOKEN" ]; then
    log "代次已更新（$_cur != $TOKEN），自退"
    exit 0
  fi

  [ -f "$ROOTFS/etc/os-release" ] || { log "rootfs 消失，自退"; exit 0; }

  if app_alive && port_listening "$OMNIROUTE_PORT"; then
    FAILS=0
    continue
  fi

  if app_alive; then
    # 进程在但端口没起来：可能还在冷启动，给一轮宽限
    log "进程存在但端口 $OMNIROUTE_PORT 未监听，观察中"
    continue
  fi

  FAILS=$((FAILS + 1))
  log "应用不在运行（连续第 $FAILS 次），尝试重启"

  if [ "$FAILS" -gt "$MAX_FAILS" ]; then
    log "连续 $MAX_FAILS 次重启失败，放弃守护（详见 $PERSIST/app.log）"
    exit 1
  fi

  # 清掉可能残留的 ruri / node
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "/proc/$pid/cmdline" ] || continue
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "run-standalone.mjs"; then
      kill -9 "$pid" 2>/dev/null
    fi
  done
  rm -f /data/adb/omniroute/omniroute.pid 2>/dev/null

  nohup "$RURIMA" ruri -p -N -S -A "$ROOTFS" /bin/sh "$BOOT" >> "$PERSIST/app.log" 2>&1 &
  sleep 15
done
