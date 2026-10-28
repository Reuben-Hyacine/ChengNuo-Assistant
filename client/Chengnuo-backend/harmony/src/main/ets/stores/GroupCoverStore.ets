import { fileIo, fileUri } from '@kit.CoreFileKit';
import { JsonRec, Jsonl } from '../Jsonl';

/**
 * 卡片组封面缓存（服务 112 拉取后落盘）：
 * - gcover-<组号>.jpg：封面 JPEG
 * - group-cover-meta.txt：JSONL { groupId, updatedAt }，缓存版本与服务器 coverUpdatedAt
 *   一致时直接复用缓存文件，不一致才重新拉取（112）
 */
export class GroupCoverStore {
  private cache: Map<number, string> = new Map<number, string>();
  private loaded: boolean = false;

  private metaPath(): string {
    return Jsonl.dataFilePath('group-cover-meta.txt');
  }

  private coverFileName(groupId: number): string {
    return `gcover-${groupId}.jpg`;
  }

  private coverPathOf(groupId: number): string {
    return Jsonl.dataFilePath(this.coverFileName(groupId));
  }

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    this.cache = new Map<number, string>();
    const records: Object[] = Jsonl.readJsonl(this.metaPath());
    for (let i = 0; i < records.length; i++) {
      const rec: Record<string, Object> | null = JsonRec.toRecord(records[i]);
      if (rec === null) {
        continue;
      }
      const groupId: number | null = JsonRec.intOrNull(rec['groupId']);
      const updatedAt: string = JsonRec.trimText(rec['updatedAt']);
      if (groupId !== null && groupId >= 1 && updatedAt.length > 0) {
        this.cache.set(groupId, updatedAt);
      }
    }
    this.loaded = true;
  }

  private persist(): void {
    const out: Object[] = [];
    this.cache.forEach((updatedAt: string, groupId: number) => {
      const rec: Record<string, Object> = { 'groupId': groupId, 'updatedAt': updatedAt };
      out.push(rec);
    });
    Jsonl.writeJsonl(this.metaPath(), out);
  }

  private fileExistsOf(groupId: number): boolean {
    try {
      return fileIo.accessSync(this.coverPathOf(groupId));
    } catch (e) {
      return false;
    }
  }

  /** 缓存的封面版本（无缓存返回 ''），与服务器 coverUpdatedAt 比对决定是否重新拉取 */
  cachedUpdatedAtOf(groupId: number): string {
    if (!Number.isInteger(groupId) || groupId < 1) {
      return '';
    }
    this.ensureLoaded();
    return this.cache.get(groupId) ?? '';
  }

  /** 缓存封面的 file:// URI（无缓存或文件丢失返回 ''），供 Image 组件直接显示 */
  coverUriOf(groupId: number): string {
    if (!Number.isInteger(groupId) || groupId < 1) {
      return '';
    }
    this.ensureLoaded();
    if (!this.cache.has(groupId) || !this.fileExistsOf(groupId)) {
      return '';
    }
    try {
      return fileUri.getUriFromPath(this.coverPathOf(groupId));
    } catch (e) {
      return '';
    }
  }

  /** 保存组封面（JPEG 字节）与版本号，返回 file:// URI；字节为空时幂等返回 '' */
  saveCoverOf(groupId: number, bytes: Uint8Array, updatedAt: string): string {
    if (!Number.isInteger(groupId) || groupId < 1 || bytes.byteLength === 0) {
      return '';
    }
    this.ensureLoaded();
    const path: string = this.coverPathOf(groupId);
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
    this.cache.set(groupId, stamp);
    this.persist();
    try {
      return fileUri.getUriFromPath(path);
    } catch (e) {
      return '';
    }
  }

  /** 删除组封面（105 remove）后同步清本地缓存（文件与版本记录一并清；不存在幂等） */
  removeCoverOf(groupId: number): void {
    if (!Number.isInteger(groupId) || groupId < 1) {
      return;
    }
    this.ensureLoaded();
    this.cache.delete(groupId);
    try {
      fileIo.unlinkSync(this.coverPathOf(groupId));
    } catch (e) {
      // 封面不存在：幂等
    }
    this.persist();
  }
}

export const groupCoverStore: GroupCoverStore = new GroupCoverStore();
