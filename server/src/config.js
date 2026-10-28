import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function loadEnvFile() {
  let text;
  try {
    text = fs.readFileSync(path.join(projectRoot, '.env'), 'utf8');
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
  port: Number(process.env.PORT ?? 3000),
  dataDir: process.env.DATA_DIR ?? path.join(projectRoot, 'data'),
  publicDir: process.env.PUBLIC_DIR ?? path.join(projectRoot, 'public'),
  // 开发者控制台页面目录：置于 publicDir（公开静态目录）之外，由 requireDevAuthPage 守卫按需下发
  consoleDir: process.env.CONSOLE_DIR ?? path.join(projectRoot, 'console'),
  // 开发者登录凭据文件（仅服务器本地，不进仓库）：{ user, salt, hash }
  devAuthFile: process.env.DEV_AUTH_FILE ?? path.join(projectRoot, 'dev-auth.json'),
  routingIpFile: process.env.ROUTING_IP_FILE ?? 'routing-ips.txt',
  cardFile: process.env.CARD_FILE ?? 'cards.txt',
  privateCardFile: process.env.PRIVATE_CARD_FILE ?? 'private-cards.txt',
  cardGroupFile: process.env.CARD_GROUP_FILE ?? 'card-groups.txt',
  privateGroupTombstoneFile: process.env.PRIVATE_GROUP_TOMBSTONE_FILE ?? 'private-group-tombstones.txt',
  userRelationFile: process.env.USER_RELATION_FILE ?? 'user-relations.txt',
  userProfileFile: process.env.USER_PROFILE_FILE ?? 'user-profile.txt',
  conversationFile: process.env.CONVERSATION_FILE ?? 'conversations.txt',
  accountFile: process.env.ACCOUNT_FILE ?? 'accounts.txt',
  friendRequestFile: process.env.FRIEND_REQUEST_FILE ?? 'friend-requests.txt',
  cardRequestFile: process.env.CARD_REQUEST_FILE ?? 'card-requests.txt',
  cardExtendRequestFile: process.env.CARD_EXTEND_REQUEST_FILE ?? 'card-extend-requests.txt',
  groupJoinRequestFile: process.env.GROUP_JOIN_REQUEST_FILE ?? 'group-join-requests.txt',
  cardReportFile: process.env.CARD_REPORT_FILE ?? 'card-reports.txt',
  noticeFile: process.env.NOTICE_FILE ?? 'notices.txt',
  reminderFile: process.env.REMINDER_FILE ?? 'reminders.txt',
  mailboxFile: process.env.MAILBOX_FILE ?? 'mailbox.txt',
  chatFile: process.env.CHAT_FILE ?? 'chats.txt',
  groupChatFile: process.env.GROUP_CHAT_FILE ?? 'group-chats.txt',
  postcardOutboxFile: process.env.POSTCARD_OUTBOX_FILE ?? 'postcards-outbox.txt',
  ai: {
    baseUrl: process.env.AI_BASE_URL ?? 'https://api.deepseek.com/v1',
    keyFile: process.env.AI_KEY_FILE ?? path.join(projectRoot, 'ai-api-key.txt'),
    model: process.env.AI_MODEL ?? 'deepseek-chat',
    temperature: Number(process.env.AI_TEMPERATURE ?? 0.2),
    timeoutMs: Number(process.env.AI_TIMEOUT_MS ?? 60000),
    maxRetries: Number(process.env.AI_MAX_RETRIES ?? 1)
  },
  qweather: {
    // 和风天气：自 2024 起改为「专属 API Host + 仅 HTTPS」，Host 在控制台-设置 查看
    apiHost: process.env.QW_API_HOST ?? 'kq487vbj9d.re.qweatherapi.com',
    // API Key 独立文件保存，调用时读取（与 ai-api-key.txt 同一惯例）
    keyFile: process.env.QW_KEY_FILE ?? path.join(projectRoot, 'qweather-api-key.txt'),
    timeoutMs: Number(process.env.QW_TIMEOUT_MS ?? 15000),
    // 无经纬度时用 IP 粗定位换算（免费、免 Key）；失败即降级，不阻塞天气查询
    ipGeoUrl: process.env.QW_IP_GEO_URL ?? 'http://ip-api.com/json'
  }
};
