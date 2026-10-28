import { promises as fs } from 'node:fs';
import { dataFilePath, ensureFile, serializedChain } from './jsonl.js';

// 登录状态文件（客户端本地 login-state.txt）：首行 0=未登录 / 1=已登录；
// 已登录时第二行=账号、第三行=密码。登录（11）/ 注册（10）成功后写 1 + 凭据，
// 退出登录（12）/ 注销账号（13）成功后写 0 并清掉凭据。
// App 启动时经服务 9（auth.login-state）读取：状态为 1 时用记录的账号密码自动登录，不再显示登录界面。
const FILE_PATH = dataFilePath('login-state.txt');
const run = serializedChain();

function parseText(text) {
  const lines = text.split(/\r?\n/).map(s => s.trim()).filter(s => s !== '');
  if (lines.length >= 3 && lines[0] === '1' && lines[1] !== '' && lines[2] !== '') {
    return { state: 1, account: lines[1], password: lines[2] };
  }
  // 两行式（游客/自动建号）：1 + 账号，密码留空（81/78 自动建号后写入，冷启动按空密码自动登录）
  if (lines.length === 2 && lines[0] === '1' && lines[1] !== '') {
    return { state: 1, account: lines[1], password: '' };
  }
  return { state: 0, account: '', password: '' };
}

// 确保文件存在：缺省内容 0（未登录）
export function ensureLoginStateFile() {
  return run(async () => {
    await ensureFile(FILE_PATH);
    const text = await fs.readFile(FILE_PATH, 'utf8');
    if (text.trim() === '') {
      await fs.writeFile(FILE_PATH, '0\n', 'utf8');
    }
    return true;
  });
}

// 读取登录状态（不联网、不发请求）
export function getLoginState() {
  return run(async () => {
    await ensureFile(FILE_PATH);
    const text = await fs.readFile(FILE_PATH, 'utf8');
    return parseText(text);
  });
}

// 登录 / 注册成功：写 1 并记录账号密码；凭据不完整时保持原状态不落 1
export function markLoggedIn({ account, password }) {
  return run(async () => {
    const name = typeof account === 'string' ? account.trim() : '';
    const pass = typeof password === 'string' ? password.trim() : '';
    if (name === '' || pass === '') {
      // 直接读文件（不能经 getLoginState：同一条串行链会自等待死锁）
      await ensureFile(FILE_PATH);
      const text = await fs.readFile(FILE_PATH, 'utf8');
      return parseText(text);
    }
    await fs.writeFile(FILE_PATH, `1\n${name}\n${pass}\n`, 'utf8');
    return { state: 1, account: name, password: pass };
  });
}

// 游客登录 / 自动建号成功（81）：写 1 只记账号、不记密码（密码为空，冷启动按空密码自动登录）
export function markGuestLoggedIn({ account }) {
  return run(async () => {
    const name = typeof account === 'string' ? account.trim() : '';
    if (name === '') {
      await ensureFile(FILE_PATH);
      const text = await fs.readFile(FILE_PATH, 'utf8');
      return parseText(text);
    }
    await fs.writeFile(FILE_PATH, `1\n${name}\n`, 'utf8');
    return { state: 1, account: name, password: '' };
  });
}

// 改名（82）：登录态记录的账号同步换名（密码原样保留；游客两行式保持两行式）
export function renameLoggedInAccount({ account, newAccount }) {
  return run(async () => {
    const oldName = typeof account === 'string' ? account.trim() : '';
    const newName = typeof newAccount === 'string' ? newAccount.trim() : '';
    if (oldName === '' || newName === '') {
      return null;
    }
    await ensureFile(FILE_PATH);
    const text = await fs.readFile(FILE_PATH, 'utf8');
    const current = parseText(text);
    if (current.state !== 1 || current.account !== oldName) {
      return current;
    }
    if (current.password !== '') {
      await fs.writeFile(FILE_PATH, `1\n${newName}\n${current.password}\n`, 'utf8');
      return { state: 1, account: newName, password: current.password };
    }
    await fs.writeFile(FILE_PATH, `1\n${newName}\n`, 'utf8');
    return { state: 1, account: newName, password: '' };
  });
}

// 退出登录 / 注销账号：写 0 并删除记录的账号密码
export function markLoggedOut() {
  return run(async () => {
    await fs.writeFile(FILE_PATH, '0\n', 'utf8');
    return { state: 0, account: '', password: '' };
  });
}
