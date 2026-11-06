#!/bin/bash
# dsh-phone.sh (macOS) —— 把电脑上的 DeepSeek Harness Web 开到星空组网上，手机浏览器直接打开。
#
# 直接运行就是交互菜单：
#     ./dsh-phone.sh
#
# 命令行：
#     ./dsh-phone.sh --start | --restart | --status | --check | --stop | --url
#
# 可选：--port=3081  --dir=~/某目录  --peer=192.168.188.3  --iface=utun4
#
# 设计要点：
#   * 用 launchd 用户级 LaunchAgent（com.dsh.mesh）托管，关终端不退出。
#   * 默认不 RunAtLoad，也就是**不开机自启**；用完 --stop 就彻底停。
#   * token 每次重启才变；不重启时脚本从日志里捞当前地址并校验有效性。

set -u

PORT=3081
MESH_IF_PREF="${MESH_IF_PREF:-}"          # 留空=自动扫描
STATE_DIR="$HOME/Library/Application Support/dsh-mesh"
URL_FILE="$STATE_DIR/url"
LOG_FILE="$STATE_DIR/out.log"
PLIST="$HOME/Library/LaunchAgents/com.dsh.mesh.plist"
LABEL="com.dsh.mesh"
DOMAIN="gui/$(id -u)"
WORKDIR="$HOME"
PEER=""
MODE="menu"

for a in "$@"; do
  case "$a" in
    --start)   MODE="start" ;;
    --restart) MODE="restart" ;;
    --stop)    MODE="stop" ;;
    --status)  MODE="status" ;;
    --check)   MODE="check" ;;
    --url)     MODE="url" ;;
    --dir=*)   WORKDIR="${a#--dir=}" ;;
    --peer=*)  PEER="${a#--peer=}" ;;
    --port=*)  PORT="${a#--port=}" ;;
    --iface=*) MESH_IF_PREF="${a#--iface=}" ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $a（--help 看用法）" >&2; exit 2 ;;
  esac
done

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_0=$'\033[0m'; C_B=$'\033[1m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
step() { printf '\n%s[%s]%s %s\n' "$C_B" "$1" "$C_0" "$2"; }
hr()   { printf '%s────────────────────────────────────────────────%s\n' "$C_B" "$C_0"; }

STATE_DIR_SETUP() { mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents"; }

# ---------- 组网网卡与 IP ----------
mesh_ip() {
  local ifc ip
  if [ -n "$MESH_IF_PREF" ]; then
    ip="$(ifconfig "$MESH_IF_PREF" 2>/dev/null | awk '/inet /{print $2; exit}')"
    [ -n "$ip" ] && { printf '%s %s\n' "$MESH_IF_PREF" "$ip"; return 0; }
    return 1
  fi
  # 优先 utun/tap，其次任何带 192.168.188.x 的网卡
  for ifc in $(ifconfig -l); do
    case "$ifc" in
      utun*|tap*|gpd*|ppp*)
        ip="$(ifconfig "$ifc" 2>/dev/null | awk '/inet /{print $2; exit}')"
        case "$ip" in
          192.168.188.*) printf '%s %s\n' "$ifc" "$ip"; return 0 ;;
        esac
        ;;
    esac
  done
  for ifc in $(ifconfig -l); do
    ip="$(ifconfig "$ifc" 2>/dev/null | awk '/inet /{print $2; exit}')"
    case "$ip" in
      192.168.188.*) printf '%s %s\n' "$ifc" "$ip"; return 0 ;;
    esac
  done
  return 1
}

ensure_mesh() {
  local got
  got="$(mesh_ip)"
  if [ -n "$got" ]; then
    MESH_IFC="${got% *}"; MESH_IP="${got#* }"
    ok "组网在线：$MESH_IFC = $MESH_IP"
    return 0
  fi
  bad "没找到组网网卡（192.168.188.x）。先在星空客户端里点「连接」，再重试。"
  echo "      如果连上了还是没有，用 --iface=<网卡名> 指定，网卡名看：ifconfig -l | tr ' ' '\\n' | grep -E '^(utun|tap)'"
  return 1
}

detect_peer() {
  if [ -n "$PEER" ]; then printf '%s\n' "$PEER"; return; fi
  local net="${MESH_IP%.*}"
  [ -z "$net" ] && return 0
  arp -an 2>/dev/null | awk -v net="$net" -v self="$MESH_IP" '
    /^[? ]*\(/ {
      gsub(/[()]/,"",$2);
      if ($2 ~ ("^" net "\\.") && $2 != self) { print $2; exit }
    }'
}

# ---------- launchd ----------
write_plist() {
  local dsh_bin tmp
  dsh_bin="$(command -v dsh || true)"
  if [ -z "$dsh_bin" ]; then
    bad "找不到 dsh 命令（先 npm i -g @deepseek-ai/dsh）"
    return 1
  fi
  STATE_DIR_SETUP
  tmp="$(mktemp)"
  cat > "$tmp" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$dsh_bin</string>
    <string>web</string>
    <string>--host</string><string>$MESH_IP</string>
    <string>--port</string><string>$PORT</string>
    <string>--no-open</string>
    <string>--trusted-host</string><string>$MESH_IP:$PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$WORKDIR</string>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string></dict>
</dict>
</plist>
PLISTEOF
  if ! cmp -s "$tmp" "$PLIST"; then
    mv "$tmp" "$PLIST"
    ok "已更新 LaunchAgent 定义"
  else
    rm -f "$tmp"
  fi
}

plist_loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

fetch_url() {
  local i u code
  for i in $(seq 1 45); do
    u="$(grep -oE "http://[0-9.]+:$PORT/\?token=[A-Za-z0-9_-]+" "$LOG_FILE" 2>/dev/null | tail -1)"
    if [ -n "$u" ]; then
      code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$u" 2>/dev/null)"
      case "$code" in
        200|303) printf '%s\n' "$u" > "$URL_FILE"; printf '%s\n' "$u"; return 0 ;;
      esac
    fi
    sleep 1
  done
  return 1
}

# ---------- 动作 ----------
do_start() {
  local restart="${1:-0}"
  step 0/5 "环境"
  [ "$(uname -s)" = "Darwin" ] || { bad "这是给 macOS 的脚本"; return 1; }
  command -v dsh >/dev/null 2>&1 || { bad "dsh 不在 PATH 上"; return 1; }
  ok "macOS $(sw_vers -productVersion) · dsh $(command -v dsh)"
  step 1/5 "组网";   ensure_mesh || return 1
  step 2/5 "服务定义"; write_plist || return 1
  step 3/5 "启动"
  if plist_loaded && [ "$restart" = "0" ]; then
    ok "已经在运行（不重启，token 保持不变）"
  else
    [ "$restart" = "1" ] && launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
    : > "$LOG_FILE"
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" >/dev/null 2>&1
    sleep 2
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && ok "LaunchAgent 已加载" || { bad "加载失败，看 $LOG_FILE"; return 1; }
  fi
  step 4/5 "取地址"
  local u
  if u="$(fetch_url)"; then ok "地址已校验：$u"; else bad "没取到有效地址，最近日志："; tail -5 "$LOG_FILE"; return 1; fi
  step 5/5 "二维码"
  if command -v qrencode >/dev/null 2>&1; then qrencode -t ansiutf8 -m 1 "$u"; else warn "没装 qrencode（brew install qrencode 可出二维码），直接复制上面的地址"; fi
  do_status
}

do_stop() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl unload -w "$PLIST" >/dev/null 2>&1
  ok "已停止（LaunchAgent 已卸载，不会开机自启）"
}

do_status() {
  local got svc listen u
  got="$(mesh_ip)"; svc="$(plist_loaded && echo loaded || echo unloaded)"
  listen="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  hr
  if [ -n "$got" ]; then printf ' 组网 %s✔%s %s = %s\n' "$C_G" "$C_0" "${got% *}" "${got#* }"; else printf ' 组网 %s✘%s 未连接\n' "$C_R" "$C_0"; fi
  if [ "$svc" = "loaded" ]; then printf ' 服务 %s✔%s LaunchAgent 已加载\n' "$C_G" "$C_0"; else printf ' 服务 %s·%s 未加载\n' "$C_Y" "$C_0"; fi
  [ "${listen:-0}" -gt 0 ] || printf ' 监听 %s!%s :%s 没有在听\n' "$C_Y" "$C_0" "$PORT"
  if [ "$svc" = "loaded" ] && [ -s "$URL_FILE" ]; then printf ' 地址 %s\n' "$(cat "$URL_FILE")"
  elif [ "$svc" = "loaded" ]; then printf ' 地址 （刚起，用 --url 取当前地址）\n'
  else printf ' 地址 （服务没运行，旧地址已失效；--start 启动）\n'; fi
  hr
}

do_url() {
  local u
  u="$(fetch_url)" || { bad "没取到有效地址（服务没跑？）"; return 1; }
  echo "$u"
  command -v qrencode >/dev/null 2>&1 && qrencode -t ansiutf8 -m 1 "$u"
}

do_check() {
  local got code u
  got="$(mesh_ip)"
  step 1/4 "组网"
  if [ -n "$got" ]; then ok "网卡 ${got% *} = ${got#* }"; else bad "组网未连接"; fi
  step 2/4 "服务"
  if plist_loaded; then ok "LaunchAgent 已加载"; else warn "未加载"; fi
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && ok "已在监听 :$PORT" || warn "没有监听 :$PORT"
  step 3/4 "地址"
  u="$(grep -oE "http://[0-9.]+:$PORT/\?token=[A-Za-z0-9_-]+" "$LOG_FILE" 2>/dev/null | tail -1)"
  if [ -n "$u" ]; then code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$u")"; ok "带 token 访问 → HTTP $code"; else warn "日志里还没有地址"; fi
  step 4/4 "手机可达性"
  local peer; peer="$(detect_peer)"
  if [ -n "$peer" ]; then ping -c 2 -W 2000 "$peer" >/dev/null 2>&1 && ok "本机→手机 $peer 可达" || warn "ping 不通 $peer（可能手机没连组网）"; else warn "没发现对端"; fi
}

menu() {
  local c
  while :; do
    do_status >/dev/null 2>&1
    printf '\n'
    do_status
    printf ' 1 启动/出地址   2 重启换 token   3 只显示地址   4 自检   5 停止   0 退出\n'
    read -r -p ' 选择: ' c || exit 0
    case "$c" in
      1) do_start 0 ;;
      2) do_start 1 ;;
      3) do_url ;;
      4) do_check ;;
      5) do_stop ;;
      0|"") exit 0 ;;
      *) warn "没有这个选项" ;;
    esac
  done
}

case "$MODE" in
  start)   do_start 0 ;;
  restart) do_start 1 ;;
  stop)    do_stop ;;
  status)  do_status ;;
  check)   do_check ;;
  url)     do_url ;;
  menu)    menu ;;
esac
