import { JsonRec, Jsonl } from '../Jsonl';

/** 好友名单条目（服务 16 返回的 raw 值透传，读取时再归一） */
export class FriendBrief {
  readonly account: Object;
  readonly userId: Object;

  constructor(account: Object, userId: Object) {
    this.account = account;
    this.userId = userId;
  }
}

/** 一条本地聊天消息（编号为客户端本地编号，读取时校验、写入前统一分配） */
export class ChatMsg {
  id: number | null;
  readonly fromAccount: string;
  readonly toAccount: string;
  readonly kind: string;
  readonly text: string;
  readonly cardIndex: number | null;
  readonly card: Record<string, Object> | null;
  readonly groupId: number | null;
  readonly group: Record<string, Object> | null;
  readonly createdAt: number;
  readAt: number | null;
  acceptedAt: number | null;

  constructor(id: number | null, fromAccount: string, toAccount: string, kind: string, text: string,
    cardIndex: number | null, card: Record<string, Object> | null, groupId: number | null,
    group: Record<string, Object> | null, createdAt: number, readAt: number | null, acceptedAt: number | null) {
    this.id = id;
    this.fromAccount = fromAccount;
    this.toAccount = toAccount;
    this.kind = kind;
    this.text = text;
    this.cardIndex = cardIndex;
    this.card = card;
    this.groupId = groupId;
    this.group = group;
    this.createdAt = createdAt;
    this.readAt = readAt;
    this.acceptedAt = acceptedAt;
  }

  copy(): ChatMsg {
    return new ChatMsg(this.id, this.fromAccount, this.toAccount, this.kind, this.text, this.cardIndex, this.card,
      this.groupId, this.group, this.createdAt, this.readAt, this.acceptedAt);
  }

  toRecord(): Record<string, Object> {
    const rec: Record<string, Object> =
      { 'fromAccount': this.fromAccount, 'toAccount': this.toAccount, 'kind': this.kind, 'text': this.text, 'createdAt': this.createdAt };
    JsonRec.put(rec, 'id', this.id);
    JsonRec.put(rec, 'cardIndex', this.cardIndex);
    JsonRec.put(rec, 'card', this.card);
    JsonRec.put(rec, 'groupId', this.groupId);
    JsonRec.put(rec, 'group', this.group);
    JsonRec.put(rec, 'readAt', this.readAt);
    JsonRec.put(rec, 'acceptedAt', this.acceptedAt);
    return rec;
  }
}

/** 合并服务器中转消息的结果计数 */
export class MergeResult {
  readonly added: number;
  readonly skipped: number;

  constructor(added: number, skipped: number) {
    this.added = added;
    this.skipped = skipped;
  }
}

/** 会话总览聚合条目（内部用） */
class ConvAgg {
  peer: string;
  userId: number;
  unread: number = 0;
  total: number = 0;
  lastAt: number | null = null;
  lastId: number = 0;
  lastFromMe: boolean | null = null;
  lastKind: string | null = null;
  lastSummary: string | null = null;

  constructor(peer: string, userId: number) {
    this.peer = peer;
    this.userId = userId;
  }
}

/** chats.txt：好友对话（本库是消息的唯一长期存放处；服务器只做短期中转、送达即删） */
export class ChatStore {
  private cache: ChatMsg[] = [];
  private nextId: number = 1;
  private loaded: boolean = false;

  private filePath(): string {
    return Jsonl.dataFilePath('chats.txt');
  }

  private textOf(value: Object | undefined | null, max: number): string {
    if (!JsonRec.isString(value)) {
      return '';
    }
    const t: string = (value as string).trim();
    return t.length > max ? t.substring(0, max) : t;
  }

  private normalizeKind(kind: Object | undefined): string {
    return kind === 'card' ? 'card' : (kind === 'group' ? 'group' : 'text');
  }

  private normalize(parsed: Object | null): ChatMsg | null {
    const rec: Record<string, Object> | null = JsonRec.toRecord(parsed);
    if (rec === null) {
      return null;
    }
    const fromAccount: string = JsonRec.trimText(rec['fromAccount']);
    const toAccount: string = JsonRec.trimText(rec['toAccount']);
    const createdAt: number = JsonRec.rawNum(rec['createdAt']);
    if (fromAccount.length === 0 || toAccount.length === 0 || !Number.isFinite(createdAt) || createdAt <= 0) {
      return null;
    }
    const id: number = JsonRec.rawNum(rec['id']);
    const readAt: number = JsonRec.rawNum(rec['readAt']);
    const acceptedAt: number = JsonRec.rawNum(rec['acceptedAt']);
    return new ChatMsg(
      Number.isInteger(id) && id >= 1 ? id : null,
      fromAccount,
      toAccount,
      this.normalizeKind(rec['kind']),
      this.textOf(rec['text'], 2000),
      JsonRec.posIntOrNull(rec['cardIndex']),
      JsonRec.obj(rec['card']),
      JsonRec.posIntOrNull(rec['groupId']),
      JsonRec.obj(rec['group']),
      createdAt,
      Number.isFinite(readAt) && readAt > 0 ? readAt : null,
      Number.isFinite(acceptedAt) && acceptedAt > 0 ? acceptedAt : null
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
      const msg: ChatMsg | null = this.normalize(records[i]);
      if (msg === null || msg.id === null) {
        continue;
      }
      this.cache.push(msg);
      if (msg.id >= this.nextId) {
        this.nextId = msg.id + 1;
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

  /** 内容指纹：中转消息不带可跨机器对齐的编号，按「收发双方 + 时间 + 类型 + 内容」去重 */
  private fingerprint(msg: ChatMsg): string {
    const cardIndexText: string = msg.cardIndex !== null ? `${msg.cardIndex}` : '';
    const groupIdText: string = msg.groupId !== null ? `${msg.groupId}` : '';
    return `${msg.fromAccount}\u0001${msg.toAccount}\u0001${msg.createdAt}\u0001${msg.kind}\u0001${msg.text}\u0001${cardIndexText}\u0001${groupIdText}`;
  }

  private summaryOf(msg: ChatMsg): string | null {
    if (msg.kind === 'card') {
      const c: Record<string, Object> = msg.card !== null ? msg.card : {};
      const purpose: Object = JsonRec.truthy(c['purpose']) ? c['purpose'] : '-';
      const event: Object = JsonRec.truthy(c['event']) ? c['event'] : '-';
      const time: Object = JsonRec.truthy(c['time']) ? c['time'] : '-';
      return `[卡片] ${purpose} / ${event} / ${time}`;
    }
    if (msg.kind === 'group') {
      const g: Record<string, Object> = msg.group !== null ? msg.group : {};
      const name: Object = JsonRec.truthy(g['name']) ? g['name'] : '-';
      const cardCount: Object = (g['cardCount'] !== undefined && g['cardCount'] !== null) ? g['cardCount'] : 0;
      return `[卡片组] ${name}（${cardCount} 张卡片）`;
    }
    return msg.text;
  }

  /** 写入一条本地消息（自己发出的或合并进来的），返回落库后的消息 */
  appendMessage(msg: Object | null): ChatMsg | null {
    this.ensureLoaded();
    const normalized: ChatMsg | null = this.normalize(msg);
    if (normalized === null) {
      return null;
    }
    normalized.id = this.nextId++;
    this.cache.push(normalized);
    this.persist();
    return normalized.copy();
  }

  /** 合并服务器中转发来的消息：按内容指纹去重，编号由客户端本地重新分配 */
  mergeIncoming(account: Object | null, messages: Object[] | null): MergeResult {
    this.ensureLoaded();
    const me: string = JsonRec.trimText(account);
    if (me.length === 0 || messages === null) {
      return new MergeResult(0, 0);
    }
    const known: string[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      known.push(this.fingerprint(this.cache[i]));
    }
    let added: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < messages.length; i++) {
      const incoming: ChatMsg | null = this.normalize(messages[i]);
      if (incoming === null || incoming.toAccount !== me) {
        skipped += 1;
        continue;
      }
      const key: string = this.fingerprint(incoming);
      if (known.indexOf(key) >= 0) {
        skipped += 1;
        continue;
      }
      incoming.id = this.nextId++;
      this.cache.push(incoming);
      known.push(key);
      added += 1;
    }
    if (added > 0) {
      this.persist();
    }
    return new MergeResult(added, skipped);
  }

  /** 与某好友的完整聊天记录（按时间正序），并把对方发来的未读标记为已读 */
  listThread(account: Object | null, peer: Object | null): ChatMsg[] {
    this.ensureLoaded();
    const me: string = JsonRec.trimText(account);
    const other: string = JsonRec.trimText(peer);
    if (me.length === 0 || other.length === 0) {
      return [];
    }
    const now: number = Date.now();
    let marked: number = 0;
    for (let i = 0; i < this.cache.length; i++) {
      const m: ChatMsg = this.cache[i];
      const between: boolean =
        (m.fromAccount === me && m.toAccount === other) || (m.fromAccount === other && m.toAccount === me);
      if (between && m.toAccount === me && m.readAt === null) {
        m.readAt = now;
        marked += 1;
      }
    }
    if (marked > 0) {
      this.persist();
    }
    const thread: ChatMsg[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      const m: ChatMsg = this.cache[i];
      if ((m.fromAccount === me && m.toAccount === other) || (m.fromAccount === other && m.toAccount === me)) {
        thread.push(m);
      }
    }
    thread.sort((a: ChatMsg, b: ChatMsg): number => {
      if (a.createdAt !== b.createdAt) {
        return a.createdAt - b.createdAt;
      }
      return (a.id ?? 0) - (b.id ?? 0);
    });
    const out: ChatMsg[] = [];
    for (let i = 0; i < thread.length; i++) {
      out.push(thread[i].copy());
    }
    return out;
  }

  /** 会话总览：全部好友都在列（没聊过的也在），附最后一条消息摘要与未读数 */
  listConversations(account: Object | null, friends: FriendBrief[] | null): Record<string, Object> {
    this.ensureLoaded();
    const me: string = JsonRec.trimText(account);
    if (me.length === 0) {
      return { 'account': '', 'total': 0, 'unread': 0, 'conversations': [] as Object[] };
    }
    const peers: string[] = [];
    const byPeer: ConvAgg[] = [];
    const list: FriendBrief[] = friends !== null ? friends : [];
    for (let i = 0; i < list.length; i++) {
      const f: FriendBrief = list[i];
      const name: string = JsonRec.trimText(f.account);
      if (name.length === 0) {
        continue;
      }
      const existing: number = peers.indexOf(name);
      if (existing >= 0) {
        byPeer[existing] = new ConvAgg(name, JsonRec.intOrNull(f.userId) ?? 0);
        continue;
      }
      peers.push(name);
      byPeer.push(new ConvAgg(name, JsonRec.intOrNull(f.userId) ?? 0));
    }
    for (let i = 0; i < this.cache.length; i++) {
      const m: ChatMsg = this.cache[i];
      if (m.fromAccount !== me && m.toAccount !== me) {
        continue;
      }
      const peer: string = m.fromAccount === me ? m.toAccount : m.fromAccount;
      let idx: number = peers.indexOf(peer);
      if (idx < 0) {
        peers.push(peer);
        byPeer.push(new ConvAgg(peer, 0));
        idx = byPeer.length - 1;
      }
      const conv: ConvAgg = byPeer[idx];
      conv.total += 1;
      if (m.toAccount === me && m.readAt === null) {
        conv.unread += 1;
      }
      const mId: number = m.id ?? 0;
      if (conv.lastAt === null || m.createdAt > conv.lastAt || (m.createdAt === conv.lastAt && mId > conv.lastId)) {
        conv.lastAt = m.createdAt;
        conv.lastId = mId;
        conv.lastFromMe = m.fromAccount === me;
        conv.lastKind = m.kind;
        conv.lastSummary = this.summaryOf(m);
      }
    }
    byPeer.sort((a: ConvAgg, b: ConvAgg): number => {
      const av: number = a.lastAt ?? 0;
      const bv: number = b.lastAt ?? 0;
      if (av !== bv) {
        return bv - av;
      }
      return a.peer < b.peer ? -1 : (a.peer > b.peer ? 1 : 0);
    });
    const conversations: Record<string, Object>[] = [];
    let unread: number = 0;
    for (let i = 0; i < byPeer.length; i++) {
      const c: ConvAgg = byPeer[i];
      unread += c.unread;
      const rec: Record<string, Object> =
        { 'peer': c.peer, 'userId': c.userId, 'unread': c.unread, 'total': c.total, 'lastAt': c.lastAt ?? 0 };
      JsonRec.put(rec, 'lastFromMe', c.lastFromMe);
      JsonRec.put(rec, 'lastKind', c.lastKind);
      JsonRec.put(rec, 'lastSummary', c.lastSummary);
      conversations.push(rec);
    }
    const result: Record<string, Object> = { 'account': me, 'total': byPeer.length, 'unread': unread };
    result['conversations'] = conversations;
    return result;
  }

  /** 取一条本地消息（供「接受卡片/卡片组邀请」定位使用） */
  getMessage(account: Object | null, id: Object | null): ChatMsg | null {
    this.ensureLoaded();
    const me: string = JsonRec.trimText(account);
    const idNum: number | null = JsonRec.intOrNull(id);
    if (me.length === 0 || idNum === null) {
      return null;
    }
    for (let i = 0; i < this.cache.length; i++) {
      const m: ChatMsg = this.cache[i];
      if (m.id === idNum && (m.fromAccount === me || m.toAccount === me)) {
        return m.copy();
      }
    }
    return null;
  }

  /** 标记一条邀请消息已被接受 */
  markAccepted(account: Object | null, id: Object | null): ChatMsg | null {
    this.ensureLoaded();
    const me: string = JsonRec.trimText(account);
    const idNum: number | null = JsonRec.intOrNull(id);
    if (me.length === 0 || idNum === null) {
      return null;
    }
    for (let i = 0; i < this.cache.length; i++) {
      const m: ChatMsg = this.cache[i];
      if (m.id === idNum && m.toAccount === me) {
        if (m.acceptedAt !== null) {
          return null;
        }
        m.acceptedAt = Date.now();
        this.persist();
        return m.copy();
      }
    }
    return null;
  }

  /** 注销账号：清除该账号在本客户端的全部聊天记录 */
  clearByAccount(account: Object | null): number {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    if (name.length === 0) {
      return 0;
    }
    const before: number = this.cache.length;
    const kept: ChatMsg[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      const m: ChatMsg = this.cache[i];
      if (m.fromAccount !== name && m.toAccount !== name) {
        kept.push(m);
      }
    }
    this.cache = kept;
    const removed: number = before - this.cache.length;
    if (removed > 0) {
      this.persist();
    }
    return removed;
  }

  /** 改名（82）：聊天收发双方与嵌套卡片/卡片组快照里的账号字段同步更新（与服务器 renameChatsOf 同构） */
  renameAccountOf(account: Object | null, newAccount: Object | null): number {
    this.ensureLoaded();
    const oldName: string = JsonRec.trimText(account);
    const newName: string = JsonRec.trimText(newAccount);
    if (oldName.length === 0 || newName.length === 0 || oldName === newName) {
      return 0;
    }
    let changed: number = 0;
    for (let i = 0; i < this.cache.length; i++) {
      const m: ChatMsg = this.cache[i];
      let touched: boolean = false;
      let fromAccount: string = m.fromAccount;
      let toAccount: string = m.toAccount;
      if (fromAccount === oldName) {
        fromAccount = newName;
        touched = true;
      }
      if (toAccount === oldName) {
        toAccount = newName;
        touched = true;
      }
      const card: Record<string, Object> | null = m.card;
      if (card !== null) {
        const initiator: Object | undefined = card['initiator'];
        if (JsonRec.isString(initiator) && (initiator as string) === oldName) {
          card['initiator'] = newName;
          touched = true;
        }
        const participant: string | null = JsonRec.renameInParticipants(card['participant'], oldName, newName);
        if (participant !== null) {
          card['participant'] = participant;
          touched = true;
        }
      }
      const group: Record<string, Object> | null = m.group;
      if (group !== null) {
        const owner: Object | undefined = group['owner'];
        if (JsonRec.isString(owner) && (owner as string) === oldName) {
          group['owner'] = newName;
          touched = true;
        }
      }
      if (touched) {
        this.cache[i] = new ChatMsg(m.id, fromAccount, toAccount, m.kind, m.text, m.cardIndex, card,
          m.groupId, group, m.createdAt, m.readAt, m.acceptedAt);
        changed += 1;
      }
    }
    if (changed > 0) {
      this.persist();
    }
    return changed;
  }
}

export const chatStore: ChatStore = new ChatStore();
