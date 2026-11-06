# Design notes

## Constraint 1 — `dsh web` binds one address

```
--host <host>   bind address: one concrete IPv4 or IPv6 literal of a local interface;
                wildcard addresses are rejected
```

Consequences:

- `0.0.0.0` is not an option, by design. Adding it back with socat/iptables is out of scope.
- A server started at boot binds whatever exists at boot. A TAP registered later (`StarVPN`) is
  not in that set. On Linux this produced, for months, a service that logged
  `error: Bind to port 22 on 192.168.188.1 failed: Cannot assign requested address` for *other*
  daemons and silently came up without the mesh address — which is why the guard unit exists for
  sshd and why these scripts re-resolve the interface every run.
- To be reachable on two addresses you need either two processes (topology A) or a proxy in front
  of one (topology B).

## Constraint 2 — the token / cookie fence

Requests to `/` are checked like this:

| Request | Answer |
|---|---|
| `GET /` with no cookie | `401 dsh web authentication required` |
| `GET /?token=<t>` | `303 See Other`, `location: ./`, `set-cookie: dsh-auth-…` |
| `GET /` with that cookie | `200` |
| `/api/*` with a `Host` that is not the server's own or in `--trusted-host` | `403` |

The cookie payload embeds the **authority it was issued for**:

```json
{"version":1,"authority":"192.168.188.1:3081","issuedAt":…,"expiresAt":…}
```

and is signed with HMAC-SHA256 over a secret stored in a persistent credential record — not a
per-process random — which is why the cookie survives a restart while the token does not.

That single fact decides the proxy design: **the authority in the cookie must equal the origin the
browser sees.** So a proxy that fronts a *separate* instance rewrites `Host` to the upstream
(`--target`), while a proxy that fronts the *same* instance must preserve the browser's `Host`
(`--keep-host`) and the instance must be launched with
`--public-url http://<mesh-ip>:<port>/ --trusted-host <mesh-ip>:<port>`.

## Constraint 3 — one ledger per home directory

A second `dsh web` against the same `~/.dsh` starts cleanly but reports:

```
ui-task-board … Error: task-board ledger is already owned by process <pid>
```

Everything else works. Two instances also share `~/.dsh/sessions/`, so the session *list* is common
while the *process state* is not: opening the same session in both is asking for trouble. This is
intentional in topology A — the desktop instance is started by DSH itself and cannot simply be
re-hosted — and is the main argument for topology B.

## Measurements (relay path, `path=SN`)

```
ping -c 40 -i 0.25 192.168.188.3
40 packets transmitted, 40 received, 0% packet loss
rtt min/avg/max/mdev = 57.540/66.685/78.079/4.580 ms

# single stream, dd | nc through the tunnel
~400 KB/s sustained for 20 s, 7.9 MB, no stall

# client log, same window
[SN-RTT] Supernode 业务包往返偏慢: peerIP=192.168.188.3 rtt=1.054s path=SN
[SN-RTT] … rtt=3.481s …
[SN-RTT] … rtt=5.735s …
```

Interpretation: the tunnel is *usable* but its business-packet RTT swings by seconds while ICMP
stays flat. Long-lived HTTP streams (SSE / long polling behind the UI) therefore stall
occasionally; a reload re-establishes them. Nothing in the configuration fixes this — it is the
relay. Enabling direct P2P (`transport=P2P` with a reachable STUN path) or the paid "TCP 穿透"
option is the only lever, and it depends on the two networks being able to see each other.

## Why not a DSH plugin (yet)

`dsh` profiles are stacks of npm plugin bundles (`dsh plugin --profile web add <pkg>`), so a plugin
*could* ship this. What it cannot do is what this kit mostly does:

- choose an interface and (re)bind the server's listener — the address is a launch-time flag of
  `dsh web` itself;
- own a system service (systemd / launchd / a Windows firewall rule);
- keep working when DSH is not running.

What a plugin *can* do, and where it would be strictly better than a script, is topology B done
in-process: a plugin can open its own `http` server on the mesh IP and proxy to the port the
profile already serves, so the phone and the desktop share one instance with no external moving
parts. That is the natural next step, and `tools/mesh-proxy.mjs` is the prototype of exactly that
logic.
