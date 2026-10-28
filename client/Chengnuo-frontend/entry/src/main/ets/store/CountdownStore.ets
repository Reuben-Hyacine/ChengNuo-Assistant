import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ServerMapper } from '../net/ServerModels';

/** Date → 'YYYY-MM-DD'（补零、本地时区） */
export function isoOf(d: Date): string {
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const dd: string = day < 10 ? `0${day}` : `${day}`;
  return `${d.getFullYear()}-${mm}-${dd}`;
}

/** 倒计时持久化记录（一行 JSON 长期保存在本账号的倒计时文件里） */
export class CountdownRecord {
  /** 唯一 id（cd-<毫秒时间戳>） */
  id: string = '';
  /** 倒计时名称（如 考试、出发、纪念日） */
  title: string = '';
  /** 目标日期 yyyy-MM-dd */
  targetDate: string = '';
  /** 每年重复（生日/纪念日类：过完自动数下一次） */
  repeatAnnual: boolean = false;
  /** 用户上传的背景图文件名（filesDir/cd-bg/ 下；'' = 未上传，用默认版式） */
  bg: string = '';
  /** 图标 emoji（历史字段：新版界面不再展示，仅为旧数据保留） */
  emoji: string = '';
  /** 创建日期 yyyy-MM-dd */
  createdAt: string = '';

  static of(id: string, title: string, targetDate: string, repeatAnnual: boolean,
    createdAt: string): CountdownRecord {
    const r = new CountdownRecord();
    r.id = id;
    r.title = title;
    r.targetDate = targetDate;
    r.repeatAnnual = repeatAnnual;
    r.createdAt = createdAt;
    return r;
  }
}

/**
 * 倒计时库（端侧持久化，按账号隔离，类「倒数日」应用）：
 * - 每个账号一个文件 filesDir/countdowns-<账号>.jsonl（每行一条记录）
 * - 纯本机功能：不联网、不上传服务器；换账号只读写该账号自己的文件
 * - 数据变化自增 countdownStamp（AppStorage）通知监听方刷新
 */
export class CountdownStore {
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility 启动时注入上下文（filesDir 所在） */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 账号名 → 文件名（账号里的非安全字符替换为 _） */
  private fileOf(account: string): string {
    const safe: string = account.replace(/[^0-9A-Za-z_-]/g, '_');
    const dir: string = this.context !== null ? this.context.filesDir : '';
    return `${dir}/countdowns-${safe}.jsonl`;
  }

  /** 读某账号的全部倒计时（文件缺失/损坏返回空列表，不阻断使用） */
  listOf(account: string): CountdownRecord[] {
    const list: CountdownRecord[] = [];
    if (this.context === null || account.length === 0) {
      return list;
    }
    const path: string = this.fileOf(account);
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
        const r: CountdownRecord = new CountdownRecord();
        r.id = ServerMapper.text(rec, 'id');
        r.title = ServerMapper.text(rec, 'title');
        r.targetDate = ServerMapper.text(rec, 'targetDate');
        r.repeatAnnual = ServerMapper.flag(rec, 'repeatAnnual');
        r.bg = ServerMapper.text(rec, 'bg');
        r.emoji = ServerMapper.text(rec, 'emoji');
        r.createdAt = ServerMapper.text(rec, 'createdAt');
        if (r.id.length > 0 && r.targetDate.length === 10) {
          list.push(r);
        }
      }
    } catch (e) {
      return [];
    }
    return list;
  }

  /** 新增（新 id）或按 id 原位更新，成功（落盘）返回 true 并自增 countdownStamp */
  upsert(account: string, record: CountdownRecord): boolean {
    if (this.context === null || account.length === 0 || record.id.length === 0) {
      return false;
    }
    const list: CountdownRecord[] = this.listOf(account);
    let replaced: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === record.id) {
        list[i] = record;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      list.push(record);
    }
    if (!this.writeAll(account, list)) {
      return false;
    }
    this.touch();
    return true;
  }

  /** 按 id 删除，成功（落盘）返回 true 并自增 countdownStamp；记录带背景图时一并删除其文件 */
  remove(account: string, id: string): boolean {
    if (this.context === null || account.length === 0 || id.length === 0) {
      return false;
    }
    const list: CountdownRecord[] = this.listOf(account);
    const next: CountdownRecord[] = [];
    let removed: boolean = false;
    let removedBg: string = '';
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        removed = true;
        removedBg = list[i].bg;
        continue;
      }
      next.push(list[i]);
    }
    if (!removed || !this.writeAll(account, next)) {
      return false;
    }
    if (removedBg.length > 0) {
      this.removeBg(removedBg);
    }
    this.touch();
    return true;
  }

  /** 系统相册选图 uri → 拷贝为本倒计时专属背景图（cd-bg/cdbg-<id>.jpg），成功返回文件名 */
  copyBgFromUri(srcUri: string, recordId: string): string {
    const dir: string = this.bgDirEnsure();
    if (dir.length === 0 || srcUri.length === 0 || recordId.length === 0) {
      return '';
    }
    const name: string = `cdbg-${recordId}.jpg`;
    try {
      const src = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
      const dst = fileIo.openSync(`${dir}/${name}`,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(src.fd, dst.fd);
      fileIo.closeSync(src);
      fileIo.closeSync(dst);
      return name;
    } catch (e) {
      return '';
    }
  }

  /** 背景图文件完整路径（Image 渲染用） */
  bgPathOf(fileName: string): string {
    if (this.context === null || fileName.length === 0) {
      return '';
    }
    return `${this.context.filesDir}/cd-bg/${fileName}`;
  }

  /** 删除背景图文件（清空背景时；文件不存在静默跳过） */
  removeBg(fileName: string): void {
    if (this.context === null || fileName.length === 0) {
      return;
    }
    try {
      const path: string = this.bgPathOf(fileName);
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
    }
  }

  /** 背景图目录（filesDir/cd-bg；不存在则创建），失败返回 '' */
  private bgDirEnsure(): string {
    if (this.context === null) {
      return '';
    }
    const dir: string = `${this.context.filesDir}/cd-bg`;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
      }
    } catch (e) {
      return '';
    }
    return dir;
  }

  /** 倒计时数据变化 → 自增 countdownStamp */
  private touch(): void {
    const stamp: number = AppStorage.get<number>('countdownStamp') ?? 0;
    AppStorage.setOrCreate('countdownStamp', stamp + 1);
  }

  /** 全量回写某账号的倒计时文件 */
  private writeAll(account: string, list: CountdownRecord[]): boolean {
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

  /** 'YYYY-MM-DD' → 当地零点 Date；解析失败返回 null */
  static parseIso(iso: string): Date | null {
    const parts: string[] = iso.split('-');
    if (parts.length !== 3) {
      return null;
    }
    const y: number = Number(parts[0]);
    const m: number = Number(parts[1]);
    const d: number = Number(parts[2]);
    if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) {
      return null;
    }
    return new Date(y, m - 1, d);
  }

  /** 两个 'YYYY-MM-DD' 相差整天数（to - from；同一天 = 0；解析失败返回 0） */
  static daysBetween(fromIso: string, toIso: string): number {
    const from: Date | null = CountdownStore.parseIso(fromIso);
    const to: Date | null = CountdownStore.parseIso(toIso);
    if (from === null || to === null) {
      return 0;
    }
    return Math.round((to.getTime() - from.getTime()) / 86400000);
  }

  /** 每年重复记录的下一次发生日期（yyyy-MM-dd）：
   *  今年同月同日；已过（早于今天）顺延到明年（2/29 在平年自动落到 3/1） */
  static nextAnnualIso(targetIso: string, todayIso: string): string {
    const t: Date | null = CountdownStore.parseIso(targetIso);
    if (t === null) {
      return todayIso;
    }
    const today: Date | null = CountdownStore.parseIso(todayIso);
    if (today === null) {
      return targetIso;
    }
    const mm: number = t.getMonth();
    const dd: number = t.getDate();
    const cand: Date = new Date(today.getFullYear(), mm, dd);
    const next: Date = cand.getTime() < today.getTime() ? new Date(today.getFullYear() + 1, mm, dd) : cand;
    return isoOf(next);
  }
}

/** 列表展示行（倒计时页/月历右滑预览共用）：记录 + 计算出的排序/展示信息 */
export class CountdownRow {
  record: CountdownRecord = new CountdownRecord();
  /** 计数用的下次发生日期（yyyy-MM-dd；每年重复 = 下一次，一次性 = 目标日期） */
  nextIso: string = '';
  /** 今天到 nextIso 的整天数（正 = 未来；0 = 就是今天；负 = 已过，仅一次性记录可能出现） */
  days: number = 0;

  constructor(record: CountdownRecord, nextIso: string, days: number) {
    this.record = record;
    this.nextIso = nextIso;
    this.days = days;
  }
}

/** 某账号全部倒计时 → 排好序的展示行（未来近的在前；已过的一次性记录沉底、按逾期天数升序） */
export function sortedRowsOf(account: string, todayIso: string): CountdownRow[] {
  const rows: CountdownRow[] = [];
  const records: CountdownRecord[] = countdownStore.listOf(account);
  for (let i = 0; i < records.length; i++) {
    const rec: CountdownRecord = records[i];
    const nextIso: string = rec.repeatAnnual
      ? CountdownStore.nextAnnualIso(rec.targetDate, todayIso) : rec.targetDate;
    rows.push(new CountdownRow(rec, nextIso, CountdownStore.daysBetween(todayIso, nextIso)));
  }
  rows.sort((a: CountdownRow, b: CountdownRow): number => {
    const aPast: boolean = a.days < 0;
    const bPast: boolean = b.days < 0;
    if (aPast !== bPast) {
      return aPast ? 1 : -1;
    }
    const aAbs: number = Math.abs(a.days);
    const bAbs: number = Math.abs(b.days);
    if (aAbs === bAbs) {
      return 0;
    }
    return aAbs < bAbs ? -1 : 1;
  });
  return rows;
}

export const countdownStore: CountdownStore = new CountdownStore();
