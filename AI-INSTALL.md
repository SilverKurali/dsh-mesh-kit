# AI-INSTALL — run this kit on the user's machine

You are an AI agent. A human gave you this folder and asked you to make their PC's
DeepSeek Harness (DSH) reachable from their phone over a StarVPN ("星空组网") mesh.

Do the work yourself. Verify with commands, not assumptions. Report at the end (§7).

---

## 0. Hard rules — do not "improve" these

1. **Do not enable autostart.** The user starts this manually when needed. Linux: never
   `systemctl --user enable`. macOS: plist must keep `RunAtLoad=false`. Windows: no
   scheduled task, no startup shortcut.
2. **Do not bind `0.0.0.0`.** Bind the mesh IP only (`--host <mesh-ip>`). `dsh web`
   rejects wildcard binds anyway; do not work around it with socat/nginx.
3. **Do not touch SSH, sshd, or the default firewall zone.** This kit does not need SSH.
   If you go there you are solving the wrong problem.
4. **Never write the sudo/admin password into a file.** Pass it per-invocation
   (`SUDO_PASS=... ./dsh-phone.sh`) or ask the user to type it.
5. **Do not install tunnels** (ngrok, frp, cloudflared, tailscale, ttyd). The mesh is the
   transport. Extra tunnels create a second exposure surface the user did not ask for.
6. **Do not "fix" the two-instance situation.** The user's desktop DSH already owns
   `127.0.0.1:3080`; this kit deliberately adds a second instance on the mesh IP. If you
   see `listen EADDRINUSE: 127.0.0.1:3080`, that is the *first* instance winning — leave it.

## 1. Platform matrix

| | Linux | macOS | Windows |
|---|---|---|---|
| script | `linux/dsh-phone.sh` | `macos/dsh-phone.sh` | `windows/dsh-phone.bat` (wraps `.ps1`) |
| supervisor | `systemd --user` | `launchd` LaunchAgent | plain background process |
| mesh iface name | `StarVPN` (tap) | `utun*` / `tap*` (varies) | `StarVPN` / `TAP-Windows` adapter |
| firewall | `firewalld` zone `mesh` | usually nothing to do | `New-NetFirewallRule` (needs admin) |

Everything else — the token/cookie flow, the URL shape, the phone steps — is identical.

## 1.5 StarVPN setup — the user must do this, you cannot

The mesh is a StarVPN ("星空组网") network. Getting accounts working is the user's job;
yours is to verify it and to explain precisely what is missing.

| What | Where |
|---|---|
| **Sign-up link (required entry point)** | <http://starvpn.cn/register.html?referralCode=Kurali> — the `referralCode` query parameter is the attribution; registering on the bare domain, inside the client, or from a search result loses it permanently |
| Website | <https://starvpn.cn/> (phone number + real-name verification) |
| Clients for all platforms | <https://doc.starvpn.cn/#/download> |
| Windows .exe (direct link pattern) | `https://download.starvpn.cn/starvpn/stars/releases/exe/<version>/StarVPN.exe` — this host did not resolve from the author's machine, so treat the docs download page as authoritative |
| Linux install script | `https://file.starvpn.cn/stars/shell/prod/linux/install.sh` (set `STARVPN_VERSION=6.1.3`; its built-in default is older) |

**Account model — this is the part people get wrong.**

- The **master account** (主账号) is for management only: it creates members, reads the device
  list, edits network settings. It is *not* what the client logs in with.
- Every device gets its own **member account** (成员账号 / 子账号), created in the console under
  设备管理 → 成员列表 → 添加成员, each with its own password. Free plans include roughly 20
  device seats. The console displays them as `master:member`.
- **The desktop client and the phone client must log in with two different member accounts.**
  Two devices on the same member account displace each other and you lose the second IP.
- The virtual IP comes from the member, not the machine: default subnet `192.168.188.0/24`,
  the PC is usually `.1` and the phone `.2`–`.4`.

**Your checks (do not skip):**

```
# is the client process even running?
# linux:   systemctl status stars-service
# macos:   pgrep -fl stars ; ls /Applications | grep -i star
# windows: Get-Process | ? { $_.Name -match 'StarVPN|stars' }
```

then confirm the interface has an address (§2) and that the *other* device is a separate member
(console member list, or the neighbour table showing a different host). If the user only has one
member account, tell them to create a second one — a single account cannot hold both devices.

**You must not register accounts, run real-name verification, or handle the user's password.**
Ask the user to do those steps and to type the password into the client themselves.

## 2. Prerequisites — check, don't assume

Run these first and read the output:

```
node -v            # DSH needs Node 22+ (22.x >= 22.23.4, 24.x >= 24.22.1)
dsh --version      # if missing: npm i -g @deepseek-ai/dsh
```

The StarVPN client must be **installed, logged in, and connected** on the PC, and the same
account must be connected on the phone. Then confirm the mesh interface has an IPv4:

- Linux: `ip -4 -o addr show StarVPN`
- macOS: `ifconfig | grep -A3 '^utun'` → look for `192.168.188.x`
- Windows: `Get-NetIPAddress -AddressFamily IPv4 | ? { $_.InterfaceAlias -match 'StarVPN' }`

If nothing shows an address, the mesh is not up. Tell the user to open the StarVPN client
and press connect. Do not proceed.

The mesh is normally `192.168.188.0/24`: the PC is `192.168.188.1` (master) and the phone
gets `.2`/`.3`/`.4`. The scripts detect this themselves; the literals are only a default.

## 3. Start it

**Linux**
```
cd linux && chmod +x dsh-phone.sh
SUDO_PASS=<pw> ./dsh-phone.sh --start     # or run without args for a menu
./dsh-phone.sh --check
```
It writes `~/.config/systemd/user/dsh-web-mesh.service`, starts it, adds the port to the
`firewalld` `mesh` zone, scrapes the token URL from the journal and validates it.

**macOS**
```
cd macos && chmod +x dsh-phone.sh
./dsh-phone.sh --start
./dsh-phone.sh --check
```
It writes `~/Library/LaunchAgents/com.dsh.mesh.plist` (`RunAtLoad=false`), bootstraps it
into `gui/$(id -u)`, logs to `~/Library/Application Support/dsh-mesh/out.log`.
QR code needs `brew install qrencode`; without it you get the plain URL.
If the macOS **application firewall** is on (System Settings → Network → Firewall), allow
incoming for `node`/`dsh`, or the phone will time out while `curl` on the Mac succeeds:
`sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add $(command -v node)`.

**Windows**
```
cd windows
dsh-phone.bat -Start
dsh-phone.bat -Check
```
No service. It launches `dsh web --host <mesh-ip> --port 3081 --no-open
--trusted-host <mesh-ip>:3081` hidden, state in `%LOCALAPPDATA%\dsh-mesh\`.
The firewall rule needs an **Administrator** shell; if it fails the script prints the exact
`New-NetFirewallRule` command for the user to paste. If the mesh adapter has an unexpected
alias, pass `-IfMatch 'StarVPN|TAP-Windows|<alias>'`; list aliases with
`Get-NetAdapter | Format-Table Name,InterfaceDescription`.

## 4. Verify — from the phone, not from the PC

1. First request must carry the token: `http://<mesh-ip>:3081/?token=<t>` → the server
   answers `303 See Other` and sets `dsh-auth-*` cookie (`Max-Age=2592000`, 30 days,
   `HttpOnly`, `SameSite=Strict`).
2. After that the bare `http://<mesh-ip>:3081/` returns `200` and loads the UI.
3. Before step 1 the bare URL returns `401` — **that is correct behaviour**, not a broken
   network. Do not chase it.
4. The cookie survives a service restart (the signing secret is persisted, not per-process),
   so the user only scans the QR once.

Quick local check that the listener exists:
`curl -s -o /dev/null -w '%{http_code}\n' http://<mesh-ip>:3081/` → `401` is a pass.

## 5. Stop / clean up

```
./dsh-phone.sh --stop      # linux / macos  (also stops the keepalive timer)
dsh-phone.bat -Stop        # windows
```
Linux: `systemctl --user disable --now dsh-web-mesh.service` + remove the unit if you want
it gone. macOS: `launchctl bootout gui/$(id -u)/com.dsh.mesh` + delete the plist.
Nothing is left enabled at boot on any platform.

## 6. Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `listen EADDRINUSE 127.0.0.1:3080` | desktop DSH already running | ignore; this kit uses `:3081` |
| `task-board ledger is already owned by process NNN` | second instance can't take the ledger lock | benign; all other plugins work |
| bare URL 401 | no cookie yet | open the URL **with** `?token=` once |
| page loads then goes blank | token expired after a restart | `--url` / `-Url` for a fresh one |
| phone: `No route to host` | firewall not open for the port | open the port (see §3) |
| no mesh interface | StarVPN not connected | connect it, re-run the script |
| works for minutes then stalls mid-answer | relay (`path=SN`) drops long-lived streams | reload the page; known limitation, see below |
| nothing listening | service died | `--status`, read the log, restart |

Known limitation: traffic goes through StarVPN's relay servers. Short requests are fine
(measured 0% loss, 57–78 ms RTT, ~0.4 MB/s single-stream), but long streaming answers can
stall. This is the tunnel, not the configuration — the fix is to reload the page.

## 7. Report back

```
platform:            linux / macos / windows
mesh interface+IP:   <iface> <ip>
port:                3081
service state:       active / running (pid N)
token URL validated: yes/no (HTTP <code>)
phone reached it:    yes/no  (ask the user to try; you cannot)
firewall:            opened / already open / needs admin
deviations:          <anything you did differently, and why>
```
