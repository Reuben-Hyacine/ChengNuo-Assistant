import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ServerMapper } from '../net/ServerModels';

/** 明信片持久化记录（一行 JSON 长期保存在本账号的明信片库文件里） */
export class PostcardRecord {
  /** 完成日期 yyyy-MM-dd */
  date: string = '';
  /** 展示日期（如 10月3日） */
  dateText: string = '';
  title: string = '';
  /** 明信片正文（后端 AI 生成的一句话：时间+事件+祝福） */
  text: string = '';
  gradientIndex: number = 0;
  emoji: string = '💌';
  /** 生成当天天气现象（如 晴/多云，随记录保存） */
  weatherText: string = '';
  /** 生成当天天气图标 emoji（如 ☀️，随记录保存） */
  weatherEmoji: string = '';
  /** 关联群号（0 = 无群/历史记录；上滑查看聊天记录用） */
  groupId: number = 0;
  /** 关联群名（历史记录可能已无对应群，仅作展示兜底） */
  groupName: string = '';

  static of(date: string, dateText: string, title: string, text: string,
    gradientIndex: number, emoji: string, weatherText: string = '', weatherEmoji: string = '',
    groupId: number = 0, groupName: string = ''): PostcardRecord {
    const r = new PostcardRecord();
    r.date = date;
    r.dateText = dateText;
    r.title = title;
    r.text = text;
    r.gradientIndex = gradientIndex;
    r.emoji = emoji;
    r.weatherText = weatherText;
    r.weatherEmoji = weatherEmoji;
    r.groupId = groupId;
    r.groupName = groupName;
    return r;
  }
}

/**
 * 明信片库（端侧持久化，按账号隔离）：
 * - 每个账号一个文件 filesDir/postcards-<账号>.jsonl（每行一条记录）
 * - 服务器（66 postcard.make）只生成正文不持久化，端侧负责长期保存
 * - 账号隔离：换账号登录只读写该账号自己的文件，看不到其他账号的明信片
 */
export class PostcardStore {
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility 启动时注入上下文（filesDir 所在） */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 读某账号的全部明信片（文件缺失/损坏返回空列表，不阻断使用） */
  listOf(account: string): PostcardRecord[] {
    const list: PostcardRecord[] = [];
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
        const r: PostcardRecord = new PostcardRecord();
        r.date = ServerMapper.text(rec, 'date');
        r.dateText = ServerMapper.text(rec, 'dateText');
        r.title = ServerMapper.text(rec, 'title');
        r.text = ServerMapper.text(rec, 'text');
        r.gradientIndex = ServerMapper.num(rec, 'gradientIndex', 0);
        r.emoji = ServerMapper.text(rec, 'emoji');
        r.weatherText = ServerMapper.text(rec, 'weatherText');
        r.weatherEmoji = ServerMapper.text(rec, 'weatherEmoji');
        r.groupId = ServerMapper.num(rec, 'groupId', 0);
        r.groupName = ServerMapper.text(rec, 'groupName');
        list.push(r);
      }
    } catch (e) {
      return [];
    }
    return list;
  }

  /** 追加一条并整体回写（量小全量重写即可），成功后自增 postcardStamp 通知界面刷新 */
  append(account: string, record: PostcardRecord): void {
    if (this.context === null || account.length === 0) {
      return;
    }
    const list: PostcardRecord[] = this.listOf(account);
    list.push(record);
    if (this.writeAll(account, list)) {
      this.touch();
    }
  }

  /** 合并一次拉取到的参与者明信片（103）：按 date+title+text 查重后只追加新记录，
   *  返回实际新增条数（0 = 全部重复/无新增），有新增时自增 postcardStamp */
  mergeMany(account: string, records: PostcardRecord[]): number {
    if (this.context === null || account.length === 0 || records.length === 0) {
      return 0;
    }
    const list: PostcardRecord[] = this.listOf(account);
    let added: number = 0;
    for (let i = 0; i < records.length; i++) {
      const rec: PostcardRecord = records[i];
      let dup: boolean = false;
      for (let j = 0; j < list.length; j++) {
        if (list[j].date === rec.date && list[j].title === rec.title && list[j].text === rec.text) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        list.push(rec);
        added++;
      }
    }
    if (added === 0 || !this.writeAll(account, list)) {
      return 0;
    }
    this.touch();
    return added;
  }

  /** 删除第一条内容匹配的记录（date+title+text 定位，避免索引漂移误删），
   *  成功后自增 postcardStamp 通知界面刷新 */
  remove(account: string, date: string, title: string, text: string): boolean {
    if (this.context === null || account.length === 0) {
      return false;
    }
    const list: PostcardRecord[] = this.listOf(account);
    const next: PostcardRecord[] = [];
    let removed: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (!removed && list[i].date === date && list[i].title === title && list[i].text === text) {
        removed = true;
        continue;
      }
      next.push(list[i]);
    }
    if (!removed || !this.writeAll(account, next)) {
      return false;
    }
    this.touch();
    return true;
  }

  /** 明信片数据变化 → 自增 postcardStamp（日程页/我的页等监听方收到后重取） */
  private touch(): void {
    const stamp: number = AppStorage.get<number>('postcardStamp') ?? 0;
    AppStorage.setOrCreate('postcardStamp', stamp + 1);
  }

  /** 全量回写某账号的明信片文件 */
  private writeAll(account: string, list: PostcardRecord[]): boolean {
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

  /** 某账号明信片总数（用于渐变色轮换） */
  countOf(account: string): number {
    return this.listOf(account).length;
  }

  /** 某账号全部明信片日期（yyyy-MM-dd，日程月历 📮 角标用） */
  datesOf(account: string): string[] {
    const dates: string[] = [];
    const list: PostcardRecord[] = this.listOf(account);
    for (let i = 0; i < list.length; i++) {
      if (list[i].date.length > 0 && dates.indexOf(list[i].date) < 0) {
        dates.push(list[i].date);
      }
    }
    return dates;
  }

  /** 账号名 → 文件名（账号里的非安全字符替换为 _） */
  private fileOf(account: string): string {
    const safe: string = account.replace(/[^0-9A-Za-z_-]/g, '_');
    const dir: string = this.context !== null ? this.context.filesDir : '';
    return `${dir}/postcards-${safe}.jsonl`;
  }

  /** 记录「日期 → 明信片生成当天天气」（服务器明信片记录不带天气字段，端侧随生成时刻按日补存；
   *  展示当日安排/最近一张时回查；格式 '晴|☀️'） */
  setDayWeather(account: string, date: string, weatherText: string, weatherEmoji: string): void {
    if (this.context === null || account.length === 0 || date.length === 0 || weatherText.length === 0) {
      return;
    }
    const rec: Record<string, Object> = this.readWeatherRec(account) ?? {};
    rec[date] = `${weatherText}|${weatherEmoji}`;
    try {
      const path: string = this.weatherFileOf(account);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(rec));
      fileIo.closeSync(file);
    } catch (e) {
      // 写失败静默：天气角标是增强信息，不阻断明信片主流程
    }
  }

  /** 某日期的生成天气 [text, emoji]（无记录返回 ['', '']） */
  dayWeatherOf(account: string, date: string): string[] {
    const rec: Record<string, Object> | null = this.readWeatherRec(account);
    if (rec === null) {
      return ['', ''];
    }
    const value: string = ServerMapper.text(rec, date);
    if (value.length === 0) {
      return ['', ''];
    }
    const parts: string[] = value.split('|');
    return parts.length >= 2 ? [parts[0], parts[1]] : [parts[0], ''];
  }

  /** 读取某账号「日期→生成天气」映射（文件缺失/损坏返回 null） */
  private readWeatherRec(account: string): Record<string, Object> | null {
    if (this.context === null || account.length === 0) {
      return null;
    }
    const path: string = this.weatherFileOf(account);
    let exists: boolean = false;
    try {
      exists = fileIo.accessSync(path);
    } catch (e) {
      exists = false;
    }
    if (!exists) {
      return null;
    }
    try {
      return ServerMapper.toRecord(JSON.parse(fileIo.readTextSync(path)));
    } catch (e) {
      return null;
    }
  }

  /** 生成天气映射文件名（与明信片库同目录、同账号隔离） */
  private weatherFileOf(account: string): string {
    const safe: string = account.replace(/[^0-9A-Za-z_-]/g, '_');
    const dir: string = this.context !== null ? this.context.filesDir : '';
    return `${dir}/postcards-weather-${safe}.json`;
  }
}

export const postcardStore: PostcardStore = new PostcardStore();
