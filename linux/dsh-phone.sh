#!/usr/bin/env bash
# dsh-phone.sh —— 把电脑上的 DeepSeek Harness Web 开到星空组网上，手机浏览器直接打开。
#
# 直接运行就是交互菜单：
#     ./dsh-phone.sh
#
# 也可以当命令行工具用（脚本化/定时任务）：
#     ./dsh-phone.sh --start        启动（已在跑就不重启，只刷新地址）
#     ./dsh-phone.sh --restart      重启，换一个新 token
#     ./dsh-phone.sh --status       看状态
#     ./dsh-phone.sh --check        只读自检
#     ./dsh-phone.sh --stop         停止
#     ./dsh-phone.sh --url          只打印地址 + 二维码
#     ./dsh-phone.sh --keepalive    开保活      --no-keepalive  关保活
#
# 可选：--port=3081  --dir=~/某目录  --peer=192.168.188.3  --iface=StarVPN
#       SUDO_PASS=密码 ./dsh-phone.sh     （首次要起组网/开防火墙时需要）
#
# 设计要点：
#   * 服务跑在 systemd --user（dsh-web-mesh.service），关终端、断 SSH 都不停。
#   * token 每次重启才变；不重启时脚本只从 journal 里把当前地址捞出来并校验有效性。
#   * 默认装 25 秒保活定时器，对手机打小包，降低中继会话被空闲回收导致的断流。

set -u

PORT=3081
MESH_IF_PREF="${MESH_IF_PREF:-StarVPN}"
STATE_DIR="$HOME/.local/state/dsh-mesh"
URL_FILE="$STATE_DIR/url"
UNIT="$HOME/.config/systemd/user/dsh-web-mesh.service"
KEEP_UNIT="$HOME/.config/systemd/user/dsh-mesh-keepalive.service"
KEEP_TIMER="$HOME/.config/systemd/user/dsh-mesh-keepalive.timer"
KEEP_PEER_FILE="$STATE_DIR/peer"
SUDO_PASS="${SUDO_PASS:-}"

MODE="menu"
KEEPALIVE=1
WORKDIR="$HOME"
PEER=""

for a in "$@"; do
  case "$a" in
    --start)   MODE="start" ;;
    --restart) MODE="restart" ;;
    --stop)    MODE="stop" ;;
    --status)  MODE="status" ;;
    --check)   MODE="check" ;;
    --url)     MODE="url" ;;
    --no-keepalive) MODE="keepoff" ;;
    --keepalive)    MODE="keepon" ;;
    --dir=*)   WORKDIR="${a#--dir=}" ;;
    --peer=*)  PEER="${a#--peer=}" ;;
    --port=*)  PORT="${a#--port=}" ;;
    --iface=*) MESH_IF_PREF="${a#--iface=}" ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知参数: $a（--help 看用法）" >&2; exit 2 ;;
  esac
done

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'
C_B=$'\033[1m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
step() { printf '\n%s[%s]%s %s\n' "$C_B" "$1" "$C_0" "$2"; }
hr()   { printf '%s────────────────────────────────────────────────%s\n' "$C_B" "$C_0"; }

sudo_do() {
  if [ -n "$SUDO_PASS" ]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
  else
    sudo -n "$@" 2>/dev/null
  fi
}

# ---------- 组网 ----------
mesh_ip() {
  local ifc ip
  ifc="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -x "$MESH_IF_PREF" || true)"
  if [ -z "$ifc" ]; then
    ifc="$(ip -o -4 addr show 2>/dev/null | awk '{print $2}' | cut -d@ -f1 | grep -E '^(tun|tap)' | head -1)"
  fi
  [ -z "$ifc" ] && return 1
  ip="$(ip -o -4 addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  [ -z "$ip" ] && return 1
  printf '%s %s\n' "$ifc" "$ip"
}

ensure_mesh() {
  local got
  got="$(mesh_ip)"
  if [ -n "$got" ]; then
    MESH_IFC="${got% *}"; MESH_IP="${got#* }"
    ok "组网在线：$MESH_IFC = $MESH_IP"
    return 0
  fi
  warn "组网网卡还没起来，尝试启动 stars-service …"
  sudo_do systemctl start stars-service >/dev/null 2>&1 || \
    warn "启动 stars-service 需要 sudo 密码（可用 SUDO_PASS=密码 运行）"
  for _ in $(seq 1 60); do
    got="$(mesh_ip)"
    if [ -n "$got" ]; then
      MESH_IFC="${got% *}"; MESH_IP="${got#* }"
      ok "组网已起来：$MESH_IFC = $MESH_IP"
      return 0
    fi
    sleep 1
  done
  bad "60 秒内组网没起来。先在星空客户端里点「连接」，再重试。"
  return 1
}

# ---------- 防火墙 ----------
ensure_firewall() {
  command -v firewall-cmd >/dev/null 2>&1 || { warn "没有 firewalld，跳过"; return 0; }
  if ! firewall-cmd --get-active-zones 2>/dev/null | grep -qx 'mesh'; then
    warn "没有名为 mesh 的 firewalld 域，跳过放行"
    return 0
  fi
  if sudo_do firewall-cmd --zone=mesh --query-port="$PORT/tcp" >/dev/null 2>&1; then
    ok "防火墙已放行 $PORT/tcp"
    return 0
  fi
  sudo_do firewall-cmd --zone=mesh --add-port="$PORT/tcp" --permanent >/dev/null
  sudo_do firewall-cmd --reload >/dev/null
  if sudo_do firewall-cmd --zone=mesh --query-port="$PORT/tcp" >/dev/null 2>&1; then
    ok "已放行 $PORT/tcp（永久）"
  else
    bad "放行失败，需要 sudo。手动执行："
    echo "      sudo firewall-cmd --zone=mesh --add-port=$PORT/tcp --permanent && sudo firewall-cmd --reload"
    return 1
  fi
}

# ---------- 单元 ----------
write_unit() {
  mkdir -p "$STATE_DIR" "$(dirname "$UNIT")"
  local dsh_bin tmp
  dsh_bin="$(command -v dsh || true)"
  if [ -z "$dsh_bin" ]; then
    bad "找不到 dsh 命令（先 npm i -g @deepseek-ai/dsh）"
    return 1
  fi
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[Unit]
Description=DeepSeek Harness Web on mesh ($MESH_IP:$PORT)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$WORKDIR
ExecStart=$dsh_bin web --host $MESH_IP --port $PORT --no-open --trusted-host $MESH_IP:$PORT
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
  if ! cmp -s "$tmp" "$UNIT"; then
    mv "$tmp" "$UNIT"
    systemctl --user daemon-reload
    ok "已更新服务定义"
  else
    rm -f "$tmp"
  fi
  # 按需使用：绝不 enable 开机自启
  systemctl --user disable dsh-web-mesh.service >/dev/null 2>&1 || true
}

# ---------- 保活 ----------
detect_peer() {
  if [ -n "$PEER" ]; then printf '%s\n' "$PEER"; return; fi
  if [ -s "$KEEP_PEER_FILE" ]; then cat "$KEEP_PEER_FILE"; return; fi
  local net="${MESH_IP%.*}"
  [ -z "$net" ] && return 0
  ip neigh show dev "${MESH_IFC:-$MESH_IF_PREF}" 2>/dev/null \
    | awk -v net="$net" -v self="$MESH_IP" '$1 ~ ("^" net "\.") && $1 != self {print $1; exit}'
}

write_keepalive() {
  local peer tmp
  peer="$(detect_peer)"
  if [ -z "$peer" ]; then
    warn "暂时没发现对端（手机没连或还没上线），保活先跳过"
    return 0
  fi
  printf '%s\n' "$peer" > "$KEEP_PEER_FILE"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[Unit]
Description=Keep mesh peer $peer warm

[Service]
Type=oneshot
ExecStart=/usr/bin/ping -c 1 -W 1 $peer
EOF
  mv "$tmp" "$KEEP_UNIT"
  cat > "$KEEP_TIMER" <<EOF
[Unit]
Description=Keepalive timer for mesh peer

[Timer]
OnBootSec=20
OnUnitActiveSec=25
AccuracySec=3

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user disable dsh-mesh-keepalive.timer >/dev/null 2>&1 || true
  systemctl --user start dsh-mesh-keepalive.timer >/dev/null 2>&1 || true
  ok "保活已开：每 25 秒 ping $peer"
}

disable_keepalive() {
  systemctl --user disable --now dsh-mesh-keepalive.timer >/dev/null 2>&1 || true
  ok "保活已关"
}

# ---------- 端口清理 ----------
kill_stale() {
  local pid unit_active
  pid="$(ss -Hltnp 2>/dev/null | grep -E ":$PORT\b" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  [ -z "$pid" ] && return 0
  unit_active="$(systemctl --user is-active dsh-web-mesh.service 2>/dev/null || true)"
  [ "$unit_active" = "active" ] && return 0
  if [ "$(stat -c %U "/proc/$pid" 2>/dev/null)" = "$(id -un)" ]; then
    kill "$pid" 2>/dev/null && ok "已清理占用 $PORT 的旧进程 pid=$pid"
    sleep 1
  else
    warn "端口 $PORT 被别的用户进程占用（pid=$pid）"
  fi
}

# ---------- 取地址（校验有效） ----------
fetch_url() {
  local url code tried
  for tried in $(seq 1 45); do
    url="$(journalctl --user -u dsh-web-mesh.service --no-pager -o cat 2>/dev/null \
            | grep -oE "http://$MESH_IP:$PORT/\?token=[A-Za-z0-9_-]+" | tail -1)"
    if [ -n "$url" ]; then
      code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
      case "$code" in
        200|303)
          printf '%s\n' "$url" > "$URL_FILE"
          printf '%s\n' "$url"
          return 0 ;;
      esac
    fi
    sleep 1
  done
  return 1
}

# ---------- 展示 ----------
print_share() {
  local url="$1"
  printf '\n%s手机这样用%s\n' "$C_B" "$C_0"
  printf '  1) 手机连上星空组网（同一个网络）\n'
  printf '  2) 浏览器打开（必须带 token）：\n\n'
  printf '     %s%s%s\n\n' "$C_C" "$url" "$C_0"
  if command -v qrencode >/dev/null 2>&1; then
    printf '  或者直接扫码：\n\n'
    qrencode -t ansiutf8 -m 1 "$url"
    printf '\n'
  fi
  printf '  %s断流时先别关页面：点侧栏 / 重新加载，多半能自己接回来。%s\n' "$C_Y" "$C_0"
}

show_state() {
  local got svc listen peer ka
  got="$(mesh_ip)"
  svc="$(systemctl --user is-active dsh-web-mesh.service 2>/dev/null || true)"
  listen="$(ss -Hltn 2>/dev/null | grep -cE ":$PORT\b" || true)"
  peer="$(detect_peer)"
  ka="$(systemctl --user is-active dsh-mesh-keepalive.timer 2>/dev/null || true)"

  hr
  if [ -n "$got" ]; then printf ' 组网 %s✔%s %s = %s\n' "$C_G" "$C_0" "${got% *}" "${got#* }"
  else                    printf ' 组网 %s✘%s 未连接\n' "$C_R" "$C_0"; fi
  if [ "$svc" = "active" ]; then printf ' 服务 %s✔%s 运行中（:%s）\n' "$C_G" "$C_0" "$PORT"
  else                           printf ' 服务 %s·%s %s\n' "$C_Y" "$C_0" "${svc:-未运行}"; fi
  [ "${listen:-0}" -gt 0 ] || printf ' 监听 %s!%s :%s 没有在听\n' "$C_Y" "$C_0" "$PORT"
  if [ "$ka" = "active" ]; then printf ' 保活 %s✔%s 25s → %s\n' "$C_G" "$C_0" "${peer:-未记录}"; else printf ' 保活 %s·%s 关闭\n' "$C_Y" "$C_0"; fi
  if [ "$svc" = "active" ] && [ -s "$URL_FILE" ]; then
    local u; u="$(cat "$URL_FILE")"
    printf ' 地址 %s\n' "$u"
  elif [ "$svc" = "active" ]; then
    printf ' 地址 （服务刚起，按 3 或 --url 取当前地址）\n'
  else
    printf ' 地址 （服务没运行，旧地址已失效；按 1 启动）\n'
  fi
  hr
}

# ---------- 动作 ----------
do_start() {
  local restart="$1" url
  echo
  echo "${C_B}═══ 把电脑上的 DSH Web 开到手机上 ═══${C_0}"
  step 1/6 "组网";   ensure_mesh || return 1
  step 2/6 "防火墙"; ensure_firewall || true
  step 3/6 "清理旧进程"; kill_stale
  step 4/6 "启动服务"
  write_unit || return 1
  if [ "$restart" = "1" ]; then
    systemctl --user restart dsh-web-mesh.service
    ok "已重启（换新 token）"
  elif systemctl --user is-active --quiet dsh-web-mesh.service; then
    ok "服务已在运行，不重启（token 保持不变）"
  else
    systemctl --user start dsh-web-mesh.service
    ok "已启动"
  fi
  step 5/6 "取地址"
  url="$(fetch_url || true)"
  if [ -z "$url" ]; then
    bad "没取到有效地址，最近日志："
    journalctl --user -u dsh-web-mesh.service --no-pager -n 15 -o cat 2>/dev/null | sed 's/^/      /'
    return 1
  fi
  ok "地址已校验可用"
  step 6/6 "断流保活"
  if [ "$KEEPALIVE" = "1" ]; then write_keepalive; else disable_keepalive; fi
  print_share "$url"
}

do_stop() {
  systemctl --user stop dsh-mesh-keepalive.timer 2>/dev/null
  systemctl --user stop dsh-web-mesh.service 2>/dev/null
  systemctl --user disable dsh-web-mesh.service 2>/dev/null
  systemctl --user disable dsh-mesh-keepalive.timer 2>/dev/null
  ok "服务与保活都已停止（不会开机自启）"
}

do_check() {
  local got host code
  got="$(mesh_ip)"
  step 1/4 "组网"
  if [ -n "$got" ]; then ok "网卡 ${got% *} = ${got#* }"; else bad "组网未连接"; fi
  step 2/4 "服务"
  if systemctl --user is-active --quiet dsh-web-mesh.service; then ok "systemd 单元运行中"; else warn "单元未运行"; fi
  ss -Hltn 2>/dev/null | grep -qE ":$PORT\b" && ok "已在监听 :$PORT" || warn "没有监听 :$PORT"
  step 3/4 "地址可用性"
  if [ -s "$URL_FILE" ]; then
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$(cat "$URL_FILE")" 2>/dev/null || echo 000)"
    case "$code" in
      200|303) ok "带 token 访问 → HTTP $code" ;;
      *) warn "带 token 访问 → HTTP $code（重跑一次刷新地址）" ;;
    esac
  else warn "还没有记录过地址"; fi
  step 4/4 "保活"
  if systemctl --user is-active --quiet dsh-mesh-keepalive.timer; then
    ok "定时器运行中（对端 $(cat "$KEEP_PEER_FILE" 2>/dev/null || echo 未记录)）"
  else warn "保活未启用"; fi
}

# ---------- 菜单 ----------
menu() {
  local choice url
  while :; do
    clear 2>/dev/null || true
    printf '%s把电脑上的 DSH Web 开到手机里%s\n\n' "$C_B" "$C_0"
    show_state
    printf '\n'
    printf '  %s1%s 启动 / 拿地址（已在跑就不重启）\n' "$C_C" "$C_0"
    printf '  %s2%s 重启并换一个新 token\n' "$C_C" "$C_0"
    printf '  %s3%s 只显示地址 + 二维码\n' "$C_C" "$C_0"
    printf '  %s4%s 自检（只看，不动）\n' "$C_C" "$C_0"
    printf '  %s5%s 保活：开 / 关\n' "$C_C" "$C_0"
    printf '  %s6%s 停止服务\n' "$C_C" "$C_0"
    printf '  %s0%s 退出\n' "$C_C" "$C_0"
    printf '\n选择 > '
    IFS= read -r choice || exit 0
    case "$choice" in
      1) do_start 0 ;;
      2) do_start 1 ;;
      3) if [ -s "$URL_FILE" ]; then print_share "$(cat "$URL_FILE")"
         else warn "还没有地址，先按 1 启动一次"; fi ;;
      4) do_check ;;
      5) if systemctl --user is-active --quiet dsh-mesh-keepalive.timer; then disable_keepalive
         else ensure_mesh >/dev/null 2>&1; write_keepalive; fi ;;
      6) do_stop ;;
      0|q|Q) printf '拜\n'; exit 0 ;;
      *) warn "没有这个选项：$choice" ;;
    esac
    printf '\n%s回车继续…%s' "$C_Y" "$C_0"
    IFS= read -r _ || exit 0
  done
}

# ---------- 入口 ----------
if [ "$MODE" = "menu" ] && { [ -t 0 ] || [ -n "${DSH_FORCE_MENU:-}" ]; }; then
  menu
  exit 0
fi

case "$MODE" in
  menu|start)   ensure_mesh >/dev/null 2>&1; do_start 0 ;;
  restart)      ensure_mesh >/dev/null 2>&1; do_start 1 ;;
  stop)         do_stop ;;
  status)       ensure_mesh >/dev/null 2>&1; show_state ;;
  check)        ensure_mesh >/dev/null 2>&1; do_check ;;
  url)          if [ -s "$URL_FILE" ]; then print_share "$(cat "$URL_FILE")"; else do_start 0; fi ;;
  keepon)       ensure_mesh >/dev/null 2>&1; write_keepalive ;;
  keepoff)      disable_keepalive ;;
esac
