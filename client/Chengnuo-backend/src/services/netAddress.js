import os from 'node:os';

// 本机地址探测：启动器（决定默认服务器）与控制台（展示候选服务器）共用同一套判断。

// 枚举本机所有可用的 IPv4（排除回环与 169.254.x 自动地址）
export function listLocalIPv4() {
  const out = [];
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const i of ifaces[name] || []) {
      if (i.family !== 'IPv4' || i.internal) continue;
      if (i.address.startsWith('169.254.')) continue;
      out.push({ name, ip: i.address });
    }
  }
  return out;
}

// 本机局域网地址（用于展示）：优先 10.x / 192.168.x / 172.x
export function detectLanIP() {
  const list = listLocalIPv4();
  const score = (ip) => {
    const first = Number(ip.split('.')[0]);
    return first === 10 ? 3 : (first === 192 ? 2 : (first === 172 ? 1 : 0));
  };
  list.sort((a, b) => score(b.ip) - score(a.ip));
  return list[0]?.ip ?? '127.0.0.1';
}

// 「虚拟局域网」类地址：这类地址可以让不同网络（跨外网）的设备互相直连，
// 因此优先作为「服务器」的对外地址，使其他设备上的客户端也能连上本机服务器
const VPN_HINTS = [
  { nameRe: /radmin/i, ipRe: /^26\./, label: 'Radmin VPN' },
  { nameRe: /tailscale/i, ipRe: /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./, label: 'Tailscale' },
  { nameRe: /zerotier/i, ipRe: null, label: 'ZeroTier' },
  { nameRe: /hamachi/i, ipRe: /^25\./, label: 'Hamachi' },
  { nameRe: /蒲公英|oray|pgy/i, ipRe: null, label: '蒲公英' }
];

// 本机对外可达地址（其他设备据此连到本机的服务器）：优先虚拟局域网地址，否则退回局域网地址
export function detectOutwardAddr() {
  const list = listLocalIPv4();
  for (const hint of VPN_HINTS) {
    const hit = list.find(c => hint.nameRe.test(c.name) && (!hint.ipRe || hint.ipRe.test(c.ip)));
    if (hit) return { ip: hit.ip, kind: hint.label, iface: hit.name };
  }
  return { ip: detectLanIP(), kind: '局域网', iface: '' };
}
