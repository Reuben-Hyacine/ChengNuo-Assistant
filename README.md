# 程诺助手 ChengNuo

> AI 日程搭子 + 小企鹅养成 · HarmonyOS NEXT 全栈应用（ArkTS 客户端 + Node.js 服务端）

程诺助手是一款面向学生群体的 HarmonyOS 原生应用：把作业、考试、社团、实习等安排直接告诉 AI，自动生成可协作的日程卡片；月历、倒计时、天气一目了然；完成日程还能喂养专属小企鹅，用积分兑换装扮。

## 功能亮点

### 日程（首页）
- **AI 对话建卡**：自然语言描述安排，AI 自动生成日程卡片，可整理进卡片组、调整时间
- **月历视图**：节日标注（休息日红字）、生日标记、今日高亮
- **完成反馈**：碎卡动画收卡，AI 自动生成回忆明信片
- **7 天提醒**：即将到期清单、到点应用内弹窗提醒
- **周报汇总**：完成率 / 设立 / 完成 / 延期统计
- **天气卡片**：定位城市实时天气（拒绝授权自动回退默认城市）

### 宠物养成
- 小企鹅打卡互动、改名
- 积分装饰商城：围巾、帽子等 15+ 装扮

### 发现
- AI 推荐卡片流，一键加入日程
- 活动卡片：已结束标记与加入保护

### 我的
- 个人资料：头像 / 昵称 / UID / 签名（内容审核）
- **倒计时**：生日、纪念日倒数日；本机相册背景图；每年重复自动数下一次
- 回忆明信片汇总
- 主题色、中英文界面切换

### 消息与协作
- 好友 / 卡片公开协作（好友加入）
- 消息轮询、未读徽章

### 桌面与锁屏
- **锁屏卡片**（Form Kit）：不解锁即可完成、延时或取消日程
- 天气变化自动重推保持一致

### 账号与安全
- 邮箱验证码注册（AppGallery Connect）
- 华为账号一键登录（Account Kit unionID）
- 账号名 / 邮箱 + 密码登录、忘记密码重置、换绑邮箱
- 注销账号（服务器端数据完整清理）
- 首启隐私弹窗与协议勾选门控

### 离线能力
- 服务器不可达时基础功能离线应答，联网后自动恢复

## 技术栈

**客户端（client/）**
- HarmonyOS NEXT · ArkTS / ArkUI · Stage 模型（API 23）
- 双模块：`entry` 应用 + `Chengnuo-backend` 共享 HAR
- AppGallery Connect：邮箱验证码（@hw-agconnect/cloud）
- Account Kit：华为账号一键登录
- Form Kit：锁屏卡片
- I18n：中英双语

**服务端（server/）**
- Node.js ≥ 20 · Express 5 · ES Modules
- 统一任务网关：`POST /api/route/task` 按 `serviceId` 分发，内置鉴权豁免清单
- 零外部数据库：纯文件持久化，systemd 部署
- 内置敏感词审核、好友 / 卡片协作 / 群聊 / 举报治理等完整业务

## 仓库结构

```text
├── client/
│   ├── Chengnuo-frontend/        # 应用主工程（entry 模块）
│   │   └── entry/src/main/ets/
│   │       ├── pages/            # 页面
│   │       ├── components/       # 通用组件
│   │       ├── net/              # 网络层（ServerGateway / EmailAuth）
│   │       ├── store/            # 状态管理
│   │       ├── form/             # 锁屏卡片（Form Kit）
│   │       └── ...
│   └── Chengnuo-backend/         # 共享 HAR 模块
├── server/
│   ├── src/
│   │   ├── routes/               # 路由
│   │   ├── controllers/          # 控制器
│   │   ├── services/             # 业务逻辑 + 文件存储
│   │   └── middleware/           # 中间件
│   └── scripts/                  # 辅助脚本
├── image/                        # 截图与美术素材
└── 功能与权限清单.md              # 功能与权限完整清单
```

## 快速开始

### 启动服务端

```bash
cd server
npm install
npm start        # 默认监听 3000 端口
```

### 配置 AI 与天气密钥（自备）

AI 功能（对话建卡、发现页推荐、回忆明信片等）由服务端转发调用 DeepSeek，仓库**不含任何密钥**，请自备：

1. 在 [DeepSeek 开放平台](https://platform.deepseek.com) 创建 API Key
2. 将 Key 存入 `server/ai-api-key.txt`（纯文本一行），重启服务端生效
3. 未配置时 AI 接口返回 503，其余功能不受影响

天气功能同样需要 [和风天气](https://console.qweather.com) 的 Key（存入 `server/qweather-api-key.txt`，并在 `server/.env` 设置 `QW_API_HOST`）。

模型、超时、Base URL 等参数均支持 `server/.env` 或环境变量覆盖（见 `server/src/config.js`）；`AI_BASE_URL` 可替换为任意 OpenAI 兼容接口。

### 运行客户端

1. 使用 DevEco Studio 打开 `client/Chengnuo-frontend`
2. 配置应用签名：File → Project Structure → Signing Configs
3. 云端能力（邮箱验证码等）依赖 AppGallery Connect 服务：需在 AGC 控制台创建自己的应用，并替换 `AppScope/resources/rawfile/agconnect-services.json`
4. 修改 `entry/src/main/ets/net/ServerGateway.ets` 中的 `CANDIDATE_BASES`，指向你的服务器地址

## 说明

- 本项目为个人全栈作品：客户端与服务端均为从零实现，覆盖账号体系、好友关系、卡片协作、消息、内容审核、锁屏卡片等完整链路
- 服务端按"零数据库"设计：持久化全部基于文件存储，便于小规模部署与迁移

## 版权

© 2026 沈宜其 · 保留所有权利。代码仅供学习交流，未经授权请勿用于商业用途或二次分发。
