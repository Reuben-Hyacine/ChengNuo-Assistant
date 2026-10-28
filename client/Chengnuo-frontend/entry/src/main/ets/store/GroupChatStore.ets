import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ServerMapper, GroupChatMessageInfo } from '../net/ServerModels';

/** 每个群聊本地保留的消息条数上限（超出裁掉最旧的） */
const MAX_PER_THREAD: number = 500;

/**
 * 群聊本地记录（端侧持久化，按账号隔离）：
 * - 服务器（100-102）只做短期中转分发（拉取即删、30 天过期），客户端本地文件是唯一长期真源
 * - 每个账号一个文件 filesDir/groupchats-<账号>.jsonl（每行一条消息，含自己发送的回执与拉取到的中转副本）
 * - 同一条消息的回执与各成员副本共用服务器消息 id，按 id 去重
 * - acceptedAt/applied 是纯本地字段（是否已接受过这张卡/是否已提交加入申请），服务器中转不感知
 */
export class GroupChatStore {
  private context: common.Context | null = null;
  /** 群已读水位缓存（账号 → groupId → 已读到的时间戳），未命中时从文件加载 */
  private readMarks: Map<string, Map<number, number>> = new Map<string, Map<number, number>>();

  /** EntryAbility 启动时注入上下文（filesDir 所在）；卡片桌面组件进程传 FormExtensionContext（同为 common.Context） */
  init(context: common.Context): void {
    this.context = context;
  }

  /** 某账号在某群的全部本地消息（按时间正序；文件缺失/损坏返回空列表，不阻断使用） */
  listThread(account: string, groupId: number): GroupChatMessageInfo[] {
    const list: GroupChatMessageInfo[] = [];
    const all: GroupChatMessageInfo[] = this.listOf(account);
    for (let i = 0; i < all.length; i++) {
      if (all[i].groupId === groupId) {
        list.push(all[i]);
      }
    }
    this.sortByTime(list);
    return list;
  }

  /** 删除某账号在某群的全部本地聊天记录（明信片被删/卡片被删时调用），返回是否实际删过并写盘成功 */
  deleteThread(account: string, groupId: number): boolean {
    if (this.context === null || account.length === 0 || groupId <= 0) {
      return false;
    }
    const all: GroupChatMessageInfo[] = this.listOf(account);
    const kept: GroupChatMessageInfo[] = [];
    let removed: boolean = false;
    for (let i = 0; i < all.length; i++) {
      if (all[i].groupId === groupId) {
        removed = true;
      } else {
        kept.push(all[i]);
      }
    }
    if (!removed || !this.writeAll(account, kept)) {
      return false;
    }
    this.touch();
    return true;
  }

  /** 发送成功后追加回执（与各接收成员拉到的中转副本共用同一 id，之后 mergeIncoming 按 id 自动去重） */
  appendOutgoing(account: string, msg: GroupChatMessageInfo): void {
    if (this.context === null || account.length === 0 || msg.id <= 0) {
      return;
    }
    const all: GroupChatMessageInfo[] = this.listOf(account);
    all.push(msg);
    if (this.writeAll(account, this.trimPerThread(all))) {
      this.touch();
    }
  }

  /** 合并一次拉取到的中转消息：按 id 去重、保留本地已有记录的 acceptedAt/applied、每群裁到上限。
   *  返回实际新增条数（0 = 没有新消息），有新增时自增 groupChatStamp */
  mergeIncoming(account: string, incoming: GroupChatMessageInfo[]): number {
    if (this.context === null || account.length === 0 || incoming.length === 0) {
      return 0;
    }
    const all: GroupChatMessageInfo[] = this.listOf(account);
    const seen: Set<number> = new Set<number>();
    for (let i = 0; i < all.length; i++) {
      seen.add(all[i].id);
    }
    let added: number = 0;
    for (let i = 0; i < incoming.length; i++) {
      const msg: GroupChatMessageInfo = incoming[i];
      if (msg.id <= 0 || seen.has(msg.id)) {
        continue;
      }
      seen.add(msg.id);
      all.push(msg);
      added++;
    }
    if (added === 0 || !this.writeAll(account, this.trimPerThread(all))) {
      return 0;
    }
    this.touch();
    return added;
  }

  /** 标记某条消息里的卡片已接受（acceptedAt = 当前时间戳），返回是否写入成功 */
  markAccepted(account: string, groupId: number, messageId: number): boolean {
    return this.markLocal(account, groupId, messageId, true);
  }

  /** 标记某条消息里的卡片已提交加入申请（applied = true），返回是否写入成功 */
  markApplied(account: string, groupId: number, messageId: number): boolean {
    return this.markLocal(account, groupId, messageId, false);
  }

  /** markAccepted/markApplied 共用实现（accept=true 置 acceptedAt，否则置 applied） */
  private markLocal(account: string, groupId: number, messageId: number, accept: boolean): boolean {
    if (this.context === null || account.length === 0 || messageId <= 0) {
      return false;
    }
    const all: GroupChatMessageInfo[] = this.listOf(account);
    let found: boolean = false;
    for (let i = 0; i < all.length; i++) {
      if (all[i].groupId === groupId && all[i].id === messageId) {
        found = true;
        if (accept) {
          all[i].acceptedAt = Date.now();
        } else {
          all[i].applied = true;
        }
        break;
      }
    }
    if (!found || !this.writeAll(account, all)) {
      return false;
    }
    this.touch();
    return true;
  }

  /** 某账号在某群的未读消息数：他人发的、晚于已读水位的消息（无水位记录 = 该群全部他人消息未读） */
  unreadOf(account: string, groupId: number): number {
    if (account.length === 0 || groupId <= 0) {
      return 0;
    }
    const marks: Map<number, number> = this.readMarksOf(account);
    const mark: number | undefined = marks.get(groupId);
    const thread: GroupChatMessageInfo[] = this.listThread(account, groupId);
    let unread: number = 0;
    for (let i = 0; i < thread.length; i++) {
      const msg: GroupChatMessageInfo = thread[i];
      if (msg.fromAccount !== account && (mark === undefined || msg.createdAt > mark)) {
        unread++;
      }
    }
    return unread;
  }

  /** 标记某账号在某群已读到当前（打开群聊页时调用）：水位取当前时间与线程最新消息的较大者 */
  markThreadRead(account: string, groupId: number): void {
    if (this.context === null || account.length === 0 || groupId <= 0) {
      return;
    }
    const marks: Map<number, number> = this.readMarksOf(account);
    const thread: GroupChatMessageInfo[] = this.listThread(account, groupId);
    let watermark: number = Date.now();
    const newest: GroupChatMessageInfo | undefined = thread.length > 0 ? thread[thread.length - 1] : undefined;
    if (newest !== undefined && newest.createdAt > watermark) {
      watermark = newest.createdAt;
    }
    const previous: number | undefined = marks.get(groupId);
    if (previous !== undefined && previous >= watermark) {
      return;
    }
    marks.set(groupId, watermark);
    this.writeReadMarks(account, marks);
    this.touch();
  }

  /** 读某账号的已读水位表（内存缓存优先，未命中时从文件加载；文件缺失/损坏按无水位处理） */
  private readMarksOf(account: string): Map<number, number> {
    const cached: Map<number, number> | undefined = this.readMarks.get(account);
    if (cached !== undefined) {
      return cached;
    }
    const marks: Map<number, number> = new Map<number, number>();
    if (this.context !== null && account.length > 0) {
      const path: string = this.readMarkFileOf(account);
      let exists: boolean = false;
      try {
        exists = fileIo.accessSync(path);
      } catch (e) {
        exists = false;
      }
      if (exists) {
        try {
          const lines: string[] = fileIo.readTextSync(path).split('\n');
          for (let i = 0; i < lines.length; i++) {
            const line: string = lines[i].trim();
            if (line.length === 0) {
              continue;
            }
            const rec: Record<string, Object> | null = ServerMapper.toRecord(JSON.parse(line));
            if (rec === null) {
              continue;
            }
            const gid: number = ServerMapper.num(rec, 'groupId', 0);
            const mark: number = ServerMapper.num(rec, 'mark', 0);
            if (gid > 0 && mark > 0) {
              marks.set(gid, mark);
            }
          }
        } catch (e) {
          return marks;
        }
      }
    }
    this.readMarks.set(account, marks);
    return marks;
  }

  /** 回写某账号的已读水位表（每行一条 groupId/mark） */
  private writeReadMarks(account: string, marks: Map<number, number>): void {
    const lines: string[] = [];
    marks.forEach((mark: number, gid: number) => {
      const line: Record<string, number> = { 'groupId': gid, 'mark': mark };
      lines.push(JSON.stringify(line));
    });
    try {
      const path: string = this.readMarkFileOf(account);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, lines.length > 0 ? lines.join('\n') + '\n' : '');
      fileIo.closeSync(file);
    } catch (e) {
    }
  }

  /** 已读水位文件：filesDir/groupchat-read-<账号>.jsonl */
  private readMarkFileOf(account: string): string {
    const safe: string = account.replace(/[^0-9A-Za-z_-]/g, '_');
    const dir: string = this.context !== null ? this.context.filesDir : '';
    return `${dir}/groupchat-read-${safe}.jsonl`;
  }

  /** 群聊数据变化 → 自增 groupChatStamp（群聊页等监听方收到后重取） */
  private touch(): void {
    const stamp: number = AppStorage.get<number>('groupChatStamp') ?? 0;
    AppStorage.setOrCreate('groupChatStamp', stamp + 1);
  }

  /** 读某账号的全部群聊消息（所有群混存一个文件，行内带 groupId） */
  private listOf(account: string): GroupChatMessageInfo[] {
    const list: GroupChatMessageInfo[] = [];
    if (this.context === null || account.length === 0) {
      return list;
    }
    const path: string = this.fileOf(account);
    // fs.accessSync 对不存在的路径会抛 13900002（而非返回 false），单独兜底
    let exists: boolean = false;
    try {
      exists = fileIo.accessSync(path);
    } catch (e) {
      exists = false;
    }
    if (!exists) {
      return list;
    }
    try {
      const content: string = fileIo.readTextSync(path);
      const lines: string[] = content.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const line: string = lines[i].trim();
        if (line.length === 0) {
          continue;
        }
        const rec: Record<string, Object> | null = ServerMapper.toRecord(JSON.parse(line));
        if (rec === null) {
          continue;
        }
        const msg: GroupChatMessageInfo = ServerMapper.toGroupChatMessage(rec);
        if (msg.id > 0 && msg.groupId > 0) {
          list.push(msg);
        }
      }
    } catch (e) {
      return [];
    }
    return list;
  }

  /** 全量回写某账号的群聊文件 */
  private writeAll(account: string, list: GroupChatMessageInfo[]): boolean {
    const lines: string[] = [];
    for (let i = 0; i < list.length; i++) {
      lines.push(JSON.stringify(list[i]));
    }
    try {
      const path: string = this.fileOf(account);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, lines.join('\n') + '\n');
      fileIo.closeSync(file);
    } catch (e) {
      return false;
    }
    return true;
  }

  /** 每个群只保留最新 MAX_PER_THREAD 条（按时间排好序后从尾部截取） */
  private trimPerThread(list: GroupChatMessageInfo[]): GroupChatMessageInfo[] {
    this.sortByTime(list);
    const counts: Map<number, number> = new Map<number, number>();
    const kept: GroupChatMessageInfo[] = [];
    for (let i = list.length - 1; i >= 0; i--) {
      const gid: number = list[i].groupId;
      const n: number = counts.get(gid) ?? 0;
      if (n < MAX_PER_THREAD) {
        counts.set(gid, n + 1);
        kept.push(list[i]);
      }
    }
    kept.reverse();
    return kept;
  }

  /** 原地按时间正序（createdAt 相同时按 id，保证回执与副本的稳定顺序） */
  private sortByTime(list: GroupChatMessageInfo[]): void {
    list.sort((a: GroupChatMessageInfo, b: GroupChatMessageInfo): number => {
      if (a.createdAt !== b.createdAt) {
        return a.createdAt - b.createdAt;
      }
      return a.id - b.id;
    });
  }

  /** 账号名 → 文件名（账号里的非安全字符替换为 _） */
  private fileOf(account: string): string {
    const safe: string = account.replace(/[^0-9A-Za-z_-]/g, '_');
    const dir: string = this.context !== null ? this.context.filesDir : '';
    return `${dir}/groupchats-${safe}.jsonl`;
  }
}

export const groupChatStore: GroupChatStore = new GroupChatStore();
