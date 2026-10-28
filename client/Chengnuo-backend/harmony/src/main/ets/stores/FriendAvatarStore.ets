import { fileIo, fileUri } from '@kit.CoreFileKit';
import { JsonRec, Jsonl } from '../Jsonl';

/**
 * 好友头像缓存（服务 92 拉取后落盘）：
 * - fav-<账号>.jpg：头像 JPEG（与本人个人空间头像分开存）
 * - friend-avatar-meta.txt：JSONL { account, updatedAt }，缓存版本与服务器 avatarUpdatedAt
 *   一致时直接复用缓存文件，不一致才重新拉取（92）
 */
export class FriendAvatarStore {
  private cache: Map<string, string> = new Map<string, string>();
  private loaded: boolean = false;

  private metaPath(): string {
    return Jsonl.dataFilePath('friend-avatar-meta.txt');
  }

  /** 账号名 → 头像文件安全名（路径分隔符等禁用字符与空白替换为 _） */
  private avatarFileName(account: string): string {
    const safe: string = account.replace(new RegExp('[\\\\/:*?"<>|\\s]', 'g'), '_');
    return `fav-${safe}.jpg`;
  }

  private avatarPathOf(account: string): string {
    return Jsonl.dataFilePath(this.avatarFileName(account));
  }

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    this.cache = new Map<string, string>();
    const records: Object[] = Jsonl.readJsonl(this.metaPath());
    for (let i = 0; i < records.length; i++) {
      const rec: Record<string, Object> | null = JsonRec.toRecord(records[i]);
      if (rec === null) {
        continue;
      }
      const account: string = JsonRec.trimText(rec['account']);
      const updatedAt: string = JsonRec.trimText(rec['updatedAt']);
      if (account.length > 0 && updatedAt.length > 0) {
        this.cache.set(account, updatedAt);
      }
    }
    this.loaded = true;
  }

  private persist(): void {
    const out: Object[] = [];
    this.cache.forEach((updatedAt: string, account: string) => {
      const rec: Record<string, Object> = { 'account': account, 'updatedAt': updatedAt };
      out.push(rec);
    });
    Jsonl.writeJsonl(this.metaPath(), out);
  }

  private fileExistsOf(account: string): boolean {
    try {
      return fileIo.accessSync(this.avatarPathOf(account));
    } catch (e) {
      return false;
    }
  }

  /** 缓存的头像版本（无缓存返回 ''），与服务器 avatarUpdatedAt 比对决定是否重新拉取 */
  cachedUpdatedAtOf(account: string): string {
    if (account.length === 0) {
      return '';
    }
    this.ensureLoaded();
    return this.cache.get(account) ?? '';
  }

  /** 缓存头像的 file:// URI（无缓存或文件丢失返回 ''），供 Image 组件直接显示 */
  avatarUriOf(account: string): string {
    if (account.length === 0) {
      return '';
    }
    this.ensureLoaded();
    if (!this.cache.has(account) || !this.fileExistsOf(account)) {
      return '';
    }
    try {
      return fileUri.getUriFromPath(this.avatarPathOf(account));
    } catch (e) {
      return '';
    }
  }

  /** 保存好友头像（JPEG 字节）与版本号，返回 file:// URI；字节为空时幂等返回 '' */
  saveAvatarOf(account: string, bytes: Uint8Array, updatedAt: string): string {
    if (account.length === 0 || bytes.byteLength === 0) {
      return '';
    }
    this.ensureLoaded();
    const path: string = this.avatarPathOf(account);
    const buffer: ArrayBuffer =
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    const file = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file);
    }
    const stamp: string = updatedAt.length > 0 ? updatedAt : JsonRec.isoNow();
    this.cache.set(account, stamp);
    this.persist();
    try {
      return fileUri.getUriFromPath(path);
    } catch (e) {
      return '';
    }
  }

  /** 移除好友/注销时清缓存（文件与版本记录一并清；不存在幂等） */
  removeAvatarOf(account: string): void {
    if (account.length === 0) {
      return;
    }
    this.ensureLoaded();
    this.cache.delete(account);
    try {
      fileIo.unlinkSync(this.avatarPathOf(account));
    } catch (e) {
      // 头像不存在：幂等
    }
    this.persist();
  }
}

export const friendAvatarStore: FriendAvatarStore = new FriendAvatarStore();
