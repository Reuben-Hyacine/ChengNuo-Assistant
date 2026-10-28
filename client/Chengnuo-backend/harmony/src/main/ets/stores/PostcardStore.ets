import { JsonRec, Jsonl } from '../Jsonl';

/** 一张明信片（服务 66 生成后由客户端落库长期保存） */
export class PostcardRec {
  readonly id: number;
  readonly account: string | null;
  readonly userId: number | null;
  readonly groupId: number | null;
  readonly groupName: string | null;
  readonly cardIndex: number | null;
  readonly event: string | null;
  readonly time: string | null;
  readonly text: string;
  readonly model: string | null;
  readonly createdAt: string;

  constructor(id: number, account: string | null, userId: number | null, groupId: number | null,
    groupName: string | null, cardIndex: number | null, event: string | null, time: string | null,
    text: string, model: string | null, createdAt: string) {
    this.id = id;
    this.account = account;
    this.userId = userId;
    this.groupId = groupId;
    this.groupName = groupName;
    this.cardIndex = cardIndex;
    this.event = event;
    this.time = time;
    this.text = text;
    this.model = model;
    this.createdAt = createdAt;
  }

  copy(): PostcardRec {
    return new PostcardRec(this.id, this.account, this.userId, this.groupId, this.groupName, this.cardIndex,
      this.event, this.time, this.text, this.model, this.createdAt);
  }

  toRecord(): Record<string, Object> {
    const rec: Record<string, Object> = { 'id': this.id, 'text': this.text, 'createdAt': this.createdAt };
    JsonRec.put(rec, 'account', this.account);
    JsonRec.put(rec, 'userId', this.userId);
    JsonRec.put(rec, 'groupId', this.groupId);
    JsonRec.put(rec, 'groupName', this.groupName);
    JsonRec.put(rec, 'cardIndex', this.cardIndex);
    JsonRec.put(rec, 'event', this.event);
    JsonRec.put(rec, 'time', this.time);
    JsonRec.put(rec, 'model', this.model);
    return rec;
  }
}

/** 删除结果 */
export class RemoveResult {
  readonly id: number | null;
  readonly removed: boolean;

  constructor(id: number | null, removed: boolean) {
    this.id = id;
    this.removed = removed;
  }
}

/** postcards.txt：明信片（客户端长期保存；文件为 UTF-8 JSONL，可手动编辑） */
export class PostcardStore {
  private cache: PostcardRec[] = [];
  private nextId: number = 1;
  private loaded: boolean = false;

  private filePath(): string {
    return Jsonl.dataFilePath('postcards.txt');
  }

  private normalize(parsed: Object | null): PostcardRec | null {
    const rec: Record<string, Object> | null = JsonRec.toRecord(parsed);
    if (rec === null) {
      return null;
    }
    const id: number = JsonRec.rawNum(rec['id']);
    const text: string = JsonRec.trimText(rec['text']);
    if (!Number.isInteger(id) || id < 1 || text.length === 0) {
      return null;
    }
    const account: string = JsonRec.trimText(rec['account']);
    const groupName: string = JsonRec.trimText(rec['groupName']);
    const event: string = JsonRec.trimText(rec['event']);
    const time: string = JsonRec.trimText(rec['time']);
    const model: string = JsonRec.trimText(rec['model']);
    return new PostcardRec(
      id,
      account.length > 0 ? account : null,
      JsonRec.coercedInt(rec['userId']),
      JsonRec.coercedInt(rec['groupId']),
      groupName.length > 0 ? groupName : null,
      JsonRec.coercedInt(rec['cardIndex']),
      event.length > 0 ? event : null,
      time.length > 0 ? time : null,
      text,
      model.length > 0 ? model : null,
      JsonRec.strOrNull(rec['createdAt']) ?? JsonRec.isoNow()
    );
  }

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    const records: Object[] = Jsonl.readJsonl(this.filePath());
    this.cache = [];
    this.nextId = 1;
    for (let i = 0; i < records.length; i++) {
      const rec: PostcardRec | null = this.normalize(records[i]);
      if (rec === null) {
        continue;
      }
      this.cache.push(rec);
      if (rec.id >= this.nextId) {
        this.nextId = rec.id + 1;
      }
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

  /** 追加一张明信片：服务 66 生成成功后由客户端写入，返回落库后的完整记录 */
  appendPostcard(account: Object | null, userId: Object | null, groupId: Object | null, groupName: Object | null,
    cardIndex: Object | null, event: Object | null, time: Object | null, text: Object | null,
    model: Object | null, createdAt: Object | null): PostcardRec | null {
    this.ensureLoaded();
    const body: string = JsonRec.trimText(text);
    if (body.length === 0) {
      return null;
    }
    const accountName: string = JsonRec.trimText(account);
    const groupNameText: string = JsonRec.trimText(groupName);
    const eventText: string = JsonRec.trimText(event);
    const timeText: string = JsonRec.trimText(time);
    const modelText: string = JsonRec.trimText(model);
    const createdAtText: string = JsonRec.text(createdAt);
    const rec: PostcardRec = new PostcardRec(
      this.nextId++,
      accountName.length > 0 ? accountName : null,
      JsonRec.intOrNull(userId),
      JsonRec.intOrNull(groupId),
      groupNameText.length > 0 ? groupNameText : null,
      JsonRec.intOrNull(cardIndex),
      eventText.length > 0 ? eventText : null,
      timeText.length > 0 ? timeText : null,
      body,
      modelText.length > 0 ? modelText : null,
      createdAtText.length > 0 ? createdAtText : JsonRec.isoNow()
    );
    this.cache.push(rec);
    this.persist();
    return rec.copy();
  }

  /** 某账号的全部明信片：最新的在前 */
  listForAccount(account: Object | null): PostcardRec[] {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    if (name.length === 0) {
      return [];
    }
    const mine: PostcardRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].account === name) {
        mine.push(this.cache[i]);
      }
    }
    const out: PostcardRec[] = [];
    for (let i = mine.length - 1; i >= 0; i--) {
      out.push(mine[i].copy());
    }
    return out;
  }

  /** 删除某账号的一张明信片（「明信片」库的删除按钮） */
  removePostcard(account: Object | null, id: Object | null): RemoveResult {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    const pid: number = JsonRec.rawNum(id);
    if (name.length === 0 || !Number.isInteger(pid) || pid < 1) {
      return new RemoveResult(Number.isInteger(pid) ? pid : null, false);
    }
    const before: number = this.cache.length;
    const kept: PostcardRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      const rec: PostcardRec = this.cache[i];
      if (!(rec.account === name && rec.id === pid)) {
        kept.push(rec);
      }
    }
    this.cache = kept;
    const removed: boolean = before !== this.cache.length;
    if (removed) {
      this.persist();
    }
    return new RemoveResult(pid, removed);
  }

  /** 注销账号：清除该账号在本客户端的明信片 */
  clearByAccount(account: Object | null): number {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    if (name.length === 0) {
      return 0;
    }
    const before: number = this.cache.length;
    const kept: PostcardRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].account !== name) {
        kept.push(this.cache[i]);
      }
    }
    this.cache = kept;
    const removed: number = before - this.cache.length;
    if (removed > 0) {
      this.persist();
    }
    return removed;
  }

  /** 改名（82）：该账号的明信片记录同步换名 */
  renameAccountOf(account: Object | null, newAccount: Object | null): number {
    this.ensureLoaded();
    const oldName: string = JsonRec.trimText(account);
    const newName: string = JsonRec.trimText(newAccount);
    if (oldName.length === 0 || newName.length === 0 || oldName === newName) {
      return 0;
    }
    let renamed: number = 0;
    for (let i = 0; i < this.cache.length; i++) {
      const r: PostcardRec = this.cache[i];
      if (r.account === oldName) {
        this.cache[i] = new PostcardRec(r.id, newName, r.userId, r.groupId, r.groupName, r.cardIndex,
          r.event, r.time, r.text, r.model, r.createdAt);
        renamed += 1;
      }
    }
    if (renamed > 0) {
      this.persist();
    }
    return renamed;
  }
}

export const postcardStore: PostcardStore = new PostcardStore();
