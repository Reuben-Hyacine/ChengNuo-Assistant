import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ServerMapper, endMomentOf, startMomentOf } from '../net/ServerModels';

/** 装饰槽位：head = 头饰（帽子），neck = 颈饰（围巾） */
export const PET_DECOR_SLOT_HEAD: string = 'head';
export const PET_DECOR_SLOT_NECK: string = 'neck';

/** 商城装饰物（帽子/围巾两槽位；素材在 resources/base/media/decor_*.png，名字走 I18n） */
export class PetDecor {
  id: string = '';
  name: string = '';
  slot: string = PET_DECOR_SLOT_HEAD;
  price: number = 5000;

  constructor(id: string, name: string, slot: string, price: number) {
    this.id = id;
    this.name = name;
    this.slot = slot;
    this.price = price;
  }
}

/** 装饰商城目录（10 件：5 顶帽子 + 5 条围巾，普通品质 5000 积分一档） */
export const PET_DECORS: PetDecor[] = [
  new PetDecor('hat_red', '红色毛线帽', PET_DECOR_SLOT_HEAD, 5000),
  new PetDecor('hat_blue', '蓝色毛线帽', PET_DECOR_SLOT_HEAD, 5000),
  new PetDecor('hat_yellow', '黄色毛线帽', PET_DECOR_SLOT_HEAD, 5000),
  new PetDecor('hat_green', '绿色毛线帽', PET_DECOR_SLOT_HEAD, 5000),
  new PetDecor('hat_purple', '紫色护耳帽', PET_DECOR_SLOT_HEAD, 5000),
  new PetDecor('scarf_orange', '暖橙围巾', PET_DECOR_SLOT_NECK, 5000),
  new PetDecor('scarf_cyan', '薄荷绿围巾', PET_DECOR_SLOT_NECK, 5000),
  new PetDecor('scarf_lavender', '薰衣草围巾', PET_DECOR_SLOT_NECK, 5000),
  new PetDecor('scarf_coral', '珊瑚围巾', PET_DECOR_SLOT_NECK, 5000),
  new PetDecor('scarf_pink', '樱花粉围巾', PET_DECOR_SLOT_NECK, 5000)
];

/** 积分规则：每 1 小时 500 积分（2 小时 1000）；单点卡按 1 小时计；单卡最长计 24 小时 */
const PET_POINTS_PER_HOUR = 500;
const PET_DEFAULT_HOURS = 1;
const PET_MAX_HOURS_PER_CARD = 24;

/** 历史明信片补记截止日期（yyyy-MM-dd）：只补记这天及之前生成的明信片，之后的完成在 62 完成处现场记账 */
const PET_BACKFILL_UNTIL = '2026-10-18';

/** 宠物名字上限（字节无关，按字符数截断） */
const PET_NAME_MAX = 12;

/** 无限积分账号（仅此一个测试账号）：余额恒为大数、不随消费减少，其余账号按账本计算 */
const PET_UNLIMITED_ACCOUNT: string = '猪肉脯可爱喵喵';
const PET_UNLIMITED_BALANCE: number = 999999;

/** 一张已完成卡片按计划时长折算积分：无区间按 1 小时，区间超 24 小时封顶，无有效时间不计分 */
export function petPointsOfTime(time: string): number {
  const start: Date | null = startMomentOf(time);
  if (start === null) {
    return 0;
  }
  const end: Date | null = endMomentOf(time);
  let hours: number = PET_DEFAULT_HOURS;
  if (end !== null && end.getTime() > start.getTime()) {
    hours = (end.getTime() - start.getTime()) / 3600000;
  }
  if (hours > PET_MAX_HOURS_PER_CARD) {
    hours = PET_MAX_HOURS_PER_CARD;
  }
  return Math.floor(hours * PET_POINTS_PER_HOUR);
}

/**
 * 宠物养成（端侧持久化，按账号隔离，仿 ShopStore）：
 * - 名字/补记标记/消费记 filesDir/pet-<账号>.json（单 JSON：{ name, seeded, owned, spent, wearing_head, wearing_neck }）
 * - 积分走账本 filesDir/pet-ledger-<账号>.jsonl（每行 { key, points }）：
 *   62 完成出稿成功即删卡 → 在完成处按计划时长现场记账（key = pc-<明信片号>，先于明信片入库不会重复）；
 *   出稿失败留在组内的已完成卡由宠物页经 54 补记（key = lib-<组号>-<卡号>）；
 *   功能上线前已归档的明信片每张按 1 小时一次性补记（key = bf-<日期>-<序号>）。
 *   三类 key 互斥、写入前查重，累计获得 = 账本求和，余额 = 累计获得 - spent（全本地，离线可用）
 * - 名字 / 佩戴状态 / 会话问候标记：名字与佩戴持久化；问候（咕咕嘎嘎）每次启动会话内只触发一次（内存标记）
 */
export class PetStore {
  private context: common.Context | null = null;
  /** 本次启动会话是否已问候过（不持久化：每次登录/启动重置） */
  private greetedThisSession: boolean = false;

  /** EntryAbility 启动时注入上下文（filesDir 所在）；卡片桌面组件进程传 FormExtensionContext（同为 common.Context） */
  init(context: common.Context): void {
    this.context = context;
  }

  /** 消费本次会话的首次问候资格：只有启动后第一次进宠物页返回 true */
  consumeGreet(): boolean {
    if (this.greetedThisSession) {
      return false;
    }
    this.greetedThisSession = true;
    return true;
  }

  /** 宠物名字（未设置过用默认名） */
  nameOf(account: string): string {
    const rec: Record<string, Object> | null = this.readRec(account);
    if (rec === null) {
      return '小企鹅';
    }
    const name: string = ServerMapper.text(rec, 'name');
    return name.length > 0 ? name : '小企鹅';
  }

  /** 改名（去空格、超 12 字截断、空串不写入），成功后自增 petStamp */
  setName(account: string, name: string): void {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return;
    }
    const rec: Record<string, Object> | null = this.readRec(account);
    const next: Record<string, Object> = rec !== null ? rec : this.emptyRec();
    next['name'] = trimmed.length > PET_NAME_MAX ? trimmed.substring(0, PET_NAME_MAX) : trimmed;
    if (this.writeRec(account, next)) {
      this.touch();
    }
  }

  /** 账本累计获得积分（全部记录求和） */
  earnedOf(account: string): number {
    const lines: Record<string, Object>[] = this.ledgerLines(account);
    let earned: number = 0;
    for (let i = 0; i < lines.length; i++) {
      earned += ServerMapper.num(lines[i], 'points', 0);
    }
    return earned;
  }

  /** 记入一笔获得积分（key 已存在/积分为 0 不写），写入成功自增 petStamp；返回是否新记入 */
  addEarned(account: string, key: string, points: number): boolean {
    if (key.length === 0 || points <= 0 || this.context === null || account.length === 0) {
      return false;
    }
    const lines: Record<string, Object>[] = this.ledgerLines(account);
    for (let i = 0; i < lines.length; i++) {
      if (ServerMapper.text(lines[i], 'key') === key) {
        return false;
      }
    }
    lines.push({ 'key': key, 'points': points });
    if (!this.writeLedger(account, lines)) {
      return false;
    }
    this.touch();
    return true;
  }

  /** 一次性补记功能上线前已归档的明信片（每张按 1 小时折算）：只补 PET_BACKFILL_UNTIL 及之前的日期，
   *  无论有无可补都打上 seeded 标记，保证每账号只执行一次（之后的明信片走完成处现场记账，不会二次补） */
  seedLegacyOnce(account: string, postcardDates: string[]): void {
    if (this.context === null || account.length === 0 || this.seededOf(account)) {
      return;
    }
    for (let i = 0; i < postcardDates.length; i++) {
      const date: string = postcardDates[i];
      if (date.length > 0 && date <= PET_BACKFILL_UNTIL) {
        this.addEarned(account, `bf-${date}-${i}`, PET_POINTS_PER_HOUR * PET_DEFAULT_HOURS);
      }
    }
    const rec: Record<string, Object> | null = this.readRec(account);
    const next: Record<string, Object> = rec !== null ? rec : this.emptyRec();
    next['seeded'] = 1;
    this.writeRec(account, next);
  }

  /** 是否已执行过历史明信片一次性补记 */
  private seededOf(account: string): boolean {
    const rec: Record<string, Object> | null = this.readRec(account);
    return rec !== null && ServerMapper.num(rec, 'seeded', 0) === 1;
  }

  /** 已兑换装饰 id 列表 */
  ownedOf(account: string): string[] {
    const rec: Record<string, Object> | null = this.readRec(account);
    if (rec === null) {
      return [];
    }
    return ServerMapper.textList(rec, 'owned');
  }

  /** 累计已消费积分（随兑换累加的总账） */
  spentOf(account: string): number {
    const rec: Record<string, Object> | null = this.readRec(account);
    if (rec === null) {
      return 0;
    }
    return ServerMapper.num(rec, 'spent', 0);
  }

  /** 当前某槽位佩戴的装饰 id（'head' 帽子 / 'neck' 围巾；空串 = 未佩戴） */
  wornInSlot(account: string, slot: string): string {
    const rec: Record<string, Object> | null = this.readRec(account);
    if (rec === null) {
      return '';
    }
    if (slot === PET_DECOR_SLOT_HEAD) {
      return ServerMapper.text(rec, 'wearing_head');
    }
    if (slot === PET_DECOR_SLOT_NECK) {
      return ServerMapper.text(rec, 'wearing_neck');
    }
    return '';
  }

  /** 当前可用余额 = 账本累计获得 - 已消费（无限积分账号恒为大数，不随消费减少） */
  balanceOf(account: string): number {
    if (account === PET_UNLIMITED_ACCOUNT) {
      return PET_UNLIMITED_BALANCE;
    }
    return this.earnedOf(account) - this.spentOf(account);
  }

  /** 兑换装饰：余额不足返回 false；成功记录 owned/spent 并自增 petStamp */
  buyDecor(account: string, decor: PetDecor): boolean {
    if (this.balanceOf(account) < decor.price) {
      return false;
    }
    const rec: Record<string, Object> | null = this.readRec(account);
    const next: Record<string, Object> = rec !== null ? rec : this.emptyRec();
    const owned: string[] = ServerMapper.textList(next, 'owned');
    if (owned.indexOf(decor.id) >= 0) {
      return false;
    }
    owned.push(decor.id);
    next['owned'] = owned;
    next['spent'] = ServerMapper.num(next, 'spent', 0) + decor.price;
    if (!this.writeRec(account, next)) {
      return false;
    }
    this.touch();
    return true;
  }

  /** 佩戴/取下装饰（按装饰所属槽位切换：同槽位再点已佩戴的那件 = 取下；id 须在已拥有列表内），成功后自增 petStamp */
  wearDecor(account: string, decorId: string): void {
    let decor: PetDecor | null = null;
    for (let i = 0; i < PET_DECORS.length; i++) {
      if (PET_DECORS[i].id === decorId) {
        decor = PET_DECORS[i];
        break;
      }
    }
    if (decor === null) {
      return;
    }
    const rec: Record<string, Object> | null = this.readRec(account);
    const next: Record<string, Object> = rec !== null ? rec : this.emptyRec();
    if (ServerMapper.textList(next, 'owned').indexOf(decorId) < 0) {
      return;
    }
    if (decor.slot === PET_DECOR_SLOT_HEAD) {
      next['wearing_head'] = ServerMapper.text(next, 'wearing_head') === decorId ? '' : decorId;
    } else if (decor.slot === PET_DECOR_SLOT_NECK) {
      next['wearing_neck'] = ServerMapper.text(next, 'wearing_neck') === decorId ? '' : decorId;
    }
    if (this.writeRec(account, next)) {
      this.touch();
    }
  }

  /** 宠物数据变化 → 自增 petStamp（宠物页监听后重读） */
  private touch(): void {
    const stamp: number = AppStorage.get<number>('petStamp') ?? 0;
    AppStorage.setOrCreate('petStamp', stamp + 1);
  }

  private emptyRec(): Record<string, Object> {
    return { 'name': '小企鹅', 'seeded': 0, 'owned': [], 'spent': 0, 'wearing_head': '', 'wearing_neck': '' };
  }

  /** 读取某账号的宠物文件（文件缺失/损坏返回 null） */
  private readRec(account: string): Record<string, Object> | null {
    if (this.context === null || account.length === 0) {
      return null;
    }
    const path: string = this.fileOf(account);
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

  /** 全量回写某账号的宠物文件（字段少，全量重写即可） */
  private writeRec(account: string, rec: Record<string, Object>): boolean {
    if (this.context === null || account.length === 0) {
      return false;
    }
    try {
      const path: string = this.fileOf(account);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(rec));
      fileIo.closeSync(file);
    } catch (e) {
      return false;
    }
    return true;
  }

  /** 读取某账号的积分账本（每行 { key, points }；文件缺失/损坏返回空列表） */
  private ledgerLines(account: string): Record<string, Object>[] {
    const lines: Record<string, Object>[] = [];
    if (this.context === null || account.length === 0) {
      return lines;
    }
    const path: string = this.ledgerFileOf(account);
    let exists: boolean = false;
    try {
      exists = fileIo.accessSync(path);
    } catch (e) {
      exists = false;
    }
    if (!exists) {
      return lines;
    }
    try {
      const rows: string[] = fileIo.readTextSync(path).split('\n');
      for (let i = 0; i < rows.length; i++) {
        const row: string = rows[i].trim();
        if (row.length === 0) {
          continue;
        }
        const rec: Record<string, Object> | null = ServerMapper.toRecord(JSON.parse(row));
        if (rec !== null) {
          lines.push(rec);
        }
      }
    } catch (e) {
      return [];
    }
    return lines;
  }

  /** 全量回写某账号的积分账本 */
  private writeLedger(account: string, lines: Record<string, Object>[]): boolean {
    if (this.context === null || account.length === 0) {
      return false;
    }
    try {
      const path: string = this.ledgerFileOf(account);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const rows: string[] = [];
      for (let i = 0; i < lines.length; i++) {
        rows.push(JSON.stringify(lines[i]));
      }
      fileIo.writeSync(file.fd, rows.join('\n') + '\n');
      fileIo.closeSync(file);
    } catch (e) {
      return false;
    }
    return true;
  }

  /** 积分账本文件名（与宠物主文件同目录、同账号隔离） */
  private ledgerFileOf(account: string): string {
    const safe: string = account.replace(/[^0-9A-Za-z_-]/g, '_');
    return `${this.context?.filesDir ?? ''}/pet-ledger-${safe}.jsonl`;
  }

  /** 账号名 → 文件名（账号里的非安全字符替换为 _） */
  private fileOf(account: string): string {
    const safe: string = account.replace(/[^0-9A-Za-z_-]/g, '_');
    return `${this.context?.filesDir ?? ''}/pet-${safe}.json`;
  }
}

export const petStore: PetStore = new PetStore();
