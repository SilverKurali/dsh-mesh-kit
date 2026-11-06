#!/usr/bin/env node
// mesh-proxy.mjs — 把 127.0.0.1 上的 DSH Web 暴露到组网地址，单实例方案。
//
// 用途：不想为手机再起第二个 dsh 实例（会抢 task-board 的 ledger 锁）时，用这个小代理
// 把已有实例原样搬到组网 IP 上。代理会把 Host 改写成目标地址，所以 dsh 那边认为请求
// 来自本机，不需要 --public-url / --trusted-host。
//
//   node mesh-proxy.mjs --listen 192.168.188.1:3081 --target 127.0.0.1:3080
//
// 单实例模式（推荐）：上游就是你自己那个 dsh web，启动时带上信任栅栏
//   dsh web --public-url http://192.168.188.1:3081/ --trusted-host 192.168.188.1:3081
//   node mesh-proxy.mjs --listen 192.168.188.1:3081 --target 127.0.0.1:3080 --keep-host
// keep-host 保留浏览器原始 Host，dsh 据此签发 cookie；cookie 的 authority 必须与浏览器
// 看到的 origin 一致，否则浏览器把 cookie 带上来也会被拒。
//
// 支持 HTTP/1.1 与 WebSocket 升级（DSH 的实时通道需要）。

import http from 'node:http';
import net from 'node:net';

const has = (name) => process.argv.includes(`--${name}`);

const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return def;
  const v = process.argv[i + 1];
  if (v === undefined || v.startsWith('--')) throw new Error(`--${name} 需要一个值`);
  return v;
};

const listenSpec = arg('listen', '0.0.0.0:3081');
const targetSpec = arg('target', '127.0.0.1:3080');
const [listenHost, listenPort] = [listenSpec.slice(0, listenSpec.lastIndexOf(':')), Number(listenSpec.slice(listenSpec.lastIndexOf(':') + 1))];
const [targetHost, targetPort] = [targetSpec.slice(0, targetSpec.lastIndexOf(':')), Number(targetSpec.slice(targetSpec.lastIndexOf(':') + 1))];

if (!listenHost || !Number.isInteger(listenPort) || !targetHost || !Number.isInteger(targetPort)) {
  console.error('用法: node mesh-proxy.mjs --listen <IP:PORT> --target <HOST:PORT>');
  process.exit(2);
}

const targetAuthority = `${targetHost}:${targetPort}`;

const keepHost = has('keep-host');       // 单实例模式：保留浏览器原始 Host

const rewrite = (headers) => {
  const h = { ...headers };
  if (!keepHost) h.host = targetAuthority;   // 默认把 Host 改成上游，dsh 认为请求来自本机
  h['x-forwarded-host'] = headers.host ?? '';
  h['x-forwarded-proto'] = 'http';
  if (headers['x-real-ip']) h['x-forwarded-for'] = headers['x-real-ip'];
  return h;
};

const server = http.createServer((req, res) => {
  const upstream = http.request(
    { host: targetHost, port: targetPort, method: req.method, path: req.url, headers: rewrite(req.headers) },
    (up) => {
      res.writeHead(up.statusCode ?? 502, up.headers);
      up.pipe(res);
    },
  );
  upstream.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(`mesh-proxy: 上游不可达（${targetAuthority}）：${err.message}\n`);
  });
  req.pipe(upstream);
});

// WebSocket / HTTP upgrade：裸 socket 双向转发
server.on('upgrade', (req, socket, head) => {
  const up = net.connect(targetPort, targetHost, () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (const [k, v] of Object.entries(rewrite(req.headers))) {
      if (v === undefined) continue;
      for (const one of Array.isArray(v) ? v : [v]) lines.push(`${k}: ${one}`);
    }
    up.write(lines.join('\r\n') + '\r\n\r\n');
    if (head?.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });
  const bye = () => { up.destroy(); socket.destroy(); };
  up.on('error', bye);
  socket.on('error', bye);
  up.on('close', bye);
  socket.on('close', bye);
});

server.listen(listenPort, listenHost, () => {
  console.log(`mesh-proxy: http://${listenHost}:${listenPort}/  →  http://${targetAuthority}/`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
