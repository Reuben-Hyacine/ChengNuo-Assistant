import { fileIo } from '@kit.CoreFileKit';
import { JsonRec, Jsonl } from '../Jsonl';

/** 一个私人卡片组副本（与服务器双端存储，登录时按 updatedAt 双向合并） */
export class PrivateGroupRec {
  readonly id: number | null;
  readonly account: string;
  readonly name: string;
  readonly library: string;
  readonly member: string | null;
  cards: Object[];
  readonly createdAt: string;
  readonly updatedAt: string;

  constructor(id: number | null, account: string, name: string, library: string, member: string | null,
    cards: Object[], createdAt: string, updatedAt: string) {
    this.id = id;
    this.account = account;
    this.name = name;
    this.library = library;
    this.member = member;
    this.cards = cards;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
  }

  copy(): PrivateGroupRec {
    return new PrivateGroupRec(this.id, this.account, this.name, this.library, this.member, this.cards,
      this.createdAt, this.updatedAt);
  }

  toRecord(): Record<string, Object> {
    const rec: Record<string, Object> =
      { 'account': this.account, 'name': this.name, 'library': this.library, 'cards': this.cards, 'createdAt': this.createdAt, 'updatedAt': this.updatedAt };
    JsonRec.put(rec, 'id', this.id);
    JsonRec.put(rec, 'member', this.member);
    return rec;
  }
}

/**
 * private-groups.txt：私人卡片组及卡片的客户端副本。
 * 断网时可直接手动编辑本文件（每行一个卡片组的 JSON），联网登录后即同步到服务器。
 */
export class PrivateGroupStore {
  private cache: PrivateGroupRec[] = [];
  private loaded: boolean = false;
  private stamp: string | null = null;

  private filePath(): string {
    return Jsonl.dataFilePath('private-groups.txt');
  }

  /** mtime/size 复合戳：识别「客户端运行期间被手动编辑」，保证手改内容能被上传 */
  private fileStamp(): string | null {
    try {
      const stat: fileIo.Stat = fileIo.statSync(this.filePath());
      return `${stat.mtime}/${stat.size}`;
    } catch (e) {
      return null;
    }
  }

  private normalizeGroup(parsed: Object | null): PrivateGroupRec | null {
    const rec: Record<string, Object> | null = JsonRec.toRecord(parsed);
    if (rec === null) {
      return null;
    }
    const account: string = JsonRec.trimText(rec['account']);
    const name: string = JsonRec.trimText(rec['name']);
    if (account.length === 0 || name.length === 0) {
      return null;
    }
    const id: number = JsonRec.rawNum(rec['id']);
    const now: string = JsonRec.isoNow();
    return new PrivateGroupRec(
      Number.isInteger(id) && id >= 1 ? id : null,
      account,
      name,
      'private',
      JsonRec.strOrNull(rec['member']),
      JsonRec.arr(rec['cards']) ?? [],
      JsonRec.strOrNull(rec['createdAt']) ?? now,
      JsonRec.strOrNull(rec['updatedAt']) ?? now
    );
  }

  private ensureLoaded(): void {
    const current: string | null = this.fileStamp();
    if (this.loaded && current === this.stamp) {
      return;
    }
    const records: Object[] = Jsonl.readJsonl(this.filePath());
    this.cache = [];
    for (let i = 0; i < records.length; i++) {
      const g: PrivateGroupRec | null = this.normalizeGroup(records[i]);
      if (g !== null) {
        this.cache.push(g);
      }
    }
    this.loaded = true;
    this.stamp = this.fileStamp();
  }

  private persist(): void {
    const out: Object[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      out.push(this.cache[i].toRecord());
    }
    Jsonl.writeJsonl(this.filePath(), out);
    this.stamp = this.fileStamp();
  }

  /** 某账号的私人卡片组副本（完整内部结构，含组内卡片） */
  listForAccount(account: Object | null): PrivateGroupRec[] {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    if (name.length === 0) {
      return [];
    }
    const out: PrivateGroupRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].account === name) {
        out.push(this.cache[i].copy());
      }
    }
    return out;
  }

  /** 用服务器返回的私人卡片组覆盖本账号的副本（其他账号的记录保留） */
  replaceForAccount(account: Object | null, groups: Object[] | null): Record<string, Object> {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    if (name.length === 0) {
      return { 'account': name, 'total': 0 };
    }
    const incoming: PrivateGroupRec[] = [];
    const rawList: Object[] = groups !== null ? groups : [];
    for (let i = 0; i < rawList.length; i++) {
      const g: PrivateGroupRec | null = this.normalizeGroup(rawList[i]);
      if (g !== null && g.account === name) {
        incoming.push(g);
      }
    }
    const kept: PrivateGroupRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].account !== name) {
        kept.push(this.cache[i]);
      }
    }
    this.cache = kept.concat(incoming);
    this.persist();
    return { 'account': name, 'total': incoming.length };
  }

  /** 删除某账号的一个私人卡片组副本（38 双端删除、55 删组、50 转公开时同步调用） */
  removeForAccount(account: Object | null, groupId: Object | null): Record<string, Object> {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    const id: number = JsonRec.rawNum(groupId);
    if (name.length === 0 || !Number.isInteger(id) || id < 1) {
      const invalid: Record<string, Object> = { 'removedCards': 0, 'removed': false };
      JsonRec.put(invalid, 'id', Number.isInteger(id) ? id : null);
      return invalid;
    }
    let hit: PrivateGroupRec | null = null;
    for (let i = 0; i < this.cache.length; i++) {
      const g: PrivateGroupRec = this.cache[i];
      if (g.account === name && g.id === id) {
        hit = g;
        break;
      }
    }
    if (hit === null) {
      return { 'id': id, 'removedCards': 0, 'removed': false };
    }
    const kept: PrivateGroupRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      const g: PrivateGroupRec = this.cache[i];
      if (!(g.account === name && g.id === id)) {
        kept.push(g);
      }
    }
    this.cache = kept;
    this.persist();
    const out: Record<string, Object> = { 'id': id, 'removedCards': hit.cards.length, 'removed': true };
    JsonRec.put(out, 'name', hit.name);
    return out;
  }

  /**
   * 删除某账号副本中一个私人卡片组内的一张卡（57 转发成功后同步调用；副本无此组或此卡时空操作）。
   * 不改副本的 updatedAt：让副本保持比服务器旧，63 合并时服务器版本照旧胜出。
   */
  removeCardForAccount(account: Object | null, groupId: Object | null, cardIndex: Object | null): Record<string, Object> {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    const gid: number = JsonRec.rawNum(groupId);
    const idx: number = JsonRec.rawNum(cardIndex);
    if (name.length === 0 || !Number.isInteger(gid) || gid < 1 || !Number.isInteger(idx) || idx < 1) {
      return { 'groupId': gid, 'cardIndex': idx, 'removed': false };
    }
    let hit: PrivateGroupRec | null = null;
    for (let i = 0; i < this.cache.length; i++) {
      const g: PrivateGroupRec = this.cache[i];
      if (g.account === name && g.id === gid) {
        hit = g;
        break;
      }
    }
    if (hit === null) {
      return { 'groupId': gid, 'cardIndex': idx, 'removed': false };
    }
    const kept: Object[] = [];
    for (let i = 0; i < hit.cards.length; i++) {
      const c: Object = hit.cards[i];
      const cRec: Record<string, Object> | null = JsonRec.toRecord(c);
      const cIdx: number = cRec !== null ? JsonRec.rawNum(cRec['index']) : Number.NaN;
      if (cIdx !== idx) {
        kept.push(c);
      }
    }
    const removed: boolean = kept.length < hit.cards.length;
    if (removed) {
      hit.cards = kept;
      this.persist();
    }
    return { 'groupId': gid, 'cardIndex': idx, 'removed': removed };
  }

  /** 注销账号：清除该账号的私人卡片组副本 */
  clearByAccount(account: Object | null): number {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    if (name.length === 0) {
      return 0;
    }
    const before: number = this.cache.length;
    const kept: PrivateGroupRec[] = [];
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

  /** 改名（82）：副本的账号、成员表与卡内发起人/参与人/完成权限同步换名（与服务器 renameGroupsAccountOf 同构）；
   *  updatedAt 不动：本地与服务器各自改好后内容一致，63 合并互不覆盖 */
  renameAccountOf(account: Object | null, newAccount: Object | null): number {
    this.ensureLoaded();
    const oldName: string = JsonRec.trimText(account);
    const newName: string = JsonRec.trimText(newAccount);
    if (oldName.length === 0 || newName.length === 0 || oldName === newName) {
      return 0;
    }
    let changed: number = 0;
    for (let i = 0; i < this.cache.length; i++) {
      const g: PrivateGroupRec = this.cache[i];
      let touched: boolean = false;
      let owner: string = g.account;
      if (owner === oldName) {
        owner = newName;
        touched = true;
      }
      let member: string | null = g.member;
      const memberRenamed: string | null = JsonRec.renameInParticipants(member, oldName, newName);
      if (memberRenamed !== null) {
        member = memberRenamed;
        touched = true;
      }
      for (let j = 0; j < g.cards.length; j++) {
        const card: Record<string, Object> | null = JsonRec.toRecord(g.cards[j]);
        if (card === null) {
          continue;
        }
        const content: Record<string, Object> | null = JsonRec.toRecord(card['content']);
        if (content !== null) {
          const initiator: Object | undefined = content['initiator'];
          if (JsonRec.isString(initiator) && (initiator as string) === oldName) {
            content['initiator'] = newName;
            touched = true;
          }
          const participant: string | null = JsonRec.renameInParticipants(content['participant'], oldName, newName);
          if (participant !== null) {
            content['participant'] = participant;
            touched = true;
          }
        }
        const completableBy: Object | undefined = card['completableBy'];
        if (JsonRec.isString(completableBy) && (completableBy as string) === oldName) {
          card['completableBy'] = newName;
          touched = true;
        }
        const completedBy: Object | undefined = card['completedBy'];
        if (JsonRec.isString(completedBy) && (completedBy as string) === oldName) {
          card['completedBy'] = newName;
          touched = true;
        }
      }
      if (touched) {
        this.cache[i] = new PrivateGroupRec(g.id, owner, g.name, g.library, member, g.cards, g.createdAt, g.updatedAt);
        changed += 1;
      }
    }
    if (changed > 0) {
      this.persist();
    }
    return changed;
  }
}

export const privateGroupStore: PrivateGroupStore = new PrivateGroupStore();
