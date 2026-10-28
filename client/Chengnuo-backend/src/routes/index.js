import { Router } from 'express';
import { getHealth } from '../controllers/health.controller.js';
import {
  listRoutingIps,
  suggestRoutingIps,
  addRoutingIp,
  selectRoutingIp,
  setPrimaryRoutingIp,
  removeRoutingIp
} from '../controllers/routingIp.controller.js';
import {
  listRouteServices,
  submitRouteTask
} from '../controllers/route.controller.js';
import { listMyPostcards, removeMyPostcard } from '../controllers/postcard.controller.js';

const apiRouter = Router();

// 客户端只保留：健康检查、路由 IP 库、经路由编号调用服务器。
// 用户资料库、公开卡片库、私人卡片库、对话记录库全部由服务器存储，客户端不再持有本地库。
apiRouter.get('/health', getHealth);

// 明信片只存在客户端本地文本文件（data/postcards.txt），控制台经此端点按账号读取
apiRouter.get('/postcards', listMyPostcards);
// 删除一张明信片（控制台「明信片」库的删除按钮）
apiRouter.delete('/postcards/:id', removeMyPostcard);

const routingIpsRouter = Router();
routingIpsRouter.get('/', listRoutingIps);
routingIpsRouter.get('/suggest', suggestRoutingIps);
routingIpsRouter.post('/', addRoutingIp);
routingIpsRouter.post('/select', selectRoutingIp);
routingIpsRouter.post('/:id/primary', setPrimaryRoutingIp);
routingIpsRouter.delete('/:id', removeRoutingIp);
apiRouter.use('/routing-ips', routingIpsRouter);

const routeRouter = Router();
routeRouter.get('/services', listRouteServices);
routeRouter.post('/task', submitRouteTask);
apiRouter.use('/route', routeRouter);

export function registerRoutes(app) {
  app.use('/api', apiRouter);
}