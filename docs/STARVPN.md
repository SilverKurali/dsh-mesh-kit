# StarVPN (星空组网) — what you actually need to know

## Entry points

| What | URL |
|---|---|
| **Sign up (use this link)** | <http://starvpn.cn/register.html?referralCode=Kurali> |
| Website | <https://starvpn.cn/> |
| Clients (all platforms) | <https://doc.starvpn.cn/#/download> |
| Linux install script | `https://file.starvpn.cn/stars/shell/prod/linux/install.sh` |

The Linux script pins its own default version internally (`DEFAULT_VERSION="6.1.0"` at the time of
writing) and only installs something newer when you ask:

```bash
wget -O /tmp/starvpn-install.sh https://file.starvpn.cn/stars/shell/prod/linux/install.sh
sudo env STARVPN_VERSION=6.1.3 sh /tmp/starvpn-install.sh
```

After upgrading, check that the service — not the installer's user-session child — owns the client:

```
systemctl status stars-service        # should be active
ps -o pid,ppid,cmd -C stars-service_linux_amd64
```

The installer has been observed leaving `stars run` attached to `systemd --user` while
`stars-service.service` stayed inactive. `stars stop && systemctl start stars-service` fixes it.

## Sign-up: please enter through the referral link

Register **through this link**, not by typing the domain by hand:

```
http://starvpn.cn/register.html?referralCode=Kurali
```

The `referralCode` parameter is what attributes the account to the inviter. Registering on
`starvpn.cn` directly, in the desktop client, or through a search result does **not** carry the
code — the account is created unattributed and the invitation cannot be credited afterwards.
So: open the link, register, then install the client and log in with the member account.

## Account model — the part everyone gets wrong

- **Master account (主账号)**: phone-number sign-up plus real-name verification. It exists to
  *manage*: create members, read the device list, edit network settings. **The desktop client does
  not log in with it.**
- **Member account (成员账号 / 子账号)**: created in the console under 设备管理 → 成员列表 →
  添加成员, each with its own password. Free plans include roughly twenty device seats.
  The console renders them as `master:member`.
- **One member account per device.** Two devices sharing a member account displace each other and
  you lose the second IP.
- The virtual IP belongs to the member, not the machine. Default subnet `192.168.188.0/24`: the
  first device is usually `.1`, the phone gets `.2`–`.4`.

Docker images of the client take exactly these credentials as `STARS_USER` / `STARS_PASS`, which is
a good sanity check on the model.

## What the client does on Linux

- creates a TAP interface named `StarVPN` (MAC `02:ff:3d:xx:xx:xx`, identity-derived),
- runs as root via `stars-service.service`, management UI on `127.0.0.1:7725` / `:7726`,
- keeps one TCP session to a supernode (e.g. `81.70.95.200:7654`) and relays member traffic
  through it when no direct path is found.

Logs live in `/usr/local/lib/stars/res/stars.log` (host) and, on Android,
`/sdcard/Android/data/wang.switchy.hin2n.stars/files/log/stars_go.log`.

Useful lines:

```
[SN-RTT] Supernode 业务包往返偏慢: peerIP=192.168.188.1 rtt=1.054s path=SN
Go mobile advanced config: transport=P2P stun=true tcpP2P=false portMapping=true
```

## There is no per-app split tunnel

Decompiling the 6.1.3 Android client (17 dex files) finds **no** `addAllowedApplication`,
`addDisallowedApplication` or `setAllowedApplications`. The web console's client settings only cover
STUN, Happy Eyeballs, TCP fallback, UPnP, transport mode, relay acceleration and multicast.

So when one app on the phone cannot reach the mesh while others can, the cause is app-level
(its own network stack, a WebView, a proot environment, a per-UID route), not a StarVPN setting.
Diagnose it on the phone: compare `/proc/net/tcp` for the destination, and watch the tunnel counter
in `/proc/net/dev` for interface `tun0` while the app retries.
