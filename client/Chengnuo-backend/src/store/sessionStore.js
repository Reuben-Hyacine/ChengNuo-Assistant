import { dataFilePath, readJsonl, writeJsonl, serializedChain } from './jsonl.js';

// 登录会话映射（客户端本地）：token -> 账号 / 用户编号。
// App 的本地化服务（AI 对话记录、好友对话、私人卡片组同步）需要知道请求属于哪个账号，
// 而服务器按 token 反解身份、payload 里并不带账号，所以客户端在登录成功时记下映射，供本地应答使用。
// 服务器重启会作废 token：此时本地查不到也可继续保留，下一次登录会刷新映射。
const FILE_PATH = dataFilePath('sessions.txt');

let cache = new Map(); // token -> { token, account, userId, loginAt }
let loaded = false;
const run = serializedChain();

function accountName(account) {
  return typeof account === 'string' ? account.trim() : '';
}

async function ensureLoaded() {
  if (loaded) {
    return;
  }
  const records = await readJsonl(FILE_PATH);
  cache = new Map();
  for (const rec of records) {
    const token = typeof rec?.token === 'string' ? rec.token.trim() : '';
    const account = accountName(rec?.account);
    if (token === '' || account === '') {
      continue;
    }
    cache.set(token, {
      token,
      account,
      userId: Number.isInteger(rec?.userId) ? rec.userId : null,
      loginAt: typeof rec?.loginAt === 'string' ? rec.loginAt : null
    });
  }
  loaded = true;
}

async function persist() {
  await writeJsonl(FILE_PATH, [...cache.values()]);
}

// 登录成功：记下 token 与账号；同一账号只保留最新一次登录的 token
export function rememberLogin({ token, account, userId = null }) {
  return run(async () => {
    await ensureLoaded();
    const key = typeof token === 'string' ? token.trim() : '';
    const name = accountName(account);
    if (key === '' || name === '') {
      return null;
    }
    for (const [t, rec] of cache) {
      if (rec.account === name && t !== key) {
        cache.delete(t);
      }
    }
    const rec = { token: key, account: name, userId: Number.isInteger(userId) ? userId : null, loginAt: new Date().toISOString() };
    cache.set(key, rec);
    await persist();
    return { ...rec };
  });
}

// 退出登录 / 注销：按 token 或账号移除映射
export function forgetSession({ token = null, account = null }) {
  return run(async () => {
    await ensureLoaded();
    const key = typeof token === 'string' ? token.trim() : '';
    const name = accountName(account);
    let removed = 0;
    for (const [t, rec] of cache) {
      if ((key !== '' && t === key) || (name !== '' && rec.account === name)) {
        cache.delete(t);
        removed += 1;
      }
    }
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 按 token 查会话（本地内存/文件，不发网络请求）
export function resolveSession(token) {
  return run(async () => {
    await ensureLoaded();
    const key = typeof token === 'string' ? token.trim() : '';
    if (key === '') {
      return null;
    }
    const rec = cache.get(key);
    return rec ? { ...rec } : null;
  });
}

// 改名（82）：会话映射里该账号的记录同步换名（token 不变，只改 account 字段）
export function renameAccountOf({ account = null, newAccount = null }) {
  return run(async () => {
    await ensureLoaded();
    const oldName = accountName(account);
    const newName = accountName(newAccount);
    if (oldName === '' || newName === '' || oldName === newName) {
      return { renamed: 0 };
    }
    let renamed = 0;
    for (const [, rec] of cache) {
      if (rec.account === oldName) {
        rec.account = newName;
        renamed += 1;
      }
    }
    if (renamed > 0) {
      await persist();
    }
    return { renamed };
  });
}