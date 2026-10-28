import { ok } from '../utils/response.js';
import { config } from '../config.js';
import { currentServer } from '../clientRouter.js';

// 客户端进程启动时间（App 开屏判定：startedAt 变化 = 后端新启动 → 首次冷启动播开屏动画）
const BOOT_AT = Date.now();

// 健康信息：本机地址与「当前实际连接的服务器」（实时取自服务器 IP 库，切换后立即反映）
export async function getHealth(req, res) {
  const server = await currentServer();
  ok(res, {
    status: 'ok',
    name: 'client-test-bench',
    startedAt: BOOT_AT,
    time: new Date().toISOString(),
    myAddr: `${config.myIp}:${config.myPort}`,
    server: `${server.ip}:${server.port}`
  });
}
