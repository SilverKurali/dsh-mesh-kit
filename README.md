# dsh-mesh-kit

Open your desktop **DeepSeek Harness** (DSH) web UI on your phone over a
[StarVPN / 星空组网](https://starvpn.cn/) mesh — no SSH, no port forwarding, no router config,
no rooted phone.

Supports **Linux · macOS · Windows**.

`[English](#what-it-solves) | [中文](#中文)`

## Which one do I want: plugin or these scripts?

There is now an official-looking shortcut. If DSH is already installed on the machine you want
to reach and you're allowed to add a plugin to its profile, use the plugin — it is **one process**:

```bash
dsh plugin --profile web add dsh-mesh-access --registry=https://registry.npmjs.org
```

→ <https://github.com/SilverKurali/dsh-mesh-access> · <https://www.npmjs.com/package/dsh-mesh-access>

The plugin binds a second listener **inside the running server** and reverse-proxies to it, so
the phone and the desktop share one instance, one session list, and you never see
`task-board ledger is already owned by …`.

Use the scripts in this repo instead when:

- you don't want to touch the profile, or DSH is older than `0.2.1-rc.2`;
- you want a **separate** instance with its own profile and port, leaving your main one alone;
- you want the extra bits: QR code, firewall rule, keepalive timer, `--check` self-test;
- the machine has no npm/Node toolchain handy but you can still run a shell script.

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

1. **Mesh first**: [sign up here](https://starvpn.cn/register.html?referralCode=Kurali) — the
   `referralCode` in that link is what attributes the account, so enter through it rather than
   typing the domain — then install the StarVPN client on the PC *and* the phone and log each in
   with its **own member account** (member ≠ master account — see
   [docs/STARVPN.md](docs/STARVPN.md)), and connect both.
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

### 插件还是这套脚本？

现在有条更省事的路。**要访问的那台机器上已经装了 DSH，并且允许往它的 profile 里加插件**，就用插件 —— 它只有**一个进程**：

```bash
dsh plugin --profile web add dsh-mesh-access --registry=https://registry.npmjs.org
```

→ <https://github.com/SilverKurali/dsh-mesh-access> · <https://www.npmjs.com/package/dsh-mesh-access>

用法就是：**手机上打开这个地址，远程控制电脑上的 DSH**。插件在**正在跑的服务进程内部**再开一个监听口做反向代理，所以手机和电脑是同一个实例、同一份会话列表，也不会出现 `task-board ledger is already owned by …` 那种抢锁报错。

以下情况用本仓库的脚本：

- 不想动 profile，或者 DSH 低于 `0.2.1-rc.2`；
- 想要一个**独立**实例（自己的 profile、自己的端口），完全不干扰主实例；
- 需要脚本附带的东西：二维码、防火墙规则、保活定时器、`--check` 自检；
- 那台机器不方便装 npm 工具链，但能跑 shell 脚本。

**一句话**：`dsh web` 只能绑一个具体网卡地址（不接受通配），所以桌面上的 `127.0.0.1:3080`
手机看不见；开机后才出现的组网网卡（`StarVPN` / `utun*` / TAP）也不在它的监听范围内。
这套脚本负责找网卡、绑组网 IP、放行端口、把 token 地址和二维码给你。

**三步**：

1. **先从这个邀请链接注册**：<https://starvpn.cn/register.html?referralCode=Kurali>
   （链接里的 `referralCode` 才是归属凭据，直接输域名注册不算邀请）。
   然后电脑和手机各装星空组网客户端，**各用一个成员账号**登录并连接（成员账号 ≠ 主账号，
   见 [docs/STARVPN.md](docs/STARVPN.md)）。
2. 电脑装 DSH：`npm i -g @deepseek-ai/dsh`（Node 22+）。
3. 跑你系统的脚本（Linux/macOS：`./dsh-phone.sh`；Windows：双击 `dsh-phone.bat`）。

手机**第一次**用带 `?token=` 的地址打开 → 303 + cookie（30 天）→ 以后裸地址直接 200。

**两种架构**：A 再起一个实例（脚本默认，简单，但抢不到 task-board 的锁）；
B 用 `tools/mesh-proxy.mjs --keep-host` 把组网端口反代到已有实例（单实例，状态一致）。

**已知限制**：走的是星空的中继（`path=SN`）。短请求没问题（实测 0% 丢包、57–78ms、
单向 0.4MB/s），但**长流式回答会中途卡住**，刷新页面即可接回。这是隧道特性。

完整排障、验证命令和「绝对不要做」的清单，在 `AI-INSTALL.md`（英文）。
