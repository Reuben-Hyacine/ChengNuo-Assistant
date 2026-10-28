import { Router } from 'express';
import { getHealth } from '../controllers/health.controller.js';
import { requireDevAuth } from '../middleware/requireDevAuth.js';
import { devLogin, devLogout, devCheck } from '../controllers/devAuth.controller.js';
import {
  listRoutingIps,
  addRoutingIp,
  removeRoutingIp
} from '../controllers/routingIp.controller.js';
import { getAiStatus, askAi, buildPrompt, parseJsonBody, confirmAi, resetAi, clearAiContext, completeAi } from '../controllers/ai.controller.js';
import { listRouteServices, submitRouteTask, listRouteActivity } from '../controllers/route.controller.js';
import { register, login, sessions, logout, deleteAccountHandler } from '../controllers/auth.controller.js';
import { listReports, dismissReportHandler, takedownReportHandler } from '../controllers/cardReport.controller.js';

const apiRouter = Router();

// 探活：客户端启动器与页面用它判断服务器是否可达，保持开放
apiRouter.get('/health', getHealth);

// 开发者登录：管理台（/console 页面与下方受保护接口）的凭据入口，凭据仅存服务器 dev-auth.json；
// 受保护接口对本机回环（SSH 隧道）仍免登录开放，公网访问必须先登录
const devRouter = Router();
devRouter.post('/login', devLogin);
devRouter.post('/logout', devLogout);
devRouter.get('/check', devCheck);
apiRouter.use('/dev', devRouter);

// 路由 IP 库（地址台账）：属管理类数据，本机回环或开发者登录后可读写
const routingIpsRouter = Router();
routingIpsRouter.get('/', listRoutingIps);
routingIpsRouter.post('/', addRoutingIp);
routingIpsRouter.delete('/:id', removeRoutingIp);
apiRouter.use('/routing-ips', requireDevAuth, routingIpsRouter);

// 服务器管理台专用（AI 直调、提示词、状态）：避免公网被匿名驱动 AI
const aiRouter = Router();
aiRouter.get('/status', getAiStatus);
aiRouter.post('/ask', askAi);
aiRouter.post('/confirm', confirmAi);
aiRouter.post('/reset', resetAi);
aiRouter.post('/clear-context', clearAiContext);
aiRouter.post('/complete', completeAi);
aiRouter.post('/prompt', buildPrompt);
aiRouter.post('/parse', parseJsonBody);
apiRouter.use('/ai', requireDevAuth, aiRouter);

// 经路由编号调用：客户端唯一入口。services 是静态服务名列表（页面未登录时也要展示），保持开放；
// task 由服务端按 token 校验身份；activity 是调用日志摘要，仅管理台可见
const routeRouter = Router();
routeRouter.get('/services', listRouteServices);
routeRouter.post('/task', submitRouteTask);
routeRouter.get('/activity', requireDevAuth, listRouteActivity);
apiRouter.use('/route', routeRouter);

// 注册/登录/退出/注销：各自内部校验身份。会话列表暴露所有人的账号与地址，仅管理台可看
const authRouter = Router();
authRouter.post('/register', register);
authRouter.post('/login', login);
authRouter.post('/logout', logout);
authRouter.post('/delete-account', deleteAccountHandler);
authRouter.get('/sessions', requireDevAuth, sessions);
apiRouter.use('/auth', authRouter);

// 举报管理台（发现页公开卡举报，提交走 /api/route/task 服务 104）：
// 列表与处理仅本机回环（SSH 隧道）或开发者登录后可访问
const reportsRouter = Router();
reportsRouter.get('/', listReports);
reportsRouter.post('/:id/dismiss', dismissReportHandler);
reportsRouter.post('/:id/takedown', takedownReportHandler);
apiRouter.use('/reports', requireDevAuth, reportsRouter);

export function registerRoutes(app) {
  app.use('/api', apiRouter);
}
