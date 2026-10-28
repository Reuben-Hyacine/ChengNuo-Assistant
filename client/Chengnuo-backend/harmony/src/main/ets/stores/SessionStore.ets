import { JsonRec, Jsonl } from '../Jsonl';

/** 登录会话：token -> 账号/用户编号（payload 不带账号，本地服务按此反解身份） */
export class SessionRec {
  readonly token: string;
  readonly account: string;
  readonly userId: number | null;
  readonly loginAt: string | null;

  constructor(token: string, account: string, userId: number | null, loginAt: string | null) {
    this.token = token;
    this.account = account;
    this.userId = userId;
    this.loginAt = loginAt;
  }

  copy(): SessionRec {
    return new SessionRec(this.token, this.account, this.userId, this.loginAt);
  }

  toRecord(): Record<string, Object> {
    const rec: Record<string, Object> = { 'token': this.token, 'account': this.account };
    JsonRec.put(rec, 'userId', this.userId);
    JsonRec.put(rec, 'loginAt', this.loginAt);
    return rec;
  }
}

/** sessions.txt：登录会话映射（token -> {token, account, userId, loginAt}） */
export class SessionStore {
  private cache: SessionRec[] = [];
  private loaded: boolean = false;

  private filePath(): string {
    return Jsonl.dataFilePath('sessions.txt');
  }

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    const records: Object[] = Jsonl.readJsonl(this.filePath());
    this.cache = [];
    for (let i = 0; i < records.length; i++) {
      const rec: Record<string, Object> | null = JsonRec.toRecord(records[i]);
      if (rec === null) {
        continue;
      }
      const token: string = JsonRec.trimText(rec['token']);
      const account: string = JsonRec.trimText(rec['account']);
      if (token.length === 0 || account.length === 0) {
        continue;
      }
      this.cache.push(new SessionRec(token, account, JsonRec.intOrNull(rec['userId']), JsonRec.strOrNull(rec['loginAt'])));
    }
    this.loaded = true;
  }

  private persist(): void {
    const out: Object[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      out.push(this.cache[i].toRecord());
    }
    Jsonl.writeJsonl(this.filePath(), out);
  }

  /** 登录成功：记下 token 与账号；同一账号只保留最新一次登录的 token */
  rememberLogin(token: Object | null, account: Object | null, userId: Object | null): SessionRec | null {
    this.ensureLoaded();
    const key: string = JsonRec.trimText(token);
    const name: string = JsonRec.trimText(account);
    if (key.length === 0 || name.length === 0) {
      return null;
    }
    const kept: SessionRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      const rec: SessionRec = this.cache[i];
      if (rec.token !== key && rec.account !== name) {
        kept.push(rec);
      }
    }
    this.cache = kept;
    const rec: SessionRec = new SessionRec(key, name, JsonRec.intOrNull(userId), JsonRec.isoNow());
    this.cache.push(rec);
    this.persist();
    return rec.copy();
  }

  /** 退出登录 / 注销：按 token 或账号移除映射 */
  forgetSession(token: Object | null, account: Object | null): number {
    this.ensureLoaded();
    const key: string = JsonRec.trimText(token);
    const name: string = JsonRec.trimText(account);
    let removed: number = 0;
    const kept: SessionRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      const rec: SessionRec = this.cache[i];
      const hit: boolean = (key.length > 0 && rec.token === key) || (name.length > 0 && rec.account === name);
      if (hit) {
        removed += 1;
      } else {
        kept.push(rec);
      }
    }
    if (removed > 0) {
      this.cache = kept;
      this.persist();
    }
    return removed;
  }

  /** 改名（82）：会话映射里该账号的记录同步换名（token 不变，只改 account 字段） */
  renameAccountOf(account: Object | null, newAccount: Object | null): number {
    this.ensureLoaded();
    const oldName: string = JsonRec.trimText(account);
    const newName: string = JsonRec.trimText(newAccount);
    if (oldName.length === 0 || newName.length === 0 || oldName === newName) {
      return 0;
    }
    let renamed: number = 0;
    for (let i = 0; i < this.cache.length; i++) {
      const rec: SessionRec = this.cache[i];
      if (rec.account === oldName) {
        this.cache[i] = new SessionRec(rec.token, newName, rec.userId, rec.loginAt);
        renamed += 1;
      }
    }
    if (renamed > 0) {
      this.persist();
    }
    return renamed;
  }

  /** 按 token 查会话（本地内存/文件，不发网络请求） */
  resolveSession(token: Object | null): SessionRec | null {
    this.ensureLoaded();
    const key: string = JsonRec.trimText(token);
    if (key.length === 0) {
      return null;
    }
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].token === key) {
        return this.cache[i].copy();
      }
    }
    return null;
  }
}

export const sessionStore: SessionStore = new SessionStore();
