import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

/**
 * 个人空间资料库（服务 90/91 的存储层）：
 * - data/profiles.txt：JSONL，每账号一行 { account, gender, birthday, signature, province, city, hasAvatar, updatedAt }
 *   （昵称即账号名，不在资料里单独存储）
 * - data/avatars/<账号>.jpg：头像 JPEG（客户端压缩后 base64 上送，此处解码落盘）
 * 客户端在本地另存一份副本（HAR ProfileStore），本库只承担服务器侧的持久化。
 */

const FILE_PATH = path.join(config.dataDir, 'profiles.txt');
const AVATAR_DIR = path.join(config.dataDir, 'avatars');

/** 账号名 → 头像文件安全名（Windows/POSIX 禁用字符与空白替换为 _） */
function avatarFileName(account) {
  return `${String(account).replace(/[\\/:*?"<>|\s]/g, '_')}.jpg`;
}

let cache = new Map(); // account -> profile record
let loaded = false;
let chain = Promise.resolve();

function serialized(task) {
  const run = chain.then(task, task);
  chain = run.then(() => {}, () => {});
  return run;
}

async function ensureFiles() {
  await fs.mkdir(config.dataDir, { recursive: true });
  await fs.mkdir(AVATAR_DIR, { recursive: true });
  try {
    await fs.access(FILE_PATH);
  } catch {
    await fs.writeFile(FILE_PATH, '', 'utf8');
  }
}

function stripBom(text) {
  return text && text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
}

async function load() {
  await ensureFiles();
  const text = stripBom(await fs.readFile(FILE_PATH, 'utf8'));
  cache = new Map();
  text.split(/\r?\n/)
    .filter(line => line.trim() !== '')
    .forEach(line => {
      try {
        const parsed = JSON.parse(line);
        const account = typeof parsed.account === 'string' ? parsed.account.trim() : '';
        if (account === '') {
          return;
        }
        cache.set(account, {
          account,
          gender: typeof parsed.gender === 'string' ? parsed.gender : '',
          birthday: typeof parsed.birthday === 'string' ? parsed.birthday : '',
          signature: typeof parsed.signature === 'string' ? parsed.signature : '',
          province: typeof parsed.province === 'string' ? parsed.province : '',
          city: typeof parsed.city === 'string' ? parsed.city : '',
          hasAvatar: parsed.hasAvatar === true,
          updatedAt: typeof parsed.updatedAt === 'string' ? parsed.updatedAt : new Date().toISOString()
        });
      } catch {
        // 跳过损坏行
      }
    });
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

async function persist() {
  const lines = [...cache.values()].map(rec => JSON.stringify(rec));
  await fs.writeFile(FILE_PATH, lines.length ? `${lines.join('\n')}\n` : '', 'utf8');
}

function avatarPathOf(account) {
  return path.join(AVATAR_DIR, avatarFileName(account));
}

/** 读取该账号头像并编码为 base64（无头像/读取失败返回 null） */
export async function avatarBase64Of(account) {
  try {
    return await fs.readFile(avatarPathOf(account), 'base64');
  } catch {
    return null;
  }
}

async function writeAvatar(account, base64) {
  const buffer = Buffer.from(base64, 'base64');
  if (buffer.length === 0) {
    const err = new Error('头像数据为空，无法保存');
    err.status = 400;
    throw err;
  }
  await fs.mkdir(AVATAR_DIR, { recursive: true });
  await fs.writeFile(avatarPathOf(account), buffer);
}

async function removeAvatar(account) {
  try {
    await fs.unlink(avatarPathOf(account));
  } catch {
    // 头像不存在：幂等
  }
}

async function avatarFileExists(account) {
  try {
    await fs.access(avatarPathOf(account));
    return true;
  } catch {
    return false;
  }
}

/** 读取该账号的资料（profile 为 null 表示从未保存过） */
export function getProfileOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const rec = cache.get(account) ?? null;
    return { account, profile: rec ? { ...rec } : null };
  });
}

/**
 * 保存该账号的资料。
 * - fields：{ gender, birthday, signature, province, city }
 * - avatarBase64：undefined = 头像不动；null/'' = 删除头像；字符串 = 解码覆盖头像
 * hasAvatar 以实际落盘结果为准（避免档案行与头像文件脱节）。
 */
export function setProfileOf(account, fields, avatarBase64 = undefined) {
  return serialized(async () => {
    await ensureLoaded();
    let hasAvatar = (cache.get(account)?.hasAvatar === true) && await avatarFileExists(account);
    if (avatarBase64 === null || avatarBase64 === '') {
      await removeAvatar(account);
      hasAvatar = false;
    } else if (typeof avatarBase64 === 'string') {
      await writeAvatar(account, avatarBase64);
      hasAvatar = true;
    }
    const rec = {
      account,
      gender: fields.gender,
      birthday: fields.birthday,
      signature: fields.signature,
      province: fields.province,
      city: fields.city,
      hasAvatar,
      updatedAt: new Date().toISOString()
    };
    cache.set(account, rec);
    await persist();
    return { account, profile: { ...rec } };
  });
}

/** 改名（82）：资料记录与头像文件一并换名（目标名已有头像时先清掉，避免旧文件残留） */
export function renameProfileOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    const rec = cache.get(oldName);
    if (!rec) {
      return { renamed: 0 };
    }
    const hasAvatar = rec.hasAvatar === true && await avatarFileExists(oldName);
    if (hasAvatar) {
      await removeAvatar(newName);
      await fs.rename(avatarPathOf(oldName), avatarPathOf(newName));
    }
    cache.delete(oldName);
    cache.set(newName, { ...rec, account: newName });
    await persist();
    return { renamed: 1 };
  });
}

/** 注销（13）：清除资料记录与头像文件 */
export function clearProfileOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const existed = cache.delete(account);
    await removeAvatar(account);
    await persist();
    return { cleared: existed ? 1 : 0 };
  });
}
