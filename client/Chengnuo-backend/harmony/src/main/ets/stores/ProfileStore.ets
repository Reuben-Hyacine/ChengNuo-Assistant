import { fileIo, fileUri } from '@kit.CoreFileKit';
import { JsonRec, Jsonl } from '../Jsonl';

/**
 * 个人空间记录（服务 90/91）：客户端本地副本，与服务器副本各存一份。
 * 字段与服务器端同构：性别（''/男/女/不公开）/ 生日（''或 YYYY-MM-DD）/
 * 个性签名（审核）/ 地区（省/市）/ 头像（avatar-<账号>.jpg，JPEG 二进制）。
 * 昵称即账号名（账号模块 82 改名），个人空间不单独存昵称。
 */
export class ProfileRecord {
  readonly account: string;
  gender: string;
  birthday: string;
  signature: string;
  province: string;
  city: string;
  hasAvatar: boolean;
  readonly updatedAt: string;

  constructor(account: string, gender: string, birthday: string,
    signature: string, province: string, city: string, hasAvatar: boolean, updatedAt: string) {
    this.account = account;
    this.gender = gender;
    this.birthday = birthday;
    this.signature = signature;
    this.province = province;
    this.city = city;
    this.hasAvatar = hasAvatar;
    this.updatedAt = updatedAt;
  }

  copy(): ProfileRecord {
    return new ProfileRecord(this.account, this.gender, this.birthday,
      this.signature, this.province, this.city, this.hasAvatar, this.updatedAt);
  }

  toRecord(): Record<string, Object> {
    const rec: Record<string, Object> = {
      'account': this.account,
      'gender': this.gender,
      'birthday': this.birthday,
      'signature': this.signature,
      'province': this.province,
      'city': this.city,
      'hasAvatar': this.hasAvatar,
      'updatedAt': this.updatedAt
    };
    return rec;
  }
}

/**
 * profile.txt + avatar-<账号>.jpg：个人空间客户端副本（UTF-8 JSONL，可手动编辑）。
 * 头像与记录同目录（backend-data）；hasAvatar 以头像文件实际存在为准（避免记录与文件脱节）。
 */
export class ProfileStore {
  private cache: ProfileRecord[] = [];
  private loaded: boolean = false;

  private filePath(): string {
    return Jsonl.dataFilePath('profile.txt');
  }

  /** 账号名 → 头像文件安全名（路径分隔符等禁用字符与空白替换为 _） */
  private avatarFileName(account: string): string {
    const safe: string = account.replace(new RegExp('[\\\\/:*?"<>|\\s]'), '_');
    return `avatar-${safe}.jpg`;
  }

  private avatarPathOf(account: string): string {
    return Jsonl.dataFilePath(this.avatarFileName(account));
  }

  private normalize(parsed: Object | null): ProfileRecord | null {
    const rec: Record<string, Object> | null = JsonRec.toRecord(parsed);
    if (rec === null) {
      return null;
    }
    const account: string = JsonRec.trimText(rec['account']);
    if (account.length === 0) {
      return null;
    }
    return new ProfileRecord(
      account,
      JsonRec.trimText(rec['gender']),
      JsonRec.trimText(rec['birthday']),
      JsonRec.text(rec['signature']),
      JsonRec.trimText(rec['province']),
      JsonRec.trimText(rec['city']),
      rec['hasAvatar'] === true,
      JsonRec.strOrNull(rec['updatedAt']) ?? JsonRec.isoNow()
    );
  }

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    const records: Object[] = Jsonl.readJsonl(this.filePath());
    this.cache = [];
    for (let i = 0; i < records.length; i++) {
      const rec: ProfileRecord | null = this.normalize(records[i]);
      if (rec !== null) {
        this.cache.push(rec);
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

  private indexOf(account: string): number {
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].account === account) {
        return i;
      }
    }
    return -1;
  }

  /** 头像文件是否已落盘 */
  avatarFileExistsOf(account: string): boolean {
    if (account.length === 0) {
      return false;
    }
    try {
      return fileIo.accessSync(this.avatarPathOf(account));
    } catch (e) {
      return false;
    }
  }

  /** 已保存头像的 file:// URI（无头像返回 ''），供 Image 组件直接显示 */
  avatarUriOf(account: string): string {
    if (account.length === 0 || !this.avatarFileExistsOf(account)) {
      return '';
    }
    try {
      return fileUri.getUriFromPath(this.avatarPathOf(account));
    } catch (e) {
      return '';
    }
  }

  /** 读取该账号头像字节（无头像/读取失败返回 null），服务 92 本地应答用 */
  avatarBytesOf(account: string): Uint8Array | null {
    if (account.length === 0 || !this.avatarFileExistsOf(account)) {
      return null;
    }
    try {
      const file = fileIo.openSync(this.avatarPathOf(account), fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        return new Uint8Array(buffer);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      return null;
    }
  }

  /** 读取该账号的本地副本（从未保存过返回 null） */
  getProfileOf(account: string): ProfileRecord | null {
    if (account.length === 0) {
      return null;
    }
    this.ensureLoaded();
    const index: number = this.indexOf(account);
    return index < 0 ? null : this.cache[index].copy();
  }

  /**
   * 保存该账号的本地副本。
   * - avatarBytes：undefined = 头像不动；null = 删除头像；Uint8Array = 覆盖头像（JPEG）
   * 返回落库后的完整记录（hasAvatar 以头像文件实际存在为准）。
   */
  saveProfileOf(record: ProfileRecord, avatarBytes: Uint8Array | null | undefined): ProfileRecord {
    this.ensureLoaded();
    const account: string = record.account;
    if (account.length === 0) {
      return record.copy();
    }
    if (avatarBytes !== undefined) {
      const avatarPath: string = this.avatarPathOf(account);
      if (avatarBytes === null) {
        try {
          fileIo.unlinkSync(avatarPath);
        } catch (e) {
          // 头像不存在：幂等
        }
      } else {
        const buffer: ArrayBuffer =
          avatarBytes.buffer.slice(avatarBytes.byteOffset, avatarBytes.byteOffset + avatarBytes.byteLength);
        const file = fileIo.openSync(avatarPath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(file.fd, buffer);
        } finally {
          fileIo.closeSync(file);
        }
      }
    }
    const saved: ProfileRecord = new ProfileRecord(account, record.gender, record.birthday,
      record.signature, record.province, record.city, this.avatarFileExistsOf(account), JsonRec.isoNow());
    const index: number = this.indexOf(account);
    if (index < 0) {
      this.cache.push(saved);
    } else {
      this.cache[index] = saved;
    }
    this.persist();
    return saved.copy();
  }

  /** 改名（82）：本地副本与头像文件一并换名（目标名已有头像时先清掉，避免旧文件残留） */
  renameAccountOf(account: string, newAccount: string): number {
    if (account.length === 0 || newAccount.length === 0 || account === newAccount) {
      return 0;
    }
    this.ensureLoaded();
    const index: number = this.indexOf(account);
    if (index < 0) {
      return 0;
    }
    const rec: ProfileRecord = this.cache[index];
    if (rec.hasAvatar && this.avatarFileExistsOf(account)) {
      const oldPath: string = this.avatarPathOf(account);
      const newPath: string = this.avatarPathOf(newAccount);
      try {
        fileIo.unlinkSync(newPath);
      } catch (e) {
        // 目标名无头像：继续
      }
      try {
        fileIo.renameSync(oldPath, newPath);
      } catch (e) {
        // 改名失败：头像保持原文件，记录仍换名
      }
    }
    const renamed: ProfileRecord = new ProfileRecord(newAccount, rec.gender, rec.birthday,
      rec.signature, rec.province, rec.city, this.avatarFileExistsOf(newAccount), rec.updatedAt);
    const kept: ProfileRecord[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (i === index) {
        continue;
      }
      if (this.cache[i].account === newAccount) {
        continue;
      }
      kept.push(this.cache[i]);
    }
    kept.push(renamed);
    this.cache = kept;
    this.persist();
    return 1;
  }

  /** 退出登录/注销：清除该账号的本地副本与头像文件 */
  clearByAccount(account: string): void {
    if (account.length === 0) {
      return;
    }
    this.ensureLoaded();
    const kept: ProfileRecord[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].account !== account) {
        kept.push(this.cache[i]);
      }
    }
    this.cache = kept;
    try {
      fileIo.unlinkSync(this.avatarPathOf(account));
    } catch (e) {
      // 头像不存在：幂等
    }
    this.persist();
  }
}

export const profileStore: ProfileStore = new ProfileStore();
