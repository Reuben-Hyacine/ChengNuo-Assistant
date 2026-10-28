import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// 客户端独立运行的配置。项目根目录为 client/
const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function loadEnvFile() {
  let text;
  try {
    const envPath = path.join(projectRoot, '.env');
    if (!fs.existsSync(envPath)) {
      return;
    }
    text = fs.readFileSync(envPath, 'utf8');
  } catch {
    return;
  }
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) {
      continue;
    }
    const eq = trimmed.indexOf('=');
    if (eq === -1) {
      continue;
    }
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

loadEnvFile();

export const config = {
  env: process.env.NODE_ENV ?? 'development',
  host: process.env.HOST ?? '0.0.0.0',
  // 客户端自身监听端口
  port: Number(process.env.PORT ?? 4000),
  dataDir: process.env.DATA_DIR ?? path.join(projectRoot, 'data'),
  publicDir: process.env.PUBLIC_DIR ?? path.join(projectRoot, 'public'),
  routingIpFile: process.env.ROUTING_IP_FILE ?? 'routing-ips.txt',
  // 用户资料库、卡片库、对话记录库都由服务器存储，客户端不再有对应文件
  // 调用者身份由服务器按登录 token 判定，客户端不再持有固定用户序号
  // 客户端自身地址（仅用于本机页面访问与健康信息展示）
  myIp: process.env.MY_IP ?? '127.0.0.1',
  myPort: Number(process.env.MY_PORT ?? 4000),
  // 要连接的服务器：通常由 launcher.js 依据客户端持有的「服务器 IP 库」(data/routing-ips.txt) 写好环境变量；
  // 这里的默认值只在直接运行 `node src/server.js`（不经启动器）时生效。
  serverIp: process.env.SERVER_IP ?? '127.0.0.1',
  serverPort: Number(process.env.SERVER_PORT ?? 3000)
};