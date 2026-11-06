# dsh-mesh-kit

Open your desktop **DeepSeek Harness** (DSH) web UI on your phone over a
[StarVPN / 星空组网](https://starvpn.cn/) mesh — no SSH, no port forwarding, no router config,
no rooted phone.

Supports **Linux · macOS · Windows**.

`[English](#what-it-solves) | [中文](#中文)`

## What it solves

`dsh web` binds exactly **one concrete interface address** (wildcards are rejected):

```
$ dsh web --help
  --host <host>   bind address: one concrete IPv4 or IPv6 literal of a local
                  interface; wildcard addresses are rejected
```

So a desktop that serves `127.0.0.1:3080` is invisible to the mesh, and a mesh IP that is
created *after* boot (`StarVPN`, `utun*`, a TAP adapter) is not where the server is listening.
These scripts find the mesh interface, launch DSH bound to it, open the firewall port, and
hand you a token URL plus a QR code.

## Quickstart

1. **Mesh first**: install the StarVPN client on the PC *and* the phone, log each in with its
   **own member account** (member ≠ master account — see [docs/STARVPN.md](docs/STARVPN.md)),
   connect both.
2. **DSH**: `npm i -g @deepseek-ai/dsh` (Node 22+).
3. **Run the script for your OS** (or hand the folder to an AI and point it at `AI-INSTALL.md`).

| OS | Command |
|---|---|
| Linux | `cd linux && chmod +x dsh-phone.sh && ./dsh-phone.sh` |
| macOS | `cd macos && chmod +x dsh-phone.sh && ./dsh-phone.sh` |
| Windows | double-click `windows\dsh-phone.bat`, or `dsh-phone.bat -Start` |

No arguments = interactive menu (start / restart with a fresh token / show URL / self-check /
stop / quit). Everything also works as flags: `--start --restart --status --check --url --stop`
(PowerShell: `-Start -Restart -Status -Check -Url -Stop`).

On the phone: open the **token URL once** (`http://<mesh-ip>:3081/?token=...`); the server answers
`303` and sets `dsh-auth-*` (`Max-Age=2592000`, `HttpOnly`, `SameSite=Strict`). After that the bare
`http://<mesh-ip>:3081/` returns `200`. The cookie survives a restart — the signing secret is
persisted, not per-process.

## Two topologies

| | A. second instance (scripts) | B. proxy, single instance (`tools/mesh-proxy.mjs`) |
|---|---|---|
| processes | desktop `:3080` + a second `dsh web` on the mesh IP | one `dsh web`, plus a ~120-line proxy |
| task-board ledger | second instance cannot take the lock (`ledger is already owned …`) | no conflict |
| session state | shared storage, separate processes — never open the same session twice | one process, same state everywhere |
| firewall | one port for the mesh IP | one port for the mesh IP |
| when to use | you want zero extra moving parts | you want the phone and the desktop to be the *same* server |

Topology B, verified end to end:

```bash
# 1) your normal server, but trust the mesh authority and advertise it
dsh web --host 127.0.0.1 --port 3080 \
        --public-url http://192.168.188.1:3081/ \
        --trusted-host 192.168.188.1:3081

# 2) proxy that mesh port to it, keeping the browser's Host header
node tools/mesh-proxy.mjs --listen 192.168.188.1:3081 --target 127.0.0.1:3080 --keep-host
```

`--keep-host` matters: DSH derives the cookie's `authority` from the request `Host`, and that
authority must equal the origin the browser sees, or the browser will send a cookie the server
rejects. Without `--keep-host` the proxy rewrites `Host` to the upstream, which is what you want
when the upstream is a *separate* instance that was never told about the mesh.

## Measured on a real relay path

Same phone, same host, using StarVPN's relay (`path=SN`, no direct path):

| Metric | Value |
|---|---|
| ICMP, 40 packets | 0 % loss, `min/avg/max/mdev = 57.5/66.7/78.1/4.6 ms` |
| single-stream TCP upload | ~0.4 MB/s, no stalls over 20 s |
| client-side `[SN-RTT]` for business packets | 1.05 s / 3.48 s / 5.74 s spikes |
| long streaming answers | **can stall mid-response**; reloading the page resumes |

That last row is the honest limitation: short requests are fine, long-lived streams are not.
It is the relay, not the configuration. See [docs/DESIGN.md](docs/DESIGN.md).

## Security notes

- Never bind `0.0.0.0`. Only the mesh IP, so the service is unreachable from café Wi-Fi.
- The token grants a session; treat the QR code like a password. `--restart` rotates it.
- Nothing enables itself at boot: Linux never `enable`s the unit, macOS keeps `RunAtLoad=false`,
  Windows creates no task or shortcut. Start it when you need it, `--stop` when you don't.
- The scripts never write a sudo/admin password to disk. Pass it per invocation (`SUDO_PASS=…`)
  or type it.

## Layout

```
AI-INSTALL.md            instructions for an AI agent (English): prerequisites, per-OS start,
                         verification from the phone, failure table, hard "do not" list
linux/dsh-phone.sh       systemd --user unit + firewalld zone
macos/dsh-phone.sh       launchd LaunchAgent
windows/dsh-phone.ps1    background process + New-NetFirewallRule (+ .bat wrapper)
tools/mesh-proxy.mjs     optional single-instance proxy (HTTP + WebSocket upgrade)
docs/STARVPN.md          account model, downloads, what the client actually does
docs/DESIGN.md           decisions, topologies, measurements, why the relay stalls
```

## Status

Linux: exercised end to end on Fedora 44 (firewalld, SELinux, systemd --user).
macOS and Windows: written and statically checked (`bash -n`, `shellcheck -S error`, BOM verified),
**not yet run on real hardware** — `AI-INSTALL.md` lists the exact commands to verify them, and
issues with logs are welcome.

MIT licensed.

---

## 中文

**一句话**：`dsh web` 只能绑一个具体网卡地址（不接受通配），所以桌面上的 `127.0.0.1:3080`
手机看不见；开机后才出现的组网网卡（`StarVPN` / `utun*` / TAP）也不在它的监听范围内。
这套脚本负责找网卡、绑组网 IP、放行端口、把 token 地址和二维码给你。

**三步**：

1. 电脑和手机各装星空组网客户端，**各用一个成员账号**登录并连接（成员账号 ≠ 主账号，
   见 [docs/STARVPN.md](docs/STARVPN.md)）。
2. 电脑装 DSH：`npm i -g @deepseek-ai/dsh`（Node 22+）。
3. 跑你系统的脚本（Linux/macOS：`./dsh-phone.sh`；Windows：双击 `dsh-phone.bat`）。

手机**第一次**用带 `?token=` 的地址打开 → 303 + cookie（30 天）→ 以后裸地址直接 200。

**两种架构**：A 再起一个实例（脚本默认，简单，但抢不到 task-board 的锁）；
B 用 `tools/mesh-proxy.mjs --keep-host` 把组网端口反代到已有实例（单实例，状态一致）。

**已知限制**：走的是星空的中继（`path=SN`）。短请求没问题（实测 0% 丢包、57–78ms、
单向 0.4MB/s），但**长流式回答会中途卡住**，刷新页面即可接回。这是隧道特性。

完整排障、验证命令和「绝对不要做」的清单，在 `AI-INSTALL.md`（英文）。
