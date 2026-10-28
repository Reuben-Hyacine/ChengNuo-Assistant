import { JsonRec, Jsonl } from '../Jsonl';

/** 登录状态：state=1 时 account/password 非空（App 冷启动自动登录用） */
export class LoginState {
  readonly state: number;
  readonly account: string;
  readonly password: string;

  constructor(state: number, account: string, password: string) {
    this.state = state;
    this.account = account;
    this.password = password;
  }

  toRecord(): Record<string, Object> {
    return { 'state': this.state, 'account': this.account, 'password': this.password };
  }
}

/**
 * login-state.txt：首行 0=未登录 / 1=已登录；已登录时第二行=账号、第三行=密码。
 * 登录（11）/ 注册（10）成功后写 1 + 凭据，退出（12）/ 注销（13）成功后写 0 清凭据。
 */
export class LoginStateStore {
  private filePath(): string {
    return Jsonl.dataFilePath('login-state.txt');
  }

  private parseText(text: string): LoginState {
    const rawLines: string[] = Jsonl.splitLines(text);
    const lines: string[] = [];
    for (let i = 0; i < rawLines.length; i++) {
      const line: string = rawLines[i].trim();
      if (line.length > 0) {
        lines.push(line);
      }
    }
    if (lines.length >= 3 && lines[0] === '1' && lines[1].length > 0 && lines[2].length > 0) {
      return new LoginState(1, lines[1], lines[2]);
    }
    // 两行式（游客/自动建号）：1 + 账号，密码留空（81/78 自动建号后写入，冷启动按空密码自动登录）
    if (lines.length === 2 && lines[0] === '1' && lines[1].length > 0) {
      return new LoginState(1, lines[1], '');
    }
    return new LoginState(0, '', '');
  }

  /** 确保文件存在：缺省内容 0（未登录） */
  ensureLoginStateFile(): void {
    const filePath: string = this.filePath();
    Jsonl.ensureFile(filePath);
    const text: string = Jsonl.readText(filePath);
    if (text.trim().length === 0) {
      Jsonl.writeText(filePath, '0\n');
    }
  }

  /** 读取登录状态（不联网、不发请求），服务 9 */
  getLoginState(): LoginState {
    const filePath: string = this.filePath();
    Jsonl.ensureFile(filePath);
    return this.parseText(Jsonl.readText(filePath));
  }

  /** 登录 / 注册成功：写 1 并记录账号密码；凭据不完整时保持原状态不落 1 */
  markLoggedIn(account: Object | null, password: Object | null): LoginState {
    const name: string = JsonRec.trimText(account);
    const pass: string = JsonRec.trimText(password);
    const filePath: string = this.filePath();
    if (name.length === 0 || pass.length === 0) {
      Jsonl.ensureFile(filePath);
      return this.parseText(Jsonl.readText(filePath));
    }
    Jsonl.writeText(filePath, `1\n${name}\n${pass}\n`);
    return new LoginState(1, name, pass);
  }

  /** 游客登录 / 自动建号成功（81）：写 1 只记账号、不记密码（密码为空，冷启动按空密码自动登录） */
  markGuestLoggedIn(account: Object | null): LoginState {
    const name: string = JsonRec.trimText(account);
    if (name.length === 0) {
      return this.getLoginState();
    }
    Jsonl.writeText(this.filePath(), `1\n${name}\n`);
    return new LoginState(1, name, '');
  }

  /** 改名（82）：登录态记录的账号同步换名（密码原样保留；游客两行式保持两行式） */
  renameLoggedInAccount(account: Object | null, newAccount: Object | null): LoginState {
    const oldName: string = JsonRec.trimText(account);
    const newName: string = JsonRec.trimText(newAccount);
    const current: LoginState = this.getLoginState();
    if (oldName.length === 0 || newName.length === 0 || current.state !== 1 || current.account !== oldName) {
      return current;
    }
    if (current.password.length > 0) {
      Jsonl.writeText(this.filePath(), `1\n${newName}\n${current.password}\n`);
      return new LoginState(1, newName, current.password);
    }
    Jsonl.writeText(this.filePath(), `1\n${newName}\n`);
    return new LoginState(1, newName, '');
  }

  /** 退出登录 / 注销账号：写 0 并删除记录的账号密码 */
  markLoggedOut(): LoginState {
    Jsonl.writeText(this.filePath(), '0\n');
    return new LoginState(0, '', '');
  }
}

export const loginStateStore: LoginStateStore = new LoginStateStore();
