/**
 * 程诺数据模型：卡片 / 目标 / 对话 / 好友 / 群组 / 活动 / 收件箱 / 明信片 / 日历
 */

export enum CardKind {
  Schedule = 0,
  Task = 1,
  Activity = 2
}

export enum CardStatus {
  Empty = 0,
  Set = 1,
  Done = 2
}

export class TaskCard {
  id: string = '';
  title: string = '';
  kind: CardKind = CardKind.Schedule;
  status: CardStatus = CardStatus.Empty;
  dateText: string = '';
  timeText: string = '';
  place: string = '';
  symbol: string = '';
  note: string = '';
  isRepeat: boolean = false;
  progress: number = 0;
  confirmText: string = '';
  flipToken: number = 0;
  /** PRO MAX 服务器卡片组定位（id 形如 srv-g{groupId}-{cardIndex}，删除/退出时回传服务器） */
  groupId: number = 0;
  /** 我是否该组的创建者（true=发起者，日程页「删除」按钮仅发起者可见） */
  isOwner: boolean = false;
  /** 服务器侧被指定的完成者账号（空 = 未指定；日程页「完成」按钮仅指定完成者可见，本地卡不使用） */
  completableBy: string = '';
  /** 重复卡最后日期（yyyy-MM-dd；空/早于 dateText = 单日卡）：日程页在首日~末日闭区间每天显示 */
  repeatEndDate: string = '';
  /** 话题标签（≤5 个、每个 ≤12 字、不带 # 前缀；服务器 tags 字段，卡面正面展示） */
  tags: string[] = [];

  static of(id: string, title: string, kind: CardKind, status: CardStatus,
    timeText: string, place: string, symbol: string): TaskCard {
    const c = new TaskCard();
    c.id = id;
    c.title = title;
    c.kind = kind;
    c.status = status;
    c.timeText = timeText;
    c.place = place;
    c.symbol = symbol;
    return c;
  }

  cloneWithId(newId: string): TaskCard {
    const c = new TaskCard();
    c.id = newId;
    c.title = this.title;
    c.kind = this.kind;
    c.status = this.status;
    c.dateText = this.dateText;
    c.timeText = this.timeText;
    c.place = this.place;
    c.symbol = this.symbol;
    c.note = this.note;
    c.isRepeat = this.isRepeat;
    c.progress = this.progress;
    c.confirmText = this.confirmText;
    c.flipToken = this.flipToken;
    c.groupId = this.groupId;
    c.isOwner = this.isOwner;
    c.completableBy = this.completableBy;
    c.repeatEndDate = this.repeatEndDate;
    c.tags = this.tags.slice();
    return c;
  }
}

export class Project {
  id: string = '';
  name: string = '';
  emoji: string = '';
  intro: string = '';
  cards: TaskCard[] = [];

  static of(id: string, name: string, emoji: string, intro: string, cards: TaskCard[]): Project {
    const p = new Project();
    p.id = id;
    p.name = name;
    p.emoji = emoji;
    p.intro = intro;
    p.cards = cards;
    return p;
  }
}

export class ChatMsg {
  id: string = '';
  fromAI: boolean = true;
  text: string = '';
  chips: string[] = [];

  static of(id: string, fromAI: boolean, text: string, chips: string[]): ChatMsg {
    const m = new ChatMsg();
    m.id = id;
    m.fromAI = fromAI;
    m.text = text;
    m.chips = chips;
    return m;
  }
}

export class Friend {
  id: string = '';
  name: string = '';
  emoji: string = '';
  signature: string = '';
  freeText: string = '';
  isBusy: boolean = false;

  static of(id: string, name: string, emoji: string, signature: string, freeText: string,
    isBusy: boolean): Friend {
    const f = new Friend();
    f.id = id;
    f.name = name;
    f.emoji = emoji;
    f.signature = signature;
    f.freeText = freeText;
    f.isBusy = isBusy;
    return f;
  }
}

export class Group {
  id: string = '';
  name: string = '';
  emoji: string = '';
  memberNames: string[] = [];
  syncText: string = '';
  tasks: TaskCard[] = [];
  /** 后端协作卡（FRIEND_TASK）的卡片 ID，0 表示 mock 群组 */
  cardId: number = 0;
  isOwner: boolean = false;
  status: string = '';

  static of(id: string, name: string, emoji: string, memberNames: string[],
    syncText: string, tasks: TaskCard[]): Group {
    const g = new Group();
    g.id = id;
    g.name = name;
    g.emoji = emoji;
    g.memberNames = memberNames;
    g.syncText = syncText;
    g.tasks = tasks;
    return g;
  }

  static fromBackend(cardId: number, name: string, emoji: string, memberNames: string[],
    syncText: string, tasks: TaskCard[], isOwner: boolean, status: string): Group {
    const g = new Group();
    g.id = `ft-${cardId}`;
    g.cardId = cardId;
    g.name = name;
    g.emoji = emoji;
    g.memberNames = memberNames;
    g.syncText = syncText;
    g.tasks = tasks;
    g.isOwner = isOwner;
    g.status = status;
    return g;
  }
}

export class Activity {
  id: string = '';
  title: string = '';
  tag: string = '';
  hostName: string = '';
  hostIsFriend: boolean = false;
  /** 创建者账号（公开卡=组创建者账号；小铺 AI 推荐卡为空串） */
  hostAccount: string = '';
  timeText: string = '';
  place: string = '';
  emoji: string = '';
  joined: boolean = false;
  /** 已提交加入申请、等待创建者确认（后端 confirmStatus=PENDING） */
  pending: boolean = false;
  capacity: number = 0;
  currentCount: number = 0;
  conflictFree: boolean = false;
  /** 活动时间已过（endMomentOf 解析的结束时刻早于现在） */
  ended: boolean = false;
  /** 组简介 / 目标受众（服务 105 创建者设置，公开招募展示；空 = 未填写） */
  groupIntro: string = '';
  groupAudience: string = '';
  /** 所属组号（公开卡 = 卡片组号；发现页封面缓存按组拉取用） */
  groupId: number = 0;
  /** 组封面（105 上传 / 112 拉取后落本地缓存）：groupCoverUri 为缓存文件 file:// URI（空 = 无封面/未缓存） */
  groupCoverUri: string = '';
  groupHasCover: boolean = false;
  groupCoverUpdatedAt: string = '';
  /** 所属组加入模式（106 创建者设置）：open=自由加入 / review=审核加入 */
  groupJoinMode: string = 'open';
  /** 我已提交该组的入组申请、等待创建者审批（107 提交，109/110 处理，111 撤回） */
  groupJoinApplied: boolean = false;
  /** 我在该组的服务器角色（owner=创建者 / member=成员 / 空串=非成员），审核组按此放行成员直进 */
  groupRole: string = '';
  /** 话题标签（≤5 个、每个 ≤12 字、不带 # 前缀；发现页 # 搜索与推荐排序用） */
  tags: string[] = [];
  /** 原始 time 字段（'yyyy-MM-dd HH:mm[~…]'；招募中时间筛选用） */
  rawTime: string = '';
  /** 封面渐变索引（创建时按卡片标识随机定色，Theme 六款渐变取模） */
  colorIndex: number = 0;
  /** 卡片类型标签（work/task/activity/routine；四维度筛选用，空=未设置） */
  type: string = '';
  /** 场地标签（indoor/outdoor/anywhere；四维度筛选用，空=未设置） */
  scene: string = '';
  /** 主题标签（academic/sports/entertainment/social/creative/life；四维度筛选用，空=未设置） */
  theme: string = '';
  /** 时段归类（morning/afternoon/night，按 rawTime 开始时刻推导；空=无有效时间） */
  daySlot: string = '';

  static of(id: string, title: string, tag: string, hostName: string, hostIsFriend: boolean,
    timeText: string, place: string, emoji: string, joined: boolean, capacity: number,
    currentCount: number, conflictFree: boolean): Activity {
    const a = new Activity();
    a.id = id;
    a.title = title;
    a.tag = tag;
    a.hostName = hostName;
    a.hostIsFriend = hostIsFriend;
    a.timeText = timeText;
    a.place = place;
    a.emoji = emoji;
    a.joined = joined;
    a.capacity = capacity;
    a.currentCount = currentCount;
    a.conflictFree = conflictFree;
    return a;
  }

  cloneWithId(newId: string): Activity {
    const a = new Activity();
    a.id = newId;
    a.title = this.title;
    a.tag = this.tag;
    a.hostName = this.hostName;
    a.hostIsFriend = this.hostIsFriend;
    a.hostAccount = this.hostAccount;
    a.timeText = this.timeText;
    a.place = this.place;
    a.emoji = this.emoji;
    a.joined = this.joined;
    a.pending = this.pending;
    a.capacity = this.capacity;
    a.currentCount = this.currentCount;
    a.conflictFree = this.conflictFree;
    a.ended = this.ended;
    a.groupIntro = this.groupIntro;
    a.groupAudience = this.groupAudience;
    a.groupId = this.groupId;
    a.groupCoverUri = this.groupCoverUri;
    a.groupHasCover = this.groupHasCover;
    a.groupCoverUpdatedAt = this.groupCoverUpdatedAt;
    a.groupJoinMode = this.groupJoinMode;
    a.groupJoinApplied = this.groupJoinApplied;
    a.groupRole = this.groupRole;
    a.tags = this.tags.slice();
    a.rawTime = this.rawTime;
    a.colorIndex = this.colorIndex;
    a.type = this.type;
    a.scene = this.scene;
    a.theme = this.theme;
    a.daySlot = this.daySlot;
    return a;
  }
}

export enum InboxGroup {
  Notice = 0,
  Report = 1,
  System = 2
}

export class InboxItem {
  id: string = '';
  group: InboxGroup = InboxGroup.Notice;
  title: string = '';
  summary: string = '';
  timeText: string = '';
  icon: string = '🔔';
  read: boolean = false;
  detail: string = '';

  static of(id: string, group: InboxGroup, title: string, summary: string,
    timeText: string, icon: string, read: boolean, detail: string): InboxItem {
    const i = new InboxItem();
    i.id = id;
    i.group = group;
    i.title = title;
    i.summary = summary;
    i.timeText = timeText;
    i.icon = icon;
    i.read = read;
    i.detail = detail;
    return i;
  }

  cloneWithId(newId: string): InboxItem {
    const i = new InboxItem();
    i.id = newId;
    i.group = this.group;
    i.title = this.title;
    i.summary = this.summary;
    i.timeText = this.timeText;
    i.icon = this.icon;
    i.read = this.read;
    i.detail = this.detail;
    return i;
  }
}

export class Postcard {
  id: string = '';
  dateText: string = '';
  title: string = '';
  blessing: string = '';
  gradientIndex: number = 0;
  emoji: string = '💌';
  /** 生成当天天气现象（如 晴/多云，随明信片保存；服务器记录由端侧按日期映射补存） */
  weatherText: string = '';
  /** 生成当天天气图标 emoji（如 ☀️，随明信片保存） */
  weatherEmoji: string = '';
  /** 关联群号（0 = 无群/本地单人卡；明信片上滑查看群聊记录用） */
  groupId: number = 0;
  /** 关联群名（群可能已被删除，仅作展示兜底） */
  groupName: string = '';

  static of(id: string, dateText: string, title: string, blessing: string,
    gradientIndex: number, emoji: string, weatherText: string = '', weatherEmoji: string = '',
    groupId: number = 0, groupName: string = ''): Postcard {
    const p = new Postcard();
    p.id = id;
    p.dateText = dateText;
    p.title = title;
    p.blessing = blessing;
    p.gradientIndex = gradientIndex;
    p.emoji = emoji;
    p.weatherText = weatherText;
    p.weatherEmoji = weatherEmoji;
    p.groupId = groupId;
    p.groupName = groupName;
    return p;
  }

  /** 左上角日期行：日期 + 生成当天天气（如「10月3日 ·晴☁️」；无天气仅日期） */
  dateLine(): string {
    if (this.weatherText.length === 0) {
      return this.dateText;
    }
    return `${this.dateText} ·${this.weatherText}${this.weatherEmoji}`;
  }
}

export class CalendarDay {
  day: number = 0;
  inMonth: boolean = true;
  isToday: boolean = false;
  hasEvent: boolean = false;
  hasPostcard: boolean = false;
  dateText: string = '';

  static of(day: number, inMonth: boolean, isToday: boolean, hasEvent: boolean,
    hasPostcard: boolean, dateText: string): CalendarDay {
    const d = new CalendarDay();
    d.day = day;
    d.inMonth = inMonth;
    d.isToday = isToday;
    d.hasEvent = hasEvent;
    d.hasPostcard = hasPostcard;
    d.dateText = dateText;
    return d;
  }
}

/** 服务器协作卡视图（好友页群组卡）：我创建/加入的卡片组（公开协作 + 私人卡） */
export class CollabCard {
  /** 服务器卡片槽位：组内编号 1-10（PRO MAX 组模型） */
  index: number = 0;
  /** public=公开协作卡 private=私人卡 */
  library: string = 'public';
  /** PRO MAX 服务器卡片组定位：groupId + index 联合定位一张卡 */
  groupId: number = 0;
  groupName: string = '';
  title: string = '';
  timeText: string = '';
  place: string = '';
  initiator: string = '';
  participants: string[] = [];
  capacity: number = 1;
  count: number = 1;
  friendOnly: boolean = false;
  needApproval: boolean = false;
  isOwner: boolean = false;
  /** 被创建者指定「完成权限」的成员账号（空 = 未指定） */
  completableBy: string = '';
  /** 服务器侧已完成（归档展示，不再提醒） */
  completed: boolean = false;
  /** 话题标签（≤5 个、每个 ≤12 字、不带 # 前缀；好友页协作卡卡面展示） */
  tags: string[] = [];

  static of(index: number, library: string, title: string, timeText: string, place: string,
    initiator: string, participants: string[], capacity: number, count: number,
    friendOnly: boolean, needApproval: boolean, isOwner: boolean): CollabCard {
    const c = new CollabCard();
    c.index = index;
    c.library = library;
    c.title = title;
    c.timeText = timeText;
    c.place = place;
    c.initiator = initiator;
    c.participants = participants;
    c.capacity = capacity;
    c.count = count;
    c.friendOnly = friendOnly;
    c.needApproval = needApproval;
    c.isOwner = isOwner;
    return c;
  }
}
