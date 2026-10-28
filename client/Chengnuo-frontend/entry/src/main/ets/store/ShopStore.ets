import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ShopCardInfo, ServerMapper, endMomentOf } from '../net/ServerModels';

/** 一张卡片小铺推荐卡（89 ai.shop 生成；字段与正式卡内容一致，加入时经 53+56 转为正式卡） */
export class ShopCardRecord {
  purpose: string = '';
  event: string = '';
  time: string = '';
  reminderTime: string = '';
  repeatTime: string = '';
  repeatUntil: string = '';
  location: string = '';
  type: string = '';
  scene: string = '';
  theme: string = '';
  /** 话题标签（≤5 个、每个 ≤12 字、不带 # 前缀；发现页 # 搜索匹配、加入日程时随 56 上送） */
  tags: string[] = [];
  /** 加入日程后记录所建卡片组 id（0 = 未加入；加入后卡片保留在小铺，供与 54 对账回归） */
  joinedGroupId: number = 0;

  static fromCard(card: ShopCardInfo): ShopCardRecord {
    const r = new ShopCardRecord();
    r.purpose = card.purpose;
    r.event = card.event;
    r.time = card.time;
    r.reminderTime = card.reminderTime;
    r.repeatTime = card.repeatTime;
    r.repeatUntil = card.repeatUntil;
    r.location = card.location;
    r.type = card.type;
    r.scene = card.scene;
    r.theme = card.theme;
    r.tags = card.tags.slice();
    return r;
  }
}

/** 小铺历史保留上限：每天一批追加下超出后裁掉最旧的推荐（本地文件兜底） */
const SHOP_MAX_CARDS = 50;

/** 本地日期键（yyyy-MM-dd）：小铺「一天刷一次」的批次日期判定 */
export function todayKey(): string {
  const d: Date = new Date();
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  return `${d.getFullYear()}-${m < 10 ? '0' : ''}${m}-${day < 10 ? '0' : ''}${day}`;
}

/**
 * 卡片小铺（端侧持久化，按账号隔离，仿 PostcardStore）：
 * - 每个账号一个文件 filesDir/shop-<账号>.json（单 JSON：{ cards, genDay }）
 * - 一天刷一次：每天首次进小铺自动生成当日一批（4 张，89 串行生成即落盘），
 *   当日不再生成、不提供主动刷新；结束时刻已过的推荐在进小铺/下拉刷新时清理（pruneEnded），
 *   未结束的历史推荐保留，超过 SHOP_MAX_CARDS 时裁掉最旧的；
 *   旧版 { weekStart, cards } / { cards } 文件读取时自动兼容（genDay 缺失 = 视为待刷新）
 * - 服务器（89 ai.shop）按「周报累计统计 + 资料 + 已有日程 + exclude 已推荐活动名」生成推荐卡不落库，端侧保存
 * - 用户点「加入日程」经 53+56 建私人卡片组加卡后标记 joinedGroupId（卡片保留在小铺，
 *   显示「已加入日程/已结束」态）；从日程删除该卡后对照 54 回归未加入，恢复加入按钮
 */
export class ShopStore {
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility 启动时注入上下文（filesDir 所在） */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 读某账号的小铺卡片（历史保留；文件缺失/损坏/无 cards 字段返回空列表，不阻断使用） */
  listOf(account: string): ShopCardRecord[] {
    const list: ShopCardRecord[] = [];
    if (this.context === null || account.length === 0) {
      return list;
    }
    const rec: Record<string, Object> | null = this.readRec(account);
    if (rec === null) {
      return list;
    }
    const cardsRaw: Object | undefined = rec['cards'];
    if (cardsRaw === undefined || cardsRaw === null) {
      return list;
    }
    const arr: Object[] = cardsRaw as Object[];
    for (let i = 0; i < arr.length; i++) {
      const cardRec: Record<string, Object> | null = ServerMapper.toRecord(arr[i]);
      if (cardRec === null) {
        continue;
      }
      const r: ShopCardRecord = new ShopCardRecord();
      r.purpose = ServerMapper.text(cardRec, 'purpose');
      r.event = ServerMapper.text(cardRec, 'event');
      r.time = ServerMapper.text(cardRec, 'time');
      r.reminderTime = ServerMapper.text(cardRec, 'reminderTime');
      r.repeatTime = ServerMapper.text(cardRec, 'repeatTime');
      r.repeatUntil = ServerMapper.text(cardRec, 'repeatUntil');
      r.location = ServerMapper.text(cardRec, 'location');
      r.type = ServerMapper.text(cardRec, 'type');
      r.scene = ServerMapper.text(cardRec, 'scene');
      r.theme = ServerMapper.text(cardRec, 'theme');
      r.tags = ServerMapper.textList(cardRec, 'tags');
      r.joinedGroupId = ServerMapper.num(cardRec, 'joinedGroupId', 0);
      if (r.event.length > 0 && r.time.length > 0) {
        list.push(r);
      }
    }
    return list;
  }

  /** 追加一张推荐卡（每张生成即落盘，中断可保留已生成部分），超过保留上限裁掉最旧的；成功后自增 shopStamp 通知界面 */
  add(account: string, record: ShopCardRecord): void {
    if (this.context === null || account.length === 0) {
      return;
    }
    const list: ShopCardRecord[] = this.listOf(account);
    list.push(record);
    while (list.length > SHOP_MAX_CARDS) {
      list.shift();
    }
    if (this.writeRec(account, list, this.genDayOf(account))) {
      this.touch();
    }
  }

  /** 最近一次生成批次的日子（yyyy-MM-dd；一天只生成一批，空串 = 还没生成过/旧版文件待刷新） */
  genDayOf(account: string): string {
    if (this.context === null || account.length === 0) {
      return '';
    }
    const rec: Record<string, Object> | null = this.readRec(account);
    if (rec === null) {
      return '';
    }
    return ServerMapper.text(rec, 'genDay');
  }

  /** 记录当日批次已生成（一天刷一次：当日不再生成新批次） */
  setGenDay(account: string, day: string): void {
    if (this.context === null || account.length === 0) {
      return;
    }
    if (this.writeRec(account, this.listOf(account), day)) {
      this.touch();
    }
  }

  /** 清理已结束的推荐（结束时刻已过的小铺卡整张移除，含已加入日程的；进小铺/下拉刷新时调用）。
   *  有删减才回写并自增 shopStamp，返回是否有删减；无有效结束时刻的卡视为招募中保留 */
  pruneEnded(account: string): boolean {
    if (this.context === null || account.length === 0) {
      return false;
    }
    const list: ShopCardRecord[] = this.listOf(account);
    const kept: ShopCardRecord[] = [];
    for (let i = 0; i < list.length; i++) {
      const end: Date | null = endMomentOf(list[i].time);
      if (end === null || end.getTime() >= Date.now()) {
        kept.push(list[i]);
      }
    }
    if (kept.length === list.length || !this.writeRec(account, kept, this.genDayOf(account))) {
      return false;
    }
    this.touch();
    return true;
  }

  /** 加入日程后标记该卡：记录所建卡片组 id（按 event+time 内容定位避免索引漂移），成功后自增 shopStamp */
  markJoined(account: string, event: string, time: string, groupId: number): boolean {
    return this.setJoined(account, event, time, groupId, true);
  }

  /** 该卡从日程删除后回归未加入（恢复「加入日程」按钮）；本就未加入的卡为无操作不触发刷新 */
  resetJoined(account: string, event: string, time: string): boolean {
    return this.setJoined(account, event, time, 0, false);
  }

  /** 按 event+time 定位一张卡改写 joinedGroupId 并回写文件 */
  private setJoined(account: string, event: string, time: string, groupId: number, mark: boolean): boolean {
    if (this.context === null || account.length === 0) {
      return false;
    }
    const list: ShopCardRecord[] = this.listOf(account);
    let found: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].event === event && list[i].time === time) {
        if (!mark && list[i].joinedGroupId === 0) {
          return false;
        }
        list[i].joinedGroupId = groupId;
        found = true;
        break;
      }
    }
    if (!found || !this.writeRec(account, list, this.genDayOf(account))) {
      return false;
    }
    this.touch();
    return true;
  }

  /** 小铺数据变化 → 自增 shopStamp（发现页等监听方收到后重取） */
  private touch(): void {
    const stamp: number = AppStorage.get<number>('shopStamp') ?? 0;
    AppStorage.setOrCreate('shopStamp', stamp + 1);
  }

  /** 读取某账号的小铺文件（文件缺失/损坏返回 null） */
  private readRec(account: string): Record<string, Object> | null {
    const path: string = this.fileOf(account);
    // fs.accessSync 对不存在的路径会抛 13900002（而非返回 false），单独兜底
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

  /** 全量回写某账号的小铺文件（量小全量重写即可；旧版 { weekStart, cards } / { cards } 同时迁移为 { cards, genDay }） */
  private writeRec(account: string, list: ShopCardRecord[], genDay: string): boolean {
    try {
      const path: string = this.fileOf(account);
      const rec: Record<string, Object> = { 'cards': list, 'genDay': genDay };
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(rec));
      fileIo.closeSync(file);
    } catch (e) {
      return false;
    }
    return true;
  }

  /** 账号名 → 文件名（账号里的非安全字符替换为 _） */
  private fileOf(account: string): string {
    const safe: string = account.replace(/[^0-9A-Za-z_-]/g, '_');
    const dir: string = this.context !== null ? this.context.filesDir : '';
    return `${dir}/shop-${safe}.json`;
  }
}

export const shopStore: ShopStore = new ShopStore();
