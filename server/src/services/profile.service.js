import { checkText } from './moderation.service.js';
import { getProfileOf, setProfileOf, avatarBase64Of } from './profileStore.js';

/**
 * 个人空间服务（90 profile.get / 91 profile.update / 92 profile.avatar）：
 * - 字段：性别（''/男/女/不公开）/ 生日（''或 YYYY-MM-DD）/ 个性签名（≤100 字、过智能审核）/ 地区（省/市，≤40 字）
 * - 昵称即账号名（账号模块 82 改名），个人空间不再单独存昵称
 * - 头像：avatarBase64（纯 base64，JPEG）随 91 上送解码落盘；90 带 withAvatar=true 时回传；
 *   92 按 targetAccount 查任意账号的头像（好友列表头像用，登录即可调用）
 * - 客户端在本地另存一份副本；本服务只负责服务器侧的校验与持久化
 */

const GENDERS = new Set(['', '男', '女', '不公开']);
const SIGNATURE_MAX = 100;
const REGION_MAX = 40;
const AVATAR_BASE64_MAX = 2_600_000; // ≈1.9MB 二进制（客户端压缩后约 30-110KB）

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function rejected(message) {
  const err = new Error(message);
  err.status = 409;
  return err;
}

function textOrNull(value, max, label) {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value !== 'string') {
    throw badRequest(`${label}必须是字符串`);
  }
  const text = value.trim();
  if (text.length > max) {
    throw badRequest(`${label}最长 ${max} 字`);
  }
  return text;
}

/** YYYY-MM-DD 且为真实日期 */
function isValidBirthday(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false;
  }
  const [y, m, d] = value.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  return date.getFullYear() === y && date.getMonth() === m - 1 && date.getDate() === d;
}

/** profile.get（90）：account 由路由层按 token 注入；withAvatar=true 时附带头像 base64 */
export async function getMyProfile(payload = {}) {
  const { account, withAvatar = false } = payload;
  if (typeof account !== 'string' || account.trim() === '') {
    throw badRequest('需要账号身份才能读取个人空间');
  }
  const name = account.trim();
  const found = await getProfileOf(name);
  const out = { account: name, found: found.profile !== null };
  if (found.profile !== null) {
    out.profile = found.profile;
    if (withAvatar === true && found.profile.hasAvatar) {
      out.avatarBase64 = await avatarBase64Of(name);
    }
  }
  return out;
}

/** profile.update（91）：account 由路由层按 token 注入；全部字段整体覆盖（客户端保存整份记录） */
export async function updateMyProfile(payload = {}) {
  const { account } = payload;
  if (typeof account !== 'string' || account.trim() === '') {
    throw badRequest('需要账号身份才能保存个人空间');
  }
  const name = account.trim();

  const gender = payload.gender === undefined ? '' : payload.gender;
  if (!GENDERS.has(gender)) {
    throw badRequest('性别只能是：男 / 女 / 不公开');
  }

  const birthday = textOrNull(payload.birthday, 10, '生日');
  if (birthday !== '' && !isValidBirthday(birthday)) {
    throw badRequest('生日格式应为 YYYY-MM-DD 的真实日期');
  }

  const signature = textOrNull(payload.signature, SIGNATURE_MAX, '个性签名');
  if (signature !== '' && !checkText(signature).pass) {
    throw rejected('个性签名未通过智能审核 ✍️');
  }

  const province = textOrNull(payload.province, REGION_MAX, '省份');
  const city = textOrNull(payload.city, REGION_MAX, '城市');

  // 头像：未传 = 保持不动；null/'' = 删除；字符串 = 纯 base64（JPEG）解码落盘
  let avatarBase64 = undefined;
  if (payload.avatarBase64 !== undefined) {
    if (payload.avatarBase64 === null || payload.avatarBase64 === '') {
      avatarBase64 = null;
    } else {
      if (typeof payload.avatarBase64 !== 'string') {
        throw badRequest('头像数据必须是 base64 字符串');
      }
      let base64 = payload.avatarBase64.trim();
      const dataUriPrefix = 'data:image/';
      const commaIndex = base64.indexOf(',');
      if (base64.startsWith(dataUriPrefix) && commaIndex >= 0) {
        base64 = base64.substring(commaIndex + 1);
      }
      if (base64 === '') {
        avatarBase64 = null;
      } else {
        if (base64.length > AVATAR_BASE64_MAX) {
          throw badRequest('头像文件过大，请换一张 ✉️');
        }
        avatarBase64 = base64;
      }
    }
  }

  const saved = await setProfileOf(name, { gender, birthday, signature, province, city }, avatarBase64);
  return { account: name, profile: saved.profile, message: '个人空间已保存' };
}

/**
 * profile.avatar（92）：按 targetAccount 查任意账号的头像（payload 用 targetAccount 而非 account，
 * 后者会被路由层按 token 覆盖）。返回 found（有无资料记录）/ hasAvatar / avatarBase64 / updatedAt，
 * 供客户端在好友列表按 avatarUpdatedAt 决定是否重新拉取。
 */
export async function getAvatarOfAccount(payload = {}) {
  const { targetAccount } = payload;
  if (typeof targetAccount !== 'string' || targetAccount.trim() === '') {
    throw badRequest('需要目标账号');
  }
  const name = targetAccount.trim();
  const found = await getProfileOf(name);
  const out = { account: name, found: found.profile !== null, hasAvatar: false, updatedAt: null };
  if (found.profile !== null) {
    out.updatedAt = typeof found.profile.updatedAt === 'string' ? found.profile.updatedAt : null;
    if (found.profile.hasAvatar === true) {
      const base64 = await avatarBase64Of(name);
      if (base64 !== null) {
        out.hasAvatar = true;
        out.avatarBase64 = base64;
      }
    }
  }
  return out;
}
