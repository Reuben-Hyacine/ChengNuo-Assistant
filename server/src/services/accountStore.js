import { promises as fs } from 'node:fs';
import path from 'node:path';
import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { config } from '../config.js';

// 注册表（账号 + 密码）持久化到服务器 data/accounts.txt
// 密码不存明文：scrypt 加盐哈希；文件按 JSON 行存储并剥离 BOM
const FILE_PATH = path.join(config.dataDir, config.accountFile);

let cache = [];
let nextId = 1;
let loaded = false;
let chain = Promise.resolve();

function serialized(task) {
  const run = chain.then(task, task);
  chain = run.then(() => {}, () => {});
  return run;
}

function stripBom(text) {
  return text && text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
}

async function ensureFile() {
  await fs.mkdir(config.dataDir, { recursive: true });
  try {
    await fs.access(FILE_PATH);
  } catch {
    await fs.writeFile(FILE_PATH, '', 'utf8');
  }
}

async function load() {
  await ensureFile();
  const text = stripBom(await fs.readFile(FILE_PATH, 'utf8'));
  cache = [];
  text.split(/\r?\n/)
    .filter(line => line.trim() !== '')
    .forEach(line => {
      try {
        const parsed = JSON.parse(line);
        if (parsed && typeof parsed.account === 'string') {
          cache.push(parsed);
        }
      } catch {
        // 跳过损坏行
      }
    });
  nextId = cache.reduce((max, entry) => Math.max(max, entry.id), 0) + 1;
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

async function persist() {
  const text = cache.map(entry => JSON.stringify(entry)).join('\n');
  await fs.writeFile(FILE_PATH, text === '' ? '' : text + '\n', 'utf8');
}

function hashPassword(password) {
  const salt = randomBytes(16).toString('hex');
  const hash = scryptSync(password, salt, 64).toString('hex');
  return { salt, hash };
}

function verifyPassword(password, salt, hash) {
  try {
    const expected = Buffer.from(hash, 'hex');
    const actual = scryptSync(password, salt, 64);
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}

function view(entry) {
  return { id: entry.id, account: entry.account, userId: entry.userId, createdAt: entry.createdAt };
}

// 账号列表（不含密码哈希），供用户列表展示与好友搜索
export function listAccounts() {
  return serialized(async () => {
    await ensureLoaded();
    return cache.map(view);
  });
}

// 按账号名查询单个账号视图（不存在返回 null）
export function findAccount(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    const entry = cache.find(item => item.account === name);
    return entry ? view(entry) : null;
  });
}

// 按 userId 查询单个账号视图（不存在返回 null）
export function findAccountByUserId(userId) {
  return serialized(async () => {
    await ensureLoaded();
    const entry = cache.find(item => item.userId === userId);
    return entry ? view(entry) : null;
  });
}

// 注册新账号：账号查重，userId 从 1 开始取当前最小可用编号（注销后编号回收复用，不预留）
export function registerAccount({ account, password }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    if (!name || name.length > 32) {
      const err = new Error('账号名必须为 1-32 个字符');
      err.status = 400;
      throw err;
    }
    if (typeof password !== 'string' || password.length < 1 || password.length > 64) {
      const err = new Error('密码长度必须为 1-64 位');
      err.status = 400;
      throw err;
    }
    if (cache.some(entry => entry.account === name)) {
      const err = new Error('账号已存在');
      err.status = 409;
      throw err;
    }
    // userId 分配：从 1 开始找最小空缺编号，注销账号后其编号会被新账号回收复用
    const usedUserIds = new Set(
      cache.map(entry => entry.userId).filter(id => Number.isInteger(id) && id >= 1)
    );
    let userId = 1;
    while (usedUserIds.has(userId)) {
      userId += 1;
    }
    const { salt, hash } = hashPassword(password);
    const entry = {
      id: nextId++,
      account: name,
      salt,
      hash,
      userId,
      createdAt: new Date().toISOString()
    };
    cache.push(entry);
    await persist();
    return view(entry);
  });
}

// 注销账号：从注册表删除账号记录，返回被删账号信息（不含密码哈希）
export function deleteAccount({ account }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    const index = cache.findIndex(entry => entry.account === name);
    if (index === -1) {
      return null;
    }
    const [removed] = cache.splice(index, 1);
    await persist();
    return view(removed);
  });
}

// 登录校验（邮箱唯一匹配）：有 email 字段的账号只能按邮箱（小写归一）登录，账号名（昵称）不再作为登录标识；
// 老账号（无 email 字段）的账号名就是登录标识。账号不存在 404，密码错误 401
export function loginAccount({ account, password }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    let entry = null;
    if (name !== '') {
      const emailKey = name.toLowerCase();
      entry = cache.find(item => {
        const storedEmail = normalizeEmail(item.email);
        return storedEmail !== '' ? storedEmail === emailKey : item.account === name;
      });
    }
    if (!entry) {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    if (!verifyPassword(password, entry.salt, entry.hash)) {
      const err = new Error('密码错误');
      err.status = 401;
      throw err;
    }
    return view(entry);
  });
}

// 注销验证专用（13）：客户端注销时发送的是展示账号名（邮箱账号的昵称）而非邮箱，
// 此处按「账号名 或 邮箱（小写归一）」双匹配查找后再验密码；登录（11）仍只认邮箱，语义不变
export function loginByNameOrEmail({ account, password }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    if (name === '') {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    const emailKey = name.toLowerCase();
    const entry = cache.find(item => normalizeEmail(item.email) === emailKey || item.account === name);
    if (!entry) {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    if (!verifyPassword(password, entry.salt, entry.hash)) {
      const err = new Error('密码错误');
      err.status = 401;
      throw err;
    }
    return view(entry);
  });
}

// ---------- 华为账号（Account Kit）绑定 ----------
// unionID 是华为账号在同一开发者账号下的唯一标识；一个华为账号同一时间只能绑定一个程诺账号。
// 绑定信息随账号记录持久化在 accounts.txt，服务器重启不丢；注销账号时随记录一并删除。

function normalizeUnionId(unionId) {
  return typeof unionId === 'string' ? unionId.trim() : '';
}

// 按华为 unionID 反查已绑定的账号（不存在返回 null）
export function findAccountByHuaweiUnionId(unionId) {
  return serialized(async () => {
    await ensureLoaded();
    const key = normalizeUnionId(unionId);
    const entry = cache.find(item => item.huaweiUnionId === key);
    return entry ? view(entry) : null;
  });
}

// 把华为账号绑定到当前程诺账号：unionId 已被其他账号占用时 409；同一账号重复绑定幂等成功
export function bindHuaweiId({ account, unionId, openId }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    const key = normalizeUnionId(unionId);
    if (key === '' || key.length > 256) {
      const err = new Error('unionId 必须为 1-256 个字符');
      err.status = 400;
      throw err;
    }
    const entry = cache.find(item => item.account === name);
    if (!entry) {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    const holder = cache.find(item => item.huaweiUnionId === key && item.account !== name);
    if (holder) {
      const err = new Error(`该华为账号已绑定账号「${holder.account}」，请先在该账号上解除绑定`);
      err.status = 409;
      throw err;
    }
    entry.huaweiUnionId = key;
    entry.huaweiOpenId = typeof openId === 'string' && openId.trim() !== '' ? openId.trim() : null;
    await persist();
    return { ...view(entry), huaweiBound: true, huaweiUnionId: key };
  });
}

// 解除当前账号的华为账号绑定（幂等，未绑定时同样成功）
export function unbindHuaweiId({ account }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    const entry = cache.find(item => item.account === name);
    if (!entry) {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    const wasBound = Boolean(entry.huaweiUnionId);
    entry.huaweiUnionId = null;
    entry.huaweiOpenId = null;
    await persist();
    return { ...view(entry), huaweiBound: false, wasBound };
  });
}

// ---------- 自动建号与账号自助管理（游客 / 华为一键登录 / 修改账号名 / 设置密码） ----------
// 自动账号名保留「UID + 编号」格式（如 UID00021），禁止用户手动注册或改名占用，
// 保证自动账号名永远不与用户自选名冲突。

export function isAutoAccountName(name) {
  return typeof name === 'string' && /^UID\d+$/.test(name.trim());
}

// 自动建号：免填账号密码——账号名 = UID + 5 位零填充 userId，密码 = 空字符串（哈希照常落库，空密码可登录）。
// userId 沿用注册的「最小空缺编号」分配；若生成的名字恰被手动注册占用则继续向后取号。
export function createAutoAccount() {
  return serialized(async () => {
    await ensureLoaded();
    const usedUserIds = new Set(
      cache.map(entry => entry.userId).filter(id => Number.isInteger(id) && id >= 1)
    );
    let userId = 1;
    while (usedUserIds.has(userId) || cache.some(entry => entry.account === `UID${String(userId).padStart(5, '0')}`)) {
      userId += 1;
    }
    const { salt, hash } = hashPassword('');
    const entry = {
      id: nextId++,
      account: `UID${String(userId).padStart(5, '0')}`,
      salt,
      hash,
      userId,
      createdAt: new Date().toISOString()
    };
    cache.push(entry);
    await persist();
    return view(entry);
  });
}

// 修改账号名：新名沿用注册名校验，另禁止占用自动账号名保留格式；
// 账号名在多个业务库中作外键，改名级联由 auth.service.renameAccountOfSession 统一驱动
export function renameAccountOf({ account, newAccount }) {
  return serialized(async () => {
    await ensureLoaded();
    const oldName = typeof account === 'string' ? account.trim() : '';
    const entry = cache.find(item => item.account === oldName);
    if (!entry) {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    const name = typeof newAccount === 'string' ? newAccount.trim() : '';
    if (!name || name.length > 32) {
      const err = new Error('账号名必须为 1-32 个字符');
      err.status = 400;
      throw err;
    }
    if (isAutoAccountName(name)) {
      const err = new Error('账号名不能使用 UID+数字 的保留格式');
      err.status = 400;
      throw err;
    }
    if (name === oldName) {
      const err = new Error('新账号名与当前账号名相同');
      err.status = 400;
      throw err;
    }
    if (cache.some(item => item.account === name)) {
      const err = new Error('账号已存在');
      err.status = 409;
      throw err;
    }
    entry.account = name;
    await persist();
    return view(entry);
  });
}

// 设置密码：空密码（自动建号）账号可直接设置；已有密码的账号须先验旧密码（错误 401）
export function setPasswordOf({ account, oldPassword = '', newPassword }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    const entry = cache.find(item => item.account === name);
    if (!entry) {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    const emptyCurrent = verifyPassword('', entry.salt, entry.hash);
    if (!emptyCurrent && !verifyPassword(typeof oldPassword === 'string' ? oldPassword : '', entry.salt, entry.hash)) {
      const err = new Error('旧密码错误');
      err.status = 401;
      throw err;
    }
    if (typeof newPassword !== 'string' || newPassword.length < 1 || newPassword.length > 64) {
      const err = new Error('密码长度必须为 1-64 位');
      err.status = 400;
      throw err;
    }
    const { salt, hash } = hashPassword(newPassword);
    entry.salt = salt;
    entry.hash = hash;
    await persist();
    return view(entry);
  });
}

// 查询当前账号的华为账号绑定状态
export function huaweiBindingOf({ account }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    const entry = cache.find(item => item.account === name);
    if (!entry) {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    return {
      ...view(entry),
      huaweiBound: Boolean(entry.huaweiUnionId),
      huaweiUnionId: entry.huaweiUnionId ?? null,
      huaweiOpenId: entry.huaweiOpenId ?? null
    };
  });
}

// ---------- 邮箱账号（AGC 邮箱验证码注册） ----------
// 邮箱是唯一登录标识，与账号名（昵称）分离：账号记录附可选 email 字段，有 email 的账号只能按邮箱登录；
// 老账号（无 email 字段）的账号名就是登录标识；邮箱账号可随时改昵称（82）而不影响邮箱登录。
// 邮箱验证码的发送与校验由 App 侧经 AGC 认证服务完成（requestVerifyCode + createUser / resetPassword），
// 服务器只负责建号、签发会话与密码哈希的存储校验。

function normalizeEmail(email) {
  return typeof email === 'string' ? email.trim().toLowerCase() : '';
}

// 按邮箱查询单个账号视图（不存在返回 null）
export function findAccountByEmail(email) {
  return serialized(async () => {
    await ensureLoaded();
    const key = normalizeEmail(email);
    const entry = cache.find(item => item.email === key);
    return entry ? view(entry) : null;
  });
}

// 邮箱注册建号（85）：账号名沿用自动建号保留格式（UID+编号），密码为空字符串（界面 2 或「忘记密码」再设置）；
// 邮箱唯一——已注册的邮箱 409（正常流程下 AGC 侧 createUser 已先行拦截重复邮箱，此处兜底防并发直调）
export function createEmailAccount({ email }) {
  return serialized(async () => {
    await ensureLoaded();
    const key = normalizeEmail(email);
    if (key === '' || key.length > 254 || !key.includes('@')) {
      const err = new Error('邮箱格式无效');
      err.status = 400;
      throw err;
    }
    if (cache.some(entry => entry.email === key)) {
      const err = new Error('该邮箱已注册，请直接登录');
      err.status = 409;
      throw err;
    }
    const usedUserIds = new Set(
      cache.map(entry => entry.userId).filter(id => Number.isInteger(id) && id >= 1)
    );
    let userId = 1;
    while (usedUserIds.has(userId) || cache.some(entry => entry.account === `UID${String(userId).padStart(5, '0')}`)) {
      userId += 1;
    }
    const { salt, hash } = hashPassword('');
    const entry = {
      id: nextId++,
      account: `UID${String(userId).padStart(5, '0')}`,
      salt,
      hash,
      userId,
      email: key,
      createdAt: new Date().toISOString()
    };
    cache.push(entry);
    await persist();
    return view(entry);
  });
}

// 按邮箱重置密码（86，找回密码）：App 侧经 AGC 验证码校验后调用，服务器不再验旧密码；
// 仅邮箱注册的账号有 email 字段，老账号不适用（保留原密码登录）
export function resetPasswordByEmail({ email, newPassword }) {
  return serialized(async () => {
    await ensureLoaded();
    const key = normalizeEmail(email);
    const entry = cache.find(item => item.email === key);
    if (!entry) {
      const err = new Error('该邮箱未注册');
      err.status = 404;
      throw err;
    }
    if (typeof newPassword !== 'string' || newPassword.length < 1 || newPassword.length > 64) {
      const err = new Error('密码长度必须为 1-64 位');
      err.status = 400;
      throw err;
    }
    const { salt, hash } = hashPassword(newPassword);
    entry.salt = salt;
    entry.hash = hash;
    await persist();
    return view(entry);
  });
}

// 邮箱绑定状态查询（95）：emailBound=是否已绑定，email 为绑定邮箱（未绑定为 null）
export function emailBindingOf({ account }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    const entry = cache.find(item => item.account === name);
    if (!entry) {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    return {
      ...view(entry),
      emailBound: Boolean(entry.email),
      email: entry.email ?? null,
      hasPassword: !verifyPassword('', entry.salt, entry.hash)
    };
  });
}

// 绑定/换绑邮箱（96）：邮箱归一后跨账号唯一（被其他账号占用 409），AGC 验证码由 App 侧校验；
// 绑定后该账号只能按邮箱登录（账号名退化为昵称）。重复绑定当前邮箱幂等成功（unchanged）
export function bindEmailOf({ account, email }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    const entry = cache.find(item => item.account === name);
    if (!entry) {
      const err = new Error('账号不存在');
      err.status = 404;
      throw err;
    }
    const key = normalizeEmail(email);
    if (key === '' || key.length > 254 || !key.includes('@')) {
      const err = new Error('邮箱格式无效');
      err.status = 400;
      throw err;
    }
    const taken = cache.find(item => item !== entry && item.email === key);
    if (taken) {
      const err = new Error(`该邮箱已绑定账号「${taken.account}」，请换用其他邮箱`);
      err.status = 409;
      throw err;
    }
    const wasBound = Boolean(entry.email);
    const unchanged = entry.email === key;
    if (!unchanged) {
      entry.email = key;
      await persist();
    }
    return { ...view(entry), emailBound: true, email: key, wasBound, unchanged };
  });
}
