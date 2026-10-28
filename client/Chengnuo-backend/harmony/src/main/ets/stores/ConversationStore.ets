import { JsonRec, Jsonl } from '../Jsonl';
import { AigcLabel } from '../AigcLabel';

/** 一条 AI 对话记录 */
export class ConvRec {
  readonly id: number;
  readonly account: string | null;
  readonly userId: number;
  readonly direction: string;
  readonly time: string;
  readonly content: string;
  /** AI 生成合成内容隐式标识（GB 45438-2025）：direction = 'out' 的 AI 回复携带，用户发言为空串 */
  readonly aigcLabel: string;

  constructor(id: number, account: string | null, userId: number, direction: string, time: string, content: string,
    aigcLabel: string = '') {
    this.id = id;
    this.account = account;
    this.userId = userId;
    this.direction = direction;
    this.time = time;
    this.content = content;
    this.aigcLabel = aigcLabel;
  }

  copy(): ConvRec {
    return new ConvRec(this.id, this.account, this.userId, this.direction, this.time, this.content, this.aigcLabel);
  }

  toRecord(): Record<string, Object> {
    const rec: Record<string, Object> =
      { 'id': this.id, 'userId': this.userId, 'direction': this.direction, 'time': this.time, 'content': this.content };
    JsonRec.put(rec, 'account', this.account);
    JsonRec.put(rec, 'aigc_label', this.aigcLabel.length > 0 ? this.aigcLabel : null);
    return rec;
  }
}

export const MAX_MESSAGES_PER_USER: number = 10;

/** conversations.txt：AI 对话记录（每账号只保留最近 MAX_MESSAGES_PER_USER 条） */
export class ConversationStore {
  private cache: ConvRec[] = [];
  private nextId: number = 1;
  private loaded: boolean = false;

  private filePath(): string {
    return Jsonl.dataFilePath('conversations.txt');
  }

  private normalize(parsed: Object | null): ConvRec | null {
    const rec: Record<string, Object> | null = JsonRec.toRecord(parsed);
    if (rec === null) {
      return null;
    }
    const id: number = JsonRec.rawNum(rec['id']);
    const userId: number = JsonRec.rawNum(rec['userId']);
    const directionRaw: Object | undefined = rec['direction'];
    const direction: string | null =
      directionRaw === 'in' ? 'in' : (directionRaw === 'out' ? 'out' : null);
    const content: string = JsonRec.trimText(rec['content']);
    if (!Number.isInteger(id) || id < 1 || !Number.isInteger(userId) || userId < 1 ||
      direction === null || content.length === 0) {
      return null;
    }
    const account: string = JsonRec.trimText(rec['account']);
    const time: string = JsonRec.strOrNull(rec['time']) ?? JsonRec.isoNow();
    // 隐式标识仅 AI 回复（direction = 'out'）携带；本版本前落库的旧记录无标识，不回填
    const aigcLabel: string = direction === 'out' ? JsonRec.trimText(rec['aigc_label']) : '';
    return new ConvRec(id, account.length > 0 ? account : null, userId, direction, time, content, aigcLabel);
  }

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    const records: Object[] = Jsonl.readJsonl(this.filePath());
    this.cache = [];
    this.nextId = 1;
    for (let i = 0; i < records.length; i++) {
      const rec: ConvRec | null = this.normalize(records[i]);
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

  private trimByUser(userId: number): void {
    const mine: ConvRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].userId === userId) {
        mine.push(this.cache[i]);
      }
    }
    if (mine.length <= MAX_MESSAGES_PER_USER) {
      return;
    }
    const keep: number[] = [];
    for (let i = mine.length - MAX_MESSAGES_PER_USER; i < mine.length; i++) {
      keep.push(mine[i].id);
    }
    const kept: ConvRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      const rec: ConvRec = this.cache[i];
      if (rec.userId !== userId || keep.indexOf(rec.id) >= 0) {
        kept.push(rec);
      }
    }
    this.cache = kept;
  }

  /** 追加一轮对话（用户消息 + AI 回复）：服务 0 转发成功后由客户端写入 */
  appendTurn(account: Object | null, userId: Object | null, userText: Object | null, replyText: Object | null): ConvRec[] {
    this.ensureLoaded();
    const userIdNum: number | null = JsonRec.intOrNull(userId);
    if (userIdNum === null || userIdNum < 1) {
      return [];
    }
    const time: string = JsonRec.isoNow();
    const accountName: string = JsonRec.text(account);
    const written: ConvRec[] = [];
    const inText: string = JsonRec.trimText(userText);
    if (inText.length > 0) {
      const rec: ConvRec =
        new ConvRec(this.nextId++, accountName.length > 0 ? accountName : null, userIdNum, 'in', time, inText, '');
      this.cache.push(rec);
      written.push(rec.copy());
    }
    const outText: string = JsonRec.trimText(replyText);
    if (outText.length > 0) {
      // AI 回复落库即附加生成合成内容隐式标识（GB 45438-2025）：内容编号 c-{id}，生成时间 = 落库时间
      const outId: number = this.nextId++;
      const rec: ConvRec =
        new ConvRec(outId, accountName.length > 0 ? accountName : null, userIdNum, 'out', time, outText,
          AigcLabel.build(`c-${outId}`, time));
      this.cache.push(rec);
      written.push(rec.copy());
    }
    this.trimByUser(userIdNum);
    if (written.length > 0) {
      this.persist();
    }
    return written;
  }

  /** 服务 39：最近十条对话，最新的在前（页面自行倒序展示） */
  listByUser(userId: Object | null): ConvRec[] {
    this.ensureLoaded();
    const userIdNum: number | null = JsonRec.intOrNull(userId);
    if (userIdNum === null || userIdNum < 1) {
      return [];
    }
    const mine: ConvRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].userId === userIdNum) {
        mine.push(this.cache[i]);
      }
    }
    const start: number = mine.length > MAX_MESSAGES_PER_USER ? mine.length - MAX_MESSAGES_PER_USER : 0;
    const out: ConvRec[] = [];
    for (let i = mine.length - 1; i >= start; i--) {
      out.push(mine[i].copy());
    }
    return out;
  }

  /** 服务 0 上送的历史：{direction, content} 列表，按时间正序（旧 -> 新） */
  historyFor(userId: Object | null): Record<string, Object>[] {
    this.ensureLoaded();
    const userIdNum: number | null = JsonRec.intOrNull(userId);
    if (userIdNum === null || userIdNum < 1) {
      return [];
    }
    const mine: ConvRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].userId === userIdNum) {
        mine.push(this.cache[i]);
      }
    }
    const start: number = mine.length > MAX_MESSAGES_PER_USER ? mine.length - MAX_MESSAGES_PER_USER : 0;
    const out: Record<string, Object>[] = [];
    for (let i = start; i < mine.length; i++) {
      out.push({ 'direction': mine[i].direction, 'content': mine[i].content });
    }
    return out;
  }

  /** 服务 8：清空某账号的 AI 对话记录 */
  clearByUser(userId: Object | null): number {
    this.ensureLoaded();
    const userIdNum: number | null = JsonRec.intOrNull(userId);
    if (userIdNum === null || userIdNum < 1) {
      return 0;
    }
    const before: number = this.cache.length;
    const kept: ConvRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].userId !== userIdNum) {
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

  /** 个性化服务关闭：清空本机全部账号的 AI 对话记录 */
  clearAll(): void {
    this.ensureLoaded();
    if (this.cache.length === 0) {
      return;
    }
    this.cache = [];
    this.persist();
  }

  /** 注销账号：清除该账号在本客户端的 AI 对话记录 */
  clearByAccount(account: Object | null): number {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    if (name.length === 0) {
      return 0;
    }
    const before: number = this.cache.length;
    const kept: ConvRec[] = [];
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

  /** 改名（82）：该账号的对话记录同步换名（userId 不变，仅 account 字段迁移） */
  renameAccountOf(account: Object | null, newAccount: Object | null): number {
    this.ensureLoaded();
    const oldName: string = JsonRec.trimText(account);
    const newName: string = JsonRec.trimText(newAccount);
    if (oldName.length === 0 || newName.length === 0 || oldName === newName) {
      return 0;
    }
    let renamed: number = 0;
    for (let i = 0; i < this.cache.length; i++) {
      const rec: ConvRec = this.cache[i];
      if (rec.account === oldName) {
        this.cache[i] = new ConvRec(rec.id, newName, rec.userId, rec.direction, rec.time, rec.content, rec.aigcLabel);
        renamed += 1;
      }
    }
    if (renamed > 0) {
      this.persist();
    }
    return renamed;
  }
}

export const conversationStore: ConversationStore = new ConversationStore();
