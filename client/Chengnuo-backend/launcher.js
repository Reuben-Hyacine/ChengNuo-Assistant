// 客户端启动器：自动检测本机地址、确定要连接的服务器，然后启动客户端测试台。
// 用法：
//   node launcher.js                      按「服务器 IP 库」选服务器（默认连 primary 条目）
//   node launcher.js --server=IP:PORT     指定要连接的服务器（会写回 IP 库并设为 primary）
//   node launcher.js --myip=IP --myport=N 指定本机地址（仅用于展示）
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { detectLanIP, detectOutwardAddr } from './src/services/netAddress.js';

const clientRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)));

function parseArgs(argv) {
  const opts = { server: null, myip: null, myport: null, help: false };
  for (const a of argv) {
    const m = a.match(/^--([a-z-]+)=(.*)$/) || a.match(/^--([a-z-]+)$/);
    if (!m) continue;
    const [k, v] = [m[1], m[2] === undefined ? true : m[2]];
    if (k === 'server') opts.server = v;
    else if (k === 'myip') opts.myip = v;
    else if (k === 'myport') opts.myport = String(v);
    else if (k === 'help') opts.help = true;
  }
  return opts;
}

function splitHost(serverStr) {
  const idx = serverStr.lastIndexOf(':');
  if (idx === -1) return { ip: serverStr, port: null };
  return { ip: serverStr.slice(0, idx), port: Number(serverStr.slice(idx + 1)) };
}

// 探测服务器是否可达
async function probeServer(ip, port) {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 1500);
    const resp = await fetch(`http://${ip}:${port}/api/health`, { signal: controller.signal });
    clearTimeout(timer);
    return resp.ok;
  } catch {
    return false;
  }
}

const args = parseArgs(process.argv.slice(2));

if (args.help) {
  console.log(`用法:
  node launcher.js
  node launcher.js --server=IP:PORT    指定服务器（会写回 IP 库并设为 primary）
  node launcher.js --myip=IP --myport=N
服务器地址来源：命令行 --server > data/routing-ips.txt 中 primary 条目 > 该文件第一条 > 默认本机对外可达地址`);
  process.exit(0);
}

// 1) 确定本机地址（用于展示）与「本机对外可达地址」（默认服务器的地址）
const myIp = args.myip ?? detectLanIP();
const myPort = args.myport ?? Number(process.env.MY_PORT ?? 4000);
const outward = detectOutwardAddr();

// 2) 从客户端持有的「服务器 IP 库」确定要连接的服务器
//    优先级：命令行 --server > primary 条目 > 第一条有效记录 > 默认（本机对外可达地址 : 3000）
const { listIps, addIp, setPrimary, routingIpFilePath } = await import('./src/services/ipStore.js');
const savedIps = await listIps();

const DEFAULT_SERVER_PORT = 3000;

let serverIp = null;
let serverPort = DEFAULT_SERVER_PORT;
let source = '';
if (args.server) {
  const h = splitHost(args.server);
  serverIp = h.ip;
  if (h.port != null) {
    serverPort = h.port;
  }
  source = '命令行 --server';
} else {
  const primary = savedIps.find(e => e.primary) ?? null;
  const chosen = primary ?? savedIps[0] ?? null;
  if (chosen) {
    serverIp = chosen.ip;
    serverPort = chosen.port ?? DEFAULT_SERVER_PORT;
    source = primary ? `IP 库 primary（#${chosen.id}）` : `IP 库首条（#${chosen.id}）`;
  } else {
    serverIp = outward.ip;
    serverPort = DEFAULT_SERVER_PORT;
    source = `默认（本机对外地址 · ${outward.kind}）`;
  }
}

// 2.1) 首次使用（IP 库为空）：按约定预置两条 —— 默认「服务器」（本机对外地址）、次选「本地服务器」（127.0.0.1）
if (savedIps.length === 0) {
  try {
    await addIp({ ip: outward.ip, port: DEFAULT_SERVER_PORT, name: 'server', primary: true });
    await addIp({ ip: '127.0.0.1', port: DEFAULT_SERVER_PORT, name: 'local', primary: false });
    console.log(`  [IP库] 已预置：服务器 ${outward.ip}:${DEFAULT_SERVER_PORT}（默认，${outward.kind}） + 本地服务器 127.0.0.1:${DEFAULT_SERVER_PORT}（次选）`);
  } catch (err) {
    console.log(`  [IP库] 预置默认服务器失败：${err.message}`);
  }
} else {
  // 2.2) 选定的服务器不在库里（例如来自命令行）→ 补一条并设为 primary
  try {
    const existing = savedIps.find(e => e.ip === serverIp && (e.port ?? DEFAULT_SERVER_PORT) === serverPort) ?? null;
    if (!existing) {
      await addIp({ ip: serverIp, port: serverPort, name: 'server', primary: true });
      console.log(`  [IP库] 已登记服务器 ${serverIp}:${serverPort} 并设为 primary`);
    } else if (args.server && !existing.primary) {
      await setPrimary(existing.id);
      console.log(`  [IP库] 已把 ${serverIp}:${serverPort} 设为 primary`);
    }
  } catch (err) {
    console.log(`  [IP库] 写入服务器地址失败：${err.message}`);
  }
}

// 2.5) 登录状态文件：确保存在（缺省内容 0 = 未登录）
const { ensureLoginStateFile } = await import('./src/store/loginStateStore.js');
await ensureLoginStateFile();

// 2.6) 连不通时临时回退到本机回环地址（不写回 IP 库，避免把手动配置覆盖掉）
if (!(await probeServer(serverIp, serverPort))) {
  if (serverIp !== '127.0.0.1' && await probeServer('127.0.0.1', serverPort)) {
    console.log(`  [路由] 警告：${serverIp}:${serverPort} 连不通，本次临时改用 127.0.0.1:${serverPort}`);
    console.log(`         未写回 IP 库。若目标服务器已换地址，请改 ${routingIpFilePath}`);
    console.log('         （改法见该文件顶部说明：把目标服务器那条设为 "primary": true）');
    serverIp = '127.0.0.1';
  } else {
    console.log('');
    console.log('  =====================================================');
    console.log('   连不上服务器：客户端仍会启动，但功能不可用');
    console.log('  -----------------------------------------------------');
    console.log(`   当前服务器：${serverIp}:${serverPort}`);
    console.log(`   IP 库文件：${routingIpFilePath}`);
    console.log('   排查步骤：');
    console.log('     1) 打开上面的 IP 库文件，把目标服务器那条设为 "primary": true；');
    console.log('     2) 或改用命令行指定：node launcher.js --server=IP:PORT');
    console.log('     3) 确认服务器已启动、其 3000 端口已放通、两台机器网络互通；');
    console.log('     4) 只在本机测试：把该条的 ip 改成 127.0.0.1。');
    console.log('  =====================================================');
    console.log('');
  }
}

// 3) 写入环境变量并同步到 config 对象。
// 注意：上面读取 IP 库时已经连带给 config.js 求过一次值，config 里的 serverIp 是那时的默认值，
// 所以这里除了写环境变量，还必须直接覆盖 config 的同名字段，否则应用仍会用旧的服务器地址。
const { config } = await import('./src/config.js');
process.env.MY_IP = myIp;
process.env.MY_PORT = String(myPort);
process.env.SERVER_IP = serverIp;
process.env.SERVER_PORT = String(serverPort);
config.myIp = myIp;
config.myPort = myPort;
config.serverIp = serverIp;
config.serverPort = serverPort;

console.log('==========================================');
console.log('  客户端启动器');
console.log('  服务器地址   (来源)  : ' + `${serverIp}:${serverPort}  ← ${source}`);
console.log('  本机地址     (客户端): ' + `${myIp}:${myPort}`);
console.log('  本机对外地址         : ' + `${outward.ip}（${outward.kind}）  ← 其他设备连本机服务器时用这个`);
console.log('  服务器 IP 库         : ' + routingIpFilePath);
console.log('  · 换服务器：控制台「服务器」一行切换，或改上面这个文件，或用 --server=IP:PORT');
console.log('==========================================');

// 4) 启动客户端测试台（不再向服务器登记本机地址：服务器不需要反向连入客户端）
const serverUrl = pathToFileURL(path.join(clientRoot, 'src', 'server.js')).href;
await import(serverUrl);