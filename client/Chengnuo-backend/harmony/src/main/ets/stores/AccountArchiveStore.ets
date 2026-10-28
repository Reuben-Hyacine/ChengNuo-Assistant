import { JsonRec, Jsonl } from '../Jsonl';

/**
 * account-archive.txt：客户端账号档案（累计登记，永不删除清空）。
 * 记录在这个客户端上使用过的账号名与密码（登录/注册成功即登记；空密码不覆盖已记录的密码），
 * 并绑定该账号名下「自己创建的公开卡片组」快照（按组名合并、updatedAt 较新者胜，累计不删除）。
 * 连接远程服务器时照旧使用服务器账号表认证，本档案不参与认证；
 * 连接本地服务器时：档案内已用过的账号登录即自动在本地服务器注册，并部署其绑定的公开卡片组
 * （好友关系等其他账号的信息不上传；昵称即账号名，随注册直接沿用）。
 */
export class AccountArchiveStore {
  private cache: Record<string, Object>[] = [];
  private loaded: boolean = false;

  private filePath(): string {
    return Jsonl.dataFilePath('account-archive.txt');
  }

  private normalizeRecord(parsed: Object | null): Record<string, Object> | null {
    const rec: Record<string, Object> | null = JsonRec.toRecord(parsed);
    if (rec === null) {
      return null;
    }
    const account: string = JsonRec.trimText(rec['account']);
    if (account.length === 0) {
      return null;
    }
    return {
      'account': account,
      'password': JsonRec.text(rec['password']),
      'groups': JsonRec.arr(rec['groups']) ?? [],
      'updatedAt': JsonRec.strOrNull(rec['updatedAt']) ?? JsonRec.isoNow()
    };
  }

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    const records: Object[] = Jsonl.readJsonl(this.filePath());
    this.cache = [];
    for (let i = 0; i < records.length; i++) {
      const rec: Record<string, Object> | null = this.normalizeRecord(records[i]);
      if (rec !== null && this.findRecord(JsonRec.text(rec['account'])) === null) {
        this.cache.push(rec);
      }
    }
    this.loaded = true;
  }

  private persist(): void {
    Jsonl.writeJsonl(this.filePath(), this.cache);
  }

  private findRecord(account: string): Record<string, Object> | null {
    for (let i = 0; i < this.cache.length; i++) {
      if (JsonRec.text(this.cache[i]['account']) === account) {
        return this.cache[i];
      }
    }
    return null;
  }

  /** 该账号名是否已在本客户端使用过（本地服务器登录时的自动注册门槛） */
  isKnownAccount(account: string): boolean {
    this.ensureLoaded();
    const name: string = account.trim();
    if (name.length === 0) {
      return false;
    }
    return this.findRecord(name) !== null;
  }

  /** 登记账号（upsert）：空密码不覆盖已记录的密码；已绑定的公开卡片组保持不变 */
  recordAccount(account: string, password: string): void {
    this.ensureLoaded();
    const name: string = account.trim();
    if (name.length === 0) {
      return;
    }
    const existing: Record<string, Object> | null = this.findRecord(name);
    if (existing === null) {
      this.cache.push({
        'account': name,
        'password': password,
        'groups': [],
        'updatedAt': JsonRec.isoNow()
      });
      this.persist();
      return;
    }
    if (password.length > 0 && JsonRec.text(existing['password']) !== password) {
      existing['password'] = password;
      existing['updatedAt'] = JsonRec.isoNow();
      this.persist();
    }
  }

  /** 设置密码（83）成功后更新档案密码（始终覆盖；账号未登记时一并登记） */
  recordPassword(account: string, password: string): void {
    this.ensureLoaded();
    const name: string = account.trim();
    if (name.length === 0 || password.length === 0) {
      return;
    }
    const existing: Record<string, Object> | null = this.findRecord(name);
    if (existing === null) {
      this.recordAccount(name, password);
      return;
    }
    existing['password'] = password;
    existing['updatedAt'] = JsonRec.isoNow();
    this.persist();
  }

  /** 绑定该账号的公开卡片组快照：按组名合并、updatedAt 较新者胜，累计不删除 */
  recordGroups(account: string, groups: Object[]): void {
    this.ensureLoaded();
    const name: string = account.trim();
    if (name.length === 0) {
      return;
    }
    let existing: Record<string, Object> | null = this.findRecord(name);
    if (existing === null) {
      const rec: Record<string, Object> = {
        'account': name,
        'password': '',
        'groups': [],
        'updatedAt': JsonRec.isoNow()
      };
      this.cache.push(rec);
      existing = rec;
    }
    existing['groups'] = this.mergeGroups(JsonRec.arr(existing['groups']) ?? [], groups);
    existing['updatedAt'] = JsonRec.isoNow();
    this.persist();
  }

  /** 组名相同的以较新快照为准，其余原样保留（档案累计不删） */
  private mergeGroups(archived: Object[], fresh: Object[]): Object[] {
    const out: Object[] = archived.slice();
    for (let i = 0; i < fresh.length; i++) {
      const rec: Record<string, Object> | null = JsonRec.toRecord(fresh[i]);
      if (rec === null) {
        continue;
      }
      const name: string = JsonRec.trimText(rec['name']);
      if (name.length === 0) {
        continue;
      }
      const freshAt: string = JsonRec.text(rec['updatedAt']);
      let hit: number = -1;
      for (let k = 0; k < out.length; k++) {
        const kept: Record<string, Object> | null = JsonRec.toRecord(out[k]);
        if (kept !== null && JsonRec.trimText(kept['name']) === name) {
          hit = k;
          break;
        }
      }
      if (hit < 0) {
        out.push(JsonRec.copyRecord(rec));
        continue;
      }
      const keptRec: Record<string, Object> | null = JsonRec.toRecord(out[hit]);
      if (keptRec !== null && JsonRec.text(keptRec['updatedAt']) <= freshAt) {
        out[hit] = JsonRec.copyRecord(rec);
      }
    }
    return out;
  }

  /** 该账号绑定的公开卡片组（本地服务器登录部署用） */
  groupsOf(account: string): Object[] {
    this.ensureLoaded();
    const name: string = account.trim();
    if (name.length === 0) {
      return [];
    }
    const existing: Record<string, Object> | null = this.findRecord(name);
    if (existing === null) {
      return [];
    }
    return JsonRec.arr(existing['groups']) ?? [];
  }

  /** 改名（82）：档案账号同步换名（密码与组绑定随行；新名字已有历史档案时合并保留一份） */
  renameAccountOf(account: string, newAccount: string): void {
    this.ensureLoaded();
    const oldName: string = account.trim();
    const newName: string = newAccount.trim();
    if (oldName.length === 0 || newName.length === 0 || oldName === newName) {
      return;
    }
    const existing: Record<string, Object> | null = this.findRecord(oldName);
    if (existing === null) {
      return;
    }
    const clash: Record<string, Object> | null = this.findRecord(newName);
    if (clash !== null) {
      const oldPassword: string = JsonRec.text(existing['password']);
      if (oldPassword.length > 0) {
        clash['password'] = oldPassword;
      }
      clash['groups'] = this.mergeGroups(JsonRec.arr(existing['groups']) ?? [],
        JsonRec.arr(clash['groups']) ?? []);
      clash['updatedAt'] = JsonRec.isoNow();
      const kept: Record<string, Object>[] = [];
      for (let i = 0; i < this.cache.length; i++) {
        if (this.cache[i] !== existing) {
          kept.push(this.cache[i]);
        }
      }
      this.cache = kept;
    } else {
      existing['account'] = newName;
      existing['updatedAt'] = JsonRec.isoNow();
    }
    this.persist();
  }
}

export const accountArchiveStore: AccountArchiveStore = new AccountArchiveStore();
