/**
 * 服务器接口数据模型与解析工具。
 * 链路：App → client（后端网关 :4000）→ server（:3000），路由协议 POST /api/route/task
 *      { serviceId, token, payload } → { code, message, data: { serviceId, service, result } }，
 *      code === 0 表示成功；业务错误透传服务器原始状态码（400/403/404/409…）。
 * 注意：实例来自 JSON.parse 的类型断言，只有数据字段，不能定义实例方法；
 * 服务器响应里的 `public` 是 ArkTS 保留字，统一经 ServerMapper 从 Record 读取映射为 isPublic。
 */

/** 服务器统一响应外壳 */
export class ServerResp {
  code: number = -1;
  message: string = '';
  data: ServerTaskData | null = null;
}

/** 路由任务返回 data */
export class ServerTaskData {
  serviceId: number = 0;
  service: string = '';
  result: Object | null = null;
}

/** AI 流程状态（服务器 flowStatus）：state 0 收集信息 / 1 待确认 / 2 已定稿 */
export class ServerFlowStatus {
  state: number = 0;
  filled: boolean = false;
  confirmed: boolean = false;
}

/** 工作卡片快照（服务器 workingCard 转换后的 App 侧视图） */
export class WorkingCardInfo {
  hasContent: boolean = false;
  isPublic: boolean = false;
  friendOnly: boolean = false;
  needApproval: boolean = false;
  purpose: string = '';
  event: string = '';
  time: string = '';
  repeatTime: string = '';
  repeatUntil: string = '';
  location: string = '';
  participant: string = '';
  initiator: string = '';
  reminderTime: string = '';
  capacity: number = 1;
  count: number = 0;
  /** 三维度标签（隐藏元数据：卡片上不展示；积分计算/周报统计/推荐/筛选用；确定前必须三维度齐备） */
  type: string = '';
  scene: string = '';
  theme: string = '';
  /** 话题标签（≤5 个、每个 ≤12 字、不带 # 前缀；AI 自动提炼，卡面正面展示、发现页 # 搜索用） */
  tags: string[] = [];
}

/** 已写入卡片库的卡片（确定后 written；PRO MAX 服务器「确定」时自动建组收纳，附组号/组名） */
export class WrittenCardInfo {
  index: number = 0;
  /** 落库所在卡片组（服务器重做后 written.id = 组号；组内首卡编号恒为 1） */
  groupId: number = 0;
  groupName: string = '';
  isPublic: boolean = false;
  friendOnly: boolean = false;
  needApproval: boolean = false;
  purpose: string = '';
  event: string = '';
  time: string = '';
  repeatTime: string = '';
  repeatUntil: string = '';
  location: string = '';
  participant: string = '';
  reminderTime: string = '';
  initiator: string = '';
  capacity: number = 1;
  /** 被创建者指定「完成权限」的成员账号（空 = 未指定，创建者本人始终有权完成） */
  completableBy: string = '';
  count: number = 0;
  /** 话题标签（≤5 个、每个 ≤12 字、不带 # 前缀；卡面正面展示、发现页 # 搜索用） */
  tags: string[] = [];
}

/** 明信片库记录（客户端长期保存，data/postcards.txt）：完成卡片时由后端 AI 生成一句话正文，
 *  客户端落库；App 经 GET /api/postcards 读取、62 完成返回里顺带带回 */
export class PostcardRecordInfo {
  id: number = 0;
  account: string = '';
  userId: number = 0;
  groupId: number = 0;
  groupName: string = '';
  cardIndex: number = 0;
  event: string = '';
  /** 卡片计划时间（如 2026-10-03 19:00，可能为空） */
  time: string = '';
  /** AI 生成的一句话明信片正文（时间+事件+祝福） */
  text: string = '';
  model: string = '';
  /** 生成时刻（ISO 8601，明信片归属日期按它换算本地日期） */
  createdAt: string = '';
}

/** groups.complete-card（62）结果：客户端本地化后 = 服务器标记完成 + 后端 AI 顺带出稿明信片并落库
 *  + 出稿成功即把该卡从卡片组删除（归档为明信片，57）；AI 失败不影响完成（postcard 为 null） */
export class CompleteCardOutcome {
  ok: boolean = false;
  message: string = '';
  /** 后端 AI 生成并已存入客户端明信片库的记录（AI 未配置/失败时为 null） */
  postcard: PostcardRecordInfo | null = null;
  /** 明信片出稿后是否已把该卡从卡片组删除 */
  removedCard: boolean = false;
}

/** GET /api/postcards 结果：当前账号长期保存在客户端的全部明信片（新的在前） */
export class PostcardListOutcome {
  ok: boolean = false;
  message: string = '';
  account: string = '';
  total: number = 0;
  postcards: PostcardRecordInfo[] = [];
}

/** reports.week（74）结果：客户端周报库本地应答——本周窗口（周一 00:00 起，本地时区）与本周计数。
 *  设立数由服务器按周窗口计算快照；打卡/完成/延时由客户端在事件发生时累加；
 *  完成率 rate 由周报库落盘维护（完成数 / 本周已到期卡片并集，0-1 小数，null = 本周还没有到期卡片） */
export class WeekReportOutcome {
  ok: boolean = false;
  message: string = '';
  account: string = '';
  /** 本周周一 00:00（本地时区）毫秒时间戳 */
  weekStartMs: number = 0;
  /** 下周一 00:00 毫秒时间戳（展示周日 = weekStartMs + 6 天） */
  weekEndMs: number = 0;
  /** 本周设立卡片数 */
  setCount: number = 0;
  /** 本周打卡数 */
  checkinCount: number = 0;
  /** 本周完成数 */
  doneCount: number = 0;
  /** 本周延时数 */
  extendCount: number = 0;
  /** 本周完成率（周报库落盘值，0-1 小数；null = 本周还没有到期卡片，界面显示 —） */
  rate: number | null = null;
  /** 三维度标签 + 时段的累计计数（周报库累计视图 totals.tagCounts）：键 = day:morning /
   *  type:work / scene:indoor / theme:academic 等，值 = 归入该类的累计卡片数（只增不减） */
  tagCounts: Record<string, number> = {};
}

/** postcard.make（66）单独出稿结果：客户端本地化后返回 { generated, postcard }（生成内容 + 落库记录）。
 *  App 端完成卡片已改走 62（自动出稿并落库），66 保留作单独出稿入口 */
export class PostcardMakeOutcome {
  ok: boolean = false;
  message: string = '';
  groupId: number = 0;
  groupName: string = '';
  cardIndex: number = 0;
  event: string = '';
  time: string = '';
  /** AI 生成的一句话明信片正文 */
  text: string = '';
  createdAt: string = '';
  /** 客户端落库后的记录 id（0 = 未落库） */
  recordId: number = 0;
}

/** ai.ask 调用结果（App 侧视图） */
export class AskOutcome {
  ok: boolean = false;
  message: string = '';
  reply: string = '';
  /** 邀请/取消邀请等附加提示（服务器校验结果） */
  notes: string[] = [];
  working: WorkingCardInfo | null = null;
  flow: ServerFlowStatus | null = null;
  /** 非空表示本轮对话已自动写入卡片库（FINALIZE 阶段 + 提醒时间有效） */
  writtenCard: WrittenCardInfo | null = null;
}

/** 单条待拉取的参与者明信片（62 完成后服务器按快照出稿、经 103 投递给除发起者外的成员） */
export class PulledPostcardInfo {
  id: number = 0;
  groupId: number = 0;
  groupName: string = '';
  cardIndex: number = 0;
  event: string = '';
  time: string = '';
  text: string = '';
  model: string = '';
  /** 完成时刻（ISO 8601，明信片归属日期按它换算本地日期） */
  completedAt: string = '';
}

/** postcards.pull（103）结果：发给当前账号的参与者明信片（客户端落本地明信片库长期保存）
 *  + 待清理本地聊天记录的群号（未完成卡被删除 57 时的 clear 墓碑）；服务器侧均拉取即删 */
export class PostcardPullOutcome {
  ok: boolean = false;
  message: string = '';
  account: string = '';
  postcards: PulledPostcardInfo[] = [];
  clears: number[] = [];
}

/** ai.status 调用结果 */
export class StatusOutcome {
  ok: boolean = false;
  message: string = '';
  configured: boolean = false;
  lastReply: string = '';
  working: WorkingCardInfo | null = null;
  flow: ServerFlowStatus | null = null;
}

/** ai.reset / ai.visibility 调用结果 */
export class FlowOutcome {
  ok: boolean = false;
  message: string = '';
  working: WorkingCardInfo | null = null;
  flow: ServerFlowStatus | null = null;
}

/** ai.complete 调用结果 */
export class CompleteOutcome {
  ok: boolean = false;
  message: string = '';
  writtenCard: WrittenCardInfo | null = null;
}

/** cards.pick（76）调用结果：把一张已入库卡片整份载入「正在设置卡片」 */
export class PickOutcome {
  ok: boolean = false;
  message: string = '';
  working: WorkingCardInfo | null = null;
  flow: ServerFlowStatus | null = null;
  /** 被选取卡片的来源定位（服务器 source 字段） */
  sourceGroupId: number = 0;
  sourceGroupName: string = '';
  sourceCardIndex: number = 0;
  sourceLibrary: string = '';
}

/** 我的卡片库条目（groups.list 54 返回的组视图拍平：我创建的组 + 我加入的组，每卡一条） */
export class LibraryEntryInfo {
  library: string = 'private';
  /** 服务器卡片组定位：groupId + card.index 联合定位一张卡 */
  groupId: number = 0;
  groupName: string = '';
  /** 我在组内的角色：owner 创建者 / member 成员 */
  role: string = '';
  owner: string = '';
  isOwner: boolean = false;
  /** 服务器侧已完成（创建者标记完成并归档，不再提醒） */
  completed: boolean = false;
  card: WrittenCardInfo = new WrittenCardInfo();
  createdAt: string = '';
}

/** groups.list（54）的组级摘要（含空组）：好友页空卡片组也要展示（创建后才能往里加卡） */
export class LibraryGroupHead {
  library: string = 'private';
  /** 服务器卡片组定位 */
  groupId: number = 0;
  groupName: string = '';
  /** 我在组内的角色：owner 创建者 / member 成员 */
  role: string = '';
  owner: string = '';
  isOwner: boolean = false;
  memberCount: number = 0;
  cardCount: number = 0;
  /** 组加入模式（106 设置）：open=自由加入 / review=审核加入 */
  joinMode: string = 'open';
  /** 组简介 / 目标受众（服务 105 创建者设置，公开招募展示；空 = 未填写） */
  intro: string = '';
  audience: string = '';
  /** 组封面（105 上传 / 112 拉取）：hasCover=已设置封面，coverUpdatedAt 为服务器版本号 */
  hasCover: boolean = false;
  coverUpdatedAt: string = '';
  /** 组总人数上限（98 设置，含创建者）：0 = 不限，2~99 */
  memberCap: number = 0;
}

/** groups.list 调用结果（原 cards.private-list 37 已重做，54 = 我创建/加入的全部组） */
export class LibraryListOutcome {
  ok: boolean = false;
  message: string = '';
  account: string = '';
  /** 组级摘要（含空组，按服务器顺序） */
  heads: LibraryGroupHead[] = [];
  entries: LibraryEntryInfo[] = [];
}

/** groups.create（53）调用结果：服务器直接返回新建组视图（无 message 字段） */
export class GroupCreatedOutcome {
  ok: boolean = false;
  message: string = '';
  groupId: number = 0;
  groupName: string = '';
  /** public=公开卡片组库 private=私人卡片组库 */
  library: string = 'public';
  cardCount: number = 0;
}

/** ai.shop（89）推荐的一张小铺卡片（完整私人卡内容，由客户端按账号按周存本地小铺文件） */
export class ShopCardInfo {
  purpose: string = '';
  event: string = '';
  time: string = '';
  reminderTime: string = '';
  repeatTime: string = '';
  repeatUntil: string = '';
  location: string = '';
  /** 三维度标签（服务器已清洗为合法枚举，加入日程时随 56 上送） */
  type: string = '';
  scene: string = '';
  theme: string = '';
  /** 话题标签（≤5 个、每个 ≤12 字、不带 # 前缀；加入日程时随 56 上送） */
  tags: string[] = [];
}

/** ai.shop（89）调用结果：card 为 null 表示本次未取得有效推荐 */
export class ShopOutcome {
  ok: boolean = false;
  message: string = '';
  card: ShopCardInfo | null = null;
  model: string = '';
}

/** auth.login / auth.register 调用结果 */
export class AccountOutcome {
  ok: boolean = false;
  message: string = '';
  account: string = '';
  userId: number = 0;
  token: string = '';
}

/** auth.login-state（9，后端本地应答）：登录状态文件读取结果（0=未登录 / 1=已登录，含记录的账号密码） */
export class LoginStateOutcome {
  ok: boolean = false;
  message: string = '';
  state: number = 0;
  account: string = '';
  password: string = '';
}

/** auth.huawei-state（79）：当前账号的华为账号绑定状态（bound=已绑定，unionId 为绑定时上报的华为标识） */
export class HuaweiStateOutcome {
  ok: boolean = false;
  message: string = '';
  bound: boolean = false;
  unionId: string = '';
}

/** auth.email-state（95）：当前账号的邮箱绑定状态（emailBound=已绑定，email 为绑定邮箱，未绑定为空） */
export class EmailStateOutcome {
  ok: boolean = false;
  message: string = '';
  account: string = '';
  userId: number = 0;
  emailBound: boolean = false;
  email: string = '';
  hasPassword: boolean = false;
}

/** profile.get（90）：个人空间资料（服务器副本；客户端在 ProfileStore 另存一份本地副本）。
 *  found=false 表示服务器上从未保存过；withAvatar=true 且有头像时 avatarBase64 为纯 base64（JPEG） */
export class ProfileOutcome {
  ok: boolean = false;
  message: string = '';
  account: string = '';
  found: boolean = false;
  gender: string = '';
  birthday: string = '';
  signature: string = '';
  province: string = '';
  city: string = '';
  hasAvatar: boolean = false;
  avatarBase64: string = '';
  updatedAt: string = '';
}

/** profile.avatar（92）调用结果：按 targetAccount 查任意账号头像（好友列表头像用） */
export class AvatarOutcome {
  ok: boolean = false;
  message: string = '';
  account: string = '';
  found: boolean = false;
  hasAvatar: boolean = false;
  avatarBase64: string = '';
  updatedAt: string = '';
}

/** groups.cover（112）调用结果：按 groupId 查卡片组封面原图（发现页卡片封面用） */
export class GroupCoverOutcome {
  ok: boolean = false;
  message: string = '';
  found: boolean = false;
  hasCover: boolean = false;
  coverBase64: string = '';
  updatedAt: string = '';
}

/** 通用操作结果（加入/退出/删除/申请/审批/邀请等只有 message 的服务） */
export class MessageOutcome {
  ok: boolean = false;
  message: string = '';
}

/** 公开卡片组内的一张卡（cards.list 3 拍平，groupId + index 联合定位）：hasContent 恒真，friendOnly 卡由服务器过滤 */
export class CardSlotInfo {
  index: number = 0;
  groupId: number = 0;
  groupName: string = '';
  /** 组简介 / 目标受众（服务 105 创建者设置，公开招募展示；空 = 未填写） */
  groupIntro: string = '';
  groupAudience: string = '';
  /** 组封面（105 上传 / 112 拉取）：groupHasCover=已设置封面，groupCoverUpdatedAt 为服务器版本号 */
  groupHasCover: boolean = false;
  groupCoverUpdatedAt: string = '';
  hasContent: boolean = false;
  purpose: string = '';
  event: string = '';
  time: string = '';
  repeatTime: string = '';
  repeatUntil: string = '';
  location: string = '';
  participant: string = '';
  initiator: string = '';
  reminderTime: string = '';
  friendOnly: boolean = false;
  needApproval: boolean = false;
  capacity: number = 1;
  count: number = 0;
  /** 话题标签（≤5 个、每个 ≤12 字、不带 # 前缀；发现页 # 搜索与推荐排序用） */
  tags: string[] = [];
  /** 我已提交加入申请、等待发起者处理 */
  applied: boolean = false;
  /** 所属组加入模式（106 创建者设置）：open=自由加入 / review=审核加入 */
  groupJoinMode: string = 'open';
  /** 我已提交该组的入组申请、等待创建者审批（107 提交，111 撤回，109/110 处理） */
  groupJoinApplied: boolean = false;
  /** 我在该组的服务器角色（owner=创建者 / member=成员 / 空串=非成员），审核组按此放行成员直进 */
  groupRole: string = '';
  /** 卡片类型标签（work/task/activity/routine；发现页四维度筛选用，空=未设置） */
  type: string = '';
  /** 场地标签（indoor/outdoor/anywhere；空=未设置） */
  scene: string = '';
  /** 主题标签（academic/sports/entertainment/social/creative/life；空=未设置） */
  theme: string = '';
  createdAt: string = '';
}

/** cards.list 调用结果 */
export class CardListOutcome {
  ok: boolean = false;
  message: string = '';
  slots: CardSlotInfo[] = [];
}

/** 用户条目（users.list），state: none | friend | requested | incoming */
export class UserInfo {
  userId: number = 0;
  account: string = '';
  state: string = 'none';
}

/** users.list 调用结果 */
export class UsersListOutcome {
  ok: boolean = false;
  message: string = '';
  users: UserInfo[] = [];
}

/** 好友申请条目（friends.inbox 收到的待处理申请） */
export class FriendRequestInfo {
  id: number = 0;
  fromAccount: string = '';
  fromUserId: number = 0;
  toAccount: string = '';
  status: string = 'pending';
  createdAt: string = '';
}

/** 好友条目（关系库）；hasAvatar/avatarUpdatedAt 为头像摘要（92 按需拉取） */
export class FriendInfo {
  userId: number = 0;
  account: string = '';
  since: string = '';
  hasAvatar: boolean = false;
  avatarUpdatedAt: string = '';
}

/** friends.inbox 调用结果 */
export class FriendsInboxOutcome {
  ok: boolean = false;
  message: string = '';
  requests: FriendRequestInfo[] = [];
  friends: FriendInfo[] = [];
}

/** 卡片加入申请条目（cards.requests 26，groupId + cardIndex 定位组内卡片） */
export class CardRequestInfo {
  id: number = 0;
  groupId: number = 0;
  cardIndex: number = 0;
  fromAccount: string = '';
  createdAt: string = '';
}

/** cards.requests 调用结果 */
export class CardRequestsOutcome {
  ok: boolean = false;
  message: string = '';
  requests: CardRequestInfo[] = [];
}

/** 入组申请条目（groups.join-inbox 108，创建者收到的待审批申请） */
export class GroupJoinRequestInfo {
  id: number = 0;
  groupId: number = 0;
  groupName: string = '';
  fromAccount: string = '';
  /** 申请人填写的入组陈述（可空串） */
  statement: string = '';
  createdAt: string = '';
}

/** groups.join-inbox 调用结果 */
export class GroupJoinRequestsOutcome {
  ok: boolean = false;
  message: string = '';
  requests: GroupJoinRequestInfo[] = [];
}

/** 延时申请条目（cards.extend-requests 68）：组内被指定完成权限的成员向创建者提交的改期申请 */
export class ExtendRequestInfo {
  id: number = 0;
  groupId: number = 0;
  cardIndex: number = 0;
  fromAccount: string = '';
  /** 卡片标题快照（申请创建时的 event） */
  event: string = '';
  /** 申请的目标开始时间 "YYYY-MM-DD HH:mm" */
  targetTime: string = '';
  /** 申请的目标结束时间（无时段为空串） */
  targetEndTime: string = '';
  createdAt: string = '';
}

/** cards.extend-requests 调用结果 */
export class ExtendRequestsOutcome {
  ok: boolean = false;
  message: string = '';
  requests: ExtendRequestInfo[] = [];
}

/** cards.extend（67）调用结果：mode = applied 发起者立即改期 / requested 已生成延时申请待审批 */
export class CardExtendOutcome {
  ok: boolean = false;
  message: string = '';
  mode: string = '';
  /** applied：改期后的完整时间文本 */
  time: string = '';
}

/** cards.conflicts 调用结果（时间冲突描述列表） */
export class ConflictsOutcome {
  ok: boolean = false;
  message: string = '';
  descriptions: string[] = [];
}

/** 对话记录条目（conversations.list），direction: in = 我方发言 / out = AI 回复 */
export class ConversationMessageInfo {
  id: number = 0;
  direction: string = 'out';
  time: string = '';
  content: string = '';
  /** AI 生成合成内容隐式标识（GB 45438-2025）：仅 AI 回复携带，用户发言为空串 */
  aigcLabel: string = '';
}

/** conversations.list 调用结果（messages 已按旧 → 新排序） */
export class ConversationsOutcome {
  ok: boolean = false;
  message: string = '';
  messages: ConversationMessageInfo[] = [];
}

/** 聊天会话条目（chat.list 45：全部好友在列，没聊过的 lastAt=0） */
export class ChatConversationInfo {
  peer: string = '';
  userId: number = 0;
  unread: number = 0;
  total: number = 0;
  /** 最后一条消息时间（毫秒时间戳，0 = 还没聊过） */
  lastAt: number = 0;
  lastFromMe: boolean = false;
  /** text | card | group，没聊过为空串 */
  lastKind: string = '';
  lastSummary: string = '';
}

/** chat.list 调用结果 */
export class ChatListOutcome {
  ok: boolean = false;
  message: string = '';
  /** 全部会话合计未读数 */
  unread: number = 0;
  conversations: ChatConversationInfo[] = [];
}

/** 聊天消息条目（chat.messages 46）：kind = text 文字 / card 卡片邀请 / group 卡片组邀请 */
export class ChatMessageInfo {
  id: number = 0;
  fromAccount: string = '';
  toAccount: string = '';
  kind: string = 'text';
  text: string = '';
  /** kind=card：邀请的卡片在组内编号 */
  cardIndex: number = 0;
  /** kind=card/group：对应卡片组号 */
  groupId: number = 0;
  /** kind=card：发送时刻的卡片快照 */
  card: WrittenCardInfo | null = null;
  /** kind=group：发送时刻的卡片组快照 */
  groupName: string = '';
  groupCardCount: number = 0;
  /** 毫秒时间戳 */
  createdAt: number = 0;
  readAt: number = 0;
  /** >0 表示邀请已被接受 */
  acceptedAt: number = 0;
}

/** chat.messages 调用结果（messages 按时间正序；拉取时服务器已把对方未读消息标记已读） */
export class ChatMessagesOutcome {
  ok: boolean = false;
  message: string = '';
  messages: ChatMessageInfo[] = [];
}

/** 群聊花名册（group-chat.messages 102 返回的组视图：群 = 卡片组，成员 = 创建者 + 组成员，
 *  覆盖组内所有卡的参与者和发起者；memberCount 不含创建者，总人数 = memberCount + 1） */
export class GroupChatRosterInfo {
  id: number = 0;
  name: string = '';
  owner: string = '';
  library: string = 'public';
  members: string[] = [];
  memberCount: number = 0;
}

/** 群聊消息条目（group-chat 100/101/102）：kind = text 文字 / card 卡片分享。
 *  服务器只做短期中转（拉取即删），长期记录由客户端本地保存 */
export class GroupChatMessageInfo {
  id: number = 0;
  /** 本条消息所属群聊的组号 */
  groupId: number = 0;
  fromAccount: string = '';
  toAccount: string = '';
  kind: string = 'text';
  text: string = '';
  /** kind=card：被分享卡片在其组内编号 */
  cardIndex: number = 0;
  /** kind=card：被分享卡片所在的卡片组号（接受时按它走 14/25 加入链路） */
  cardGroupId: number = 0;
  /** kind=card：分享时刻的卡片快照 */
  card: WrittenCardInfo | null = null;
  /** 毫秒时间戳 */
  createdAt: number = 0;
  /** >0 表示我已本地接受（客户端本地字段，服务器中转不回传） */
  acceptedAt: number = 0;
  /** 我已提交加入申请、等待创建者确认（客户端本地字段） */
  applied: boolean = false;
}

/** group-chat.messages（102）调用结果：拉到的中转消息（服务器已删除）+ 组花名册 */
export class GroupChatPullOutcome {
  ok: boolean = false;
  message: string = '';
  /** 失败时的服务器/HTTP 错误码（0 = 成功；403/404 = 已非成员或群已删除） */
  code: number = 0;
  groupId: number = 0;
  group: GroupChatRosterInfo = new GroupChatRosterInfo();
  total: number = 0;
  messages: GroupChatMessageInfo[] = [];
}

/** group-chat.send-text（100）/ send-card（101）调用结果：sent 为发送回执，
 *  与各接收成员拉到的副本共用同一 id（客户端按 id 去重） */
export class GroupChatSendOutcome {
  ok: boolean = false;
  message: string = '';
  sent: GroupChatMessageInfo = new GroupChatMessageInfo();
}

/** 邮件条目（mailbox.list 42：日程提醒到点时服务器自动投递） */
export class MailInfo {
  id: number = 0;
  toAccount: string = '';
  fromAccount: string = '';
  title: string = '';
  body: string = '';
  /** 毫秒时间戳 */
  createdAt: number = 0;
  /** 毫秒时间戳，0 = 未读 */
  readAt: number = 0;
}

/** mailbox.list 调用结果（mails 新邮件在前） */
export class MailListOutcome {
  ok: boolean = false;
  message: string = '';
  unread: number = 0;
  mails: MailInfo[] = [];
}

/** 提醒条目（reminders.due 40 / reminders.upcoming 41：卡片按重复规则展开后的单次提醒） */
export class ReminderInfo {
  groupId: number = 0;
  groupName: string = '';
  cardIndex: number = 0;
  purpose: string = '';
  event: string = '';
  time: string = '';
  location: string = '';
  participant: string = '';
  /** 提醒时刻 'yyyy-MM-dd HH:mm' */
  remindAt: string = '';
  eventStart: string = '';
  eventEnd: string = '';
  /** 相对服务器当前时刻的分钟数（负数 = 已过去） */
  inMinutes: number = 0;
}

/** reminders.due / reminders.upcoming 调用结果（due 拉取即送达、同一条只返回一次；upcoming 仅预览不消耗） */
export class RemindersOutcome {
  ok: boolean = false;
  message: string = '';
  /** 仅 due：本次同步投递到收件箱的提醒邮件数 */
  mailSent: number = 0;
  /** 仅 upcoming：预览窗口小时数（168 = 7 天） */
  windowHours: number = 0;
  reminders: ReminderInfo[] = [];
}

/** 实况天气（weather.fetch 内 forecast.now） */
export class WeatherNowInfo {
  temp: string = '';
  text: string = '';
  icon: string = '';
  feelsLike: string = '';
  humidity: string = '';
  windDir: string = '';
  windScale: string = '';
  precip: string = '';
}

/** 逐日预报单日（weather.fetch 内 forecast.daily；sunrise/sunset/moonrise/moonset 为 HH:mm） */
export class WeatherDayInfo {
  fxDate: string = '';
  tempMax: string = '';
  tempMin: string = '';
  iconDay: string = '';
  textDay: string = '';
  sunrise: string = '';
  sunset: string = '';
  moonrise: string = '';
  moonset: string = '';
  moonPhase: string = '';
}

/** 逐小时预报单项（weather.fetch 内 forecast.hourly；fxTime 为 ISO） */
export class WeatherHourInfo {
  fxTime: string = '';
  temp: string = '';
  icon: string = '';
  text: string = '';
  pop: string = '';
}

/** 空气质量（weather.fetch 内 air，国标 cn-mee 项） */
export class WeatherAirInfo {
  aqi: string = '';
  category: string = '';
  level: string = '';
}

/** 生活指数单项（weather.fetch 内 indices，取运动/洗车/穿衣/紫外线） */
export class WeatherIndexInfo {
  type: string = '';
  name: string = '';
  category: string = '';
  text: string = '';
}

/** 气象预警（weather.fetch 内 warning） */
export class WeatherAlertInfo {
  title: string = '';
  description: string = '';
  startTime: string = '';
  endTime: string = '';
  severityColor: string = '';
}

/** weather.fetch（97）的调用结果（和风天气 8 产品聚合；内置后端天气快照同构复用） */
export class WeatherOutcome {
  ok: boolean = false;
  message: string = '';
  /** 快照来源账号（拉取结果为空串；快照读取时用于校验是否当前账号） */
  account: string = '';
  /** 定位到的区县与省市（如 江岸 / 湖北省 / 武汉） */
  name: string = '';
  adm1: string = '';
  adm2: string = '';
  lat: string = '';
  lon: string = '';
  fetchedAt: string = '';
  now: WeatherNowInfo | null = null;
  /** 分钟级降水摘要（如「未来两小时无降水」） */
  minutelySummary: string = '';
  days: WeatherDayInfo[] = [];
  hours: WeatherHourInfo[] = [];
  air: WeatherAirInfo | null = null;
  indices: WeatherIndexInfo[] = [];
  alerts: WeatherAlertInfo[] = [];
  /** 昨日实况（timeMachine.weatherDaily） */
  yesterdayMax: string = '';
  yesterdayMin: string = '';
}

/** ---------- 解析工具：服务器 JSON → App 侧模型 ---------- */

export class ServerMapper {
  /** 任意 JSON 对象 → Record；null 返回 null */
  static toRecord(raw: Object | null): Record<string, Object> | null {
    if (raw === null) {
      return null;
    }
    return raw as Record<string, Object>;
  }

  /** Record 读字符串字段，缺失返回空串 */
  static text(rec: Record<string, Object>, key: string): string {
    const value: Object | undefined = rec[key];
    if (value === undefined || value === null) {
      return '';
    }
    return `${value}`;
  }

  /** Record 读布尔字段，缺失返回 false */
  static flag(rec: Record<string, Object>, key: string): boolean {
    return rec[key] === true;
  }

  /** Record 读数字字段，缺失/非法返回兜底值 */
  static num(rec: Record<string, Object>, key: string, fallback: number): number {
    const value: Object | undefined = rec[key];
    if (value === undefined || value === null) {
      return fallback;
    }
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? fallback : parsed;
  }

  /** 服务器 flowStatus → ServerFlowStatus */
  static toFlow(raw: Object | null): ServerFlowStatus | null {
    const rec: Record<string, Object> | null = ServerMapper.toRecord(raw);
    if (rec === null) {
      return null;
    }
    const flow: ServerFlowStatus = new ServerFlowStatus();
    flow.state = ServerMapper.num(rec, 'state', 0);
    flow.filled = ServerMapper.flag(rec, 'filled');
    flow.confirmed = ServerMapper.flag(rec, 'confirmed');
    return flow;
  }

  /** 服务器 workingCard（含保留字 public）→ WorkingCardInfo */
  static toWorkingCard(raw: Object | null): WorkingCardInfo | null {
    const rec: Record<string, Object> | null = ServerMapper.toRecord(raw);
    if (rec === null) {
      return null;
    }
    const info: WorkingCardInfo = new WorkingCardInfo();
    info.isPublic = ServerMapper.flag(rec, 'public');
    info.friendOnly = ServerMapper.flag(rec, 'friendOnly');
    info.needApproval = ServerMapper.flag(rec, 'needApproval');
    const cardRec: Record<string, Object> | null = ServerMapper.toRecord(rec['card'] ?? null);
    if (cardRec !== null) {
      info.purpose = ServerMapper.text(cardRec, 'purpose');
      info.event = ServerMapper.text(cardRec, 'event');
      info.time = ServerMapper.text(cardRec, 'time');
      info.repeatTime = ServerMapper.text(cardRec, 'repeatTime');
      info.repeatUntil = ServerMapper.text(cardRec, 'repeatUntil');
      info.location = ServerMapper.text(cardRec, 'location');
      info.participant = ServerMapper.text(cardRec, 'participant');
      info.initiator = ServerMapper.text(cardRec, 'initiator');
      info.reminderTime = ServerMapper.text(cardRec, 'reminderTime');
      info.capacity = ServerMapper.num(cardRec, 'capacity', 1);
      info.count = ServerMapper.num(cardRec, 'count', 0);
      info.type = ServerMapper.text(cardRec, 'type');
      info.scene = ServerMapper.text(cardRec, 'scene');
      info.theme = ServerMapper.text(cardRec, 'theme');
      info.tags = ServerMapper.textList(cardRec, 'tags');
      info.hasContent = info.purpose.length > 0 || info.event.length > 0 || info.time.length > 0 ||
        info.repeatTime.length > 0 || info.repeatUntil.length > 0 || info.location.length > 0;
    }
    return info;
  }

  /** 服务器 written（PRO MAX：{ id: 组号, name: 组名, library, cardIndex: 组内编号, content: {...卡, public} }，
   *  确定按看板居中组落位：新建组首卡编号 1 / 追加进组为组内新编号 / 原位更新沿用原编号）→ WrittenCardInfo */
  static toWrittenCard(raw: Object | null): WrittenCardInfo | null {
    const rec: Record<string, Object> | null = ServerMapper.toRecord(raw);
    if (rec === null) {
      return null;
    }
    const card: WrittenCardInfo = new WrittenCardInfo();
    card.groupId = ServerMapper.num(rec, 'id', 0);
    card.groupName = ServerMapper.text(rec, 'name');
    card.index = ServerMapper.num(rec, 'cardIndex', 0);
    if (card.index === 0) {
      card.index = ServerMapper.num(rec, 'index', 0);
    }
    if (card.index === 0 && card.groupId > 0) {
      card.index = 1;
    }
    const libraryText: string = ServerMapper.text(rec, 'library');
    const contentRec: Record<string, Object> | null = ServerMapper.toRecord(rec['content'] ?? null);
    if (contentRec !== null) {
      card.isPublic = libraryText === 'public' ? true : (libraryText === 'private' ? false : ServerMapper.flag(contentRec, 'public'));
      card.friendOnly = ServerMapper.flag(contentRec, 'friendOnly');
      card.purpose = ServerMapper.text(contentRec, 'purpose');
      card.event = ServerMapper.text(contentRec, 'event');
      card.time = ServerMapper.text(contentRec, 'time');
      card.repeatTime = ServerMapper.text(contentRec, 'repeatTime');
      card.repeatUntil = ServerMapper.text(contentRec, 'repeatUntil');
      card.location = ServerMapper.text(contentRec, 'location');
      card.participant = ServerMapper.text(contentRec, 'participant');
      card.reminderTime = ServerMapper.text(contentRec, 'reminderTime');
      card.initiator = ServerMapper.text(contentRec, 'initiator');
      card.capacity = ServerMapper.num(contentRec, 'capacity', 1);
      card.needApproval = ServerMapper.flag(contentRec, 'needApproval');
      card.tags = ServerMapper.textList(contentRec, 'tags');
    }
    return card;
  }

  /** cards.pick（76）的 result → PickOutcome（ok/message 由网关填写） */
  static toPickOutcome(result: Object): PickOutcome {
    const outcome: PickOutcome = new PickOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.working = ServerMapper.toWorkingCard(rec['workingCard'] ?? null);
    outcome.flow = ServerMapper.toFlow(rec['flowStatus'] ?? null);
    const srcRec: Record<string, Object> | null = ServerMapper.toRecord(rec['source'] ?? null);
    if (srcRec !== null) {
      outcome.sourceGroupId = ServerMapper.num(srcRec, 'groupId', 0);
      outcome.sourceGroupName = ServerMapper.text(srcRec, 'groupName');
      outcome.sourceCardIndex = ServerMapper.num(srcRec, 'cardIndex', 0);
      outcome.sourceLibrary = ServerMapper.text(srcRec, 'library');
    }
    return outcome;
  }

  /** ai.ask 的 result → AskOutcome（ok/message 由网关填写） */
  static toAskOutcome(result: Object): AskOutcome {
    const outcome: AskOutcome = new AskOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const partsRec: Record<string, Object> | null = ServerMapper.toRecord(rec['parts'] ?? null);
    if (partsRec !== null) {
      outcome.reply = ServerMapper.text(partsRec, 'reply');
    }
    outcome.working = ServerMapper.toWorkingCard(rec['workingCard'] ?? null);
    outcome.flow = ServerMapper.toFlow(rec['flowStatus'] ?? null);
    outcome.writtenCard = ServerMapper.toWrittenCard(rec['written'] ?? null);
    const invited: string[] = ServerMapper.inviteNotes(rec, 'invited', true);
    const uninvited: string[] = ServerMapper.inviteNotes(rec, 'uninvited', false);
    outcome.notes = invited.concat(uninvited);
    return outcome;
  }

  /** 卡片组视图内的单卡（{ index, content, createdAt, completedAt… }）→ WrittenCardInfo（组信息由 toLibraryList 回填） */
  static toGroupCard(raw: Object): WrittenCardInfo | null {
    const rec: Record<string, Object> | null = ServerMapper.toRecord(raw);
    if (rec === null) {
      return null;
    }
    const card: WrittenCardInfo = new WrittenCardInfo();
    card.index = ServerMapper.num(rec, 'index', 0);
    card.completableBy = ServerMapper.text(rec, 'completableBy');
    const contentRec: Record<string, Object> | null = ServerMapper.toRecord(rec['content'] ?? null);
    if (contentRec !== null) {
      card.isPublic = ServerMapper.flag(contentRec, 'public');
      card.friendOnly = ServerMapper.flag(contentRec, 'friendOnly');
      card.purpose = ServerMapper.text(contentRec, 'purpose');
      card.event = ServerMapper.text(contentRec, 'event');
      card.time = ServerMapper.text(contentRec, 'time');
      card.repeatTime = ServerMapper.text(contentRec, 'repeatTime');
      card.repeatUntil = ServerMapper.text(contentRec, 'repeatUntil');
      card.location = ServerMapper.text(contentRec, 'location');
      card.participant = ServerMapper.text(contentRec, 'participant');
      card.reminderTime = ServerMapper.text(contentRec, 'reminderTime');
      card.initiator = ServerMapper.text(contentRec, 'initiator');
      card.capacity = ServerMapper.num(contentRec, 'capacity', 1);
      card.needApproval = ServerMapper.flag(contentRec, 'needApproval');
      card.tags = ServerMapper.textList(contentRec, 'tags');
    }
    return card;
  }

  /** postcard.make（66）result → PostcardMakeOutcome。客户端本地化后 result 形如 { generated, postcard }，
   *  兼容旧版平铺形状；text 为空视为失败 */
  static toPostcardMake(result: Object | null): PostcardMakeOutcome {
    const outcome: PostcardMakeOutcome = new PostcardMakeOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      outcome.message = '明信片生成失败';
      return outcome;
    }
    const innerRaw: Object = rec['postcard'] ?? rec['generated'] ?? rec;
    const inner: Record<string, Object> | null = ServerMapper.toRecord(innerRaw);
    if (inner === null) {
      outcome.message = '明信片生成失败';
      return outcome;
    }
    outcome.groupId = ServerMapper.num(inner, 'groupId', 0);
    outcome.groupName = ServerMapper.text(inner, 'groupName');
    outcome.cardIndex = ServerMapper.num(inner, 'cardIndex', 0);
    outcome.event = ServerMapper.text(inner, 'event');
    outcome.time = ServerMapper.text(inner, 'time');
    outcome.text = ServerMapper.text(inner, 'text');
    outcome.createdAt = ServerMapper.text(inner, 'createdAt');
    outcome.recordId = ServerMapper.num(inner, 'id', 0);
    outcome.ok = outcome.text.length > 0;
    if (!outcome.ok) {
      outcome.message = 'AI 未返回明信片正文';
    }
    return outcome;
  }

  /** 客户端明信片库单条记录 JSON → PostcardRecordInfo */
  static toPostcardRecord(raw: Object): PostcardRecordInfo {
    const rec: Record<string, Object> | null = ServerMapper.toRecord(raw);
    const r: PostcardRecordInfo = new PostcardRecordInfo();
    if (rec === null) {
      return r;
    }
    r.id = ServerMapper.num(rec, 'id', 0);
    r.account = ServerMapper.text(rec, 'account');
    r.userId = ServerMapper.num(rec, 'userId', 0);
    r.groupId = ServerMapper.num(rec, 'groupId', 0);
    r.groupName = ServerMapper.text(rec, 'groupName');
    r.cardIndex = ServerMapper.num(rec, 'cardIndex', 0);
    r.event = ServerMapper.text(rec, 'event');
    r.time = ServerMapper.text(rec, 'time');
    r.text = ServerMapper.text(rec, 'text');
    r.model = ServerMapper.text(rec, 'model');
    r.createdAt = ServerMapper.text(rec, 'createdAt');
    return r;
  }

  /** groups.complete-card（62）result（服务器完成结果 + 客户端附带的 postcard / removed）→ CompleteCardOutcome */
  static toCompleteCard(result: Object | null): CompleteCardOutcome {
    const outcome: CompleteCardOutcome = new CompleteCardOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      outcome.message = '完成返回数据异常';
      return outcome;
    }
    outcome.ok = true;
    outcome.message = ServerMapper.text(rec, 'message');
    const postcardRaw: Object | undefined = rec['postcard'];
    if (postcardRaw !== undefined && postcardRaw !== null) {
      const postcard: PostcardRecordInfo = ServerMapper.toPostcardRecord(postcardRaw);
      outcome.postcard = postcard.text.length > 0 ? postcard : null;
    }
    outcome.removedCard = rec['removed'] !== undefined && rec['removed'] !== null;
    return outcome;
  }

  /** GET /api/postcards 的 data（{ account, total, postcards: [...] }）→ PostcardListOutcome */
  static toPostcardList(data: Object | null): PostcardListOutcome {
    const outcome: PostcardListOutcome = new PostcardListOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(data);
    if (rec === null) {
      outcome.message = '明信片库返回数据异常';
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.total = ServerMapper.num(rec, 'total', 0);
    const raw: Object | undefined = rec['postcards'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const r: PostcardRecordInfo = ServerMapper.toPostcardRecord(list[i]);
      if (r.id > 0 && r.text.length > 0) {
        outcome.postcards.push(r);
      }
    }
    return outcome;
  }

  /** postcards.pull（103）result（{ account, postcards: [...], clears: [groupId, ...] }）→ PostcardPullOutcome */
  static toPostcardPull(result: Object | null): PostcardPullOutcome {
    const outcome: PostcardPullOutcome = new PostcardPullOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      outcome.message = '明信片拉取返回数据异常';
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    const rawPostcards: Object | undefined = rec['postcards'];
    if (rawPostcards !== undefined && rawPostcards !== null) {
      const list: Object[] = rawPostcards as Object[];
      for (let i = 0; i < list.length; i++) {
        const item: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
        if (item === null) {
          continue;
        }
        const pc: PulledPostcardInfo = new PulledPostcardInfo();
        pc.id = ServerMapper.num(item, 'id', 0);
        pc.groupId = ServerMapper.num(item, 'groupId', 0);
        pc.groupName = ServerMapper.text(item, 'groupName');
        pc.cardIndex = ServerMapper.num(item, 'cardIndex', 0);
        pc.event = ServerMapper.text(item, 'event');
        pc.time = ServerMapper.text(item, 'time');
        pc.text = ServerMapper.text(item, 'text');
        pc.model = ServerMapper.text(item, 'model');
        pc.completedAt = ServerMapper.text(item, 'completedAt');
        if (pc.id > 0 && pc.text.length > 0) {
          outcome.postcards.push(pc);
        }
      }
    }
    const rawClears: Object | undefined = rec['clears'];
    if (rawClears !== undefined && rawClears !== null) {
      const clears: Object[] = rawClears as Object[];
      for (let i = 0; i < clears.length; i++) {
        const gid: number = Number(clears[i]);
        if (Number.isInteger(gid) && gid > 0 && outcome.clears.indexOf(gid) < 0) {
          outcome.clears.push(gid);
        }
      }
    }
    return outcome;
  }

  /** reports.week（74）result（客户端周报库视图）→ WeekReportOutcome（本周窗口 + 本周四项计数）。
   *  weeks 里 current=true 的那条是本周；新账号还没有周报库记录时计数保持 0 */
  static toWeekReport(result: Object | null): WeekReportOutcome {
    const outcome: WeekReportOutcome = new WeekReportOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      outcome.message = '周报返回数据异常';
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    const weekRaw: Object | undefined = rec['currentWeek'];
    const week: Record<string, Object> | null = ServerMapper.toRecord(weekRaw === undefined ? null : weekRaw);
    if (week !== null) {
      outcome.weekStartMs = ServerMapper.num(week, 'weekStartMs', 0);
      outcome.weekEndMs = ServerMapper.num(week, 'weekEndMs', 0);
    }
    // 累计计数（totals.tagCounts）：三维度标签 + 时段，键 = day:morning / type:work 等，值 = 累计卡片数；
    // 放在 weeks 早退分支之前解析，保证新账号 / weeks 缺失时统计块也能拿到数据
    const totalsRaw: Object | undefined = rec['totals'];
    const totals: Record<string, Object> | null = ServerMapper.toRecord(totalsRaw === undefined ? null : totalsRaw);
    if (totals !== null) {
      const tagRaw: Object | undefined = totals['tagCounts'];
      const tagRec: Record<string, Object> | null = ServerMapper.toRecord(tagRaw === undefined ? null : tagRaw);
      if (tagRec !== null) {
        const tagKeys: string[] = Object.keys(tagRec);
        for (let i = 0; i < tagKeys.length; i++) {
          const n: number = Number(tagRec[tagKeys[i]]);
          if (Number.isFinite(n) && n > 0) {
            outcome.tagCounts[tagKeys[i]] = n;
          }
        }
      }
    }
    const weeksRaw: Object | undefined = rec['weeks'];
    if (weeksRaw === undefined || weeksRaw === null) {
      return outcome;
    }
    const weeks: Object[] = weeksRaw as Object[];
    for (let i = 0; i < weeks.length; i++) {
      const w: Record<string, Object> | null = ServerMapper.toRecord(weeks[i]);
      if (w === null || !ServerMapper.flag(w, 'current')) {
        continue;
      }
      outcome.setCount = ServerMapper.num(w, 'setCount', 0);
      outcome.checkinCount = ServerMapper.num(w, 'checkinCount', 0);
      outcome.doneCount = ServerMapper.num(w, 'doneCount', 0);
      outcome.extendCount = ServerMapper.num(w, 'extendCount', 0);
      // 完成率：周报库落盘值（0-1 小数）；null = 本周还没有到期卡片，保持 null 由界面显示 —
      if (w['rate'] !== undefined && w['rate'] !== null) {
        outcome.rate = ServerMapper.num(w, 'rate', 0);
      }
      break;
    }
    return outcome;
  }

  /** groups.list（54）的 result（{ account, total, groups: [组视图] }）→ 拍平成卡片条目（我创建的组 + 我加入的组，每卡一条） */
  static toLibraryList(result: Object): LibraryListOutcome {
    const outcome: LibraryListOutcome = new LibraryListOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.account = ServerMapper.text(rec, 'account');
    const raw: Object | undefined = rec['groups'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const groupList: Object[] = raw as Object[];
    for (let i = 0; i < groupList.length; i++) {
      const groupRec: Record<string, Object> | null = ServerMapper.toRecord(groupList[i]);
      if (groupRec === null) {
        continue;
      }
      const groupId: number = ServerMapper.num(groupRec, 'id', 0);
      const groupName: string = ServerMapper.text(groupRec, 'name');
      const owner: string = ServerMapper.text(groupRec, 'owner');
      const role: string = ServerMapper.text(groupRec, 'role');
      const library: string = ServerMapper.text(groupRec, 'library');
      const head: LibraryGroupHead = new LibraryGroupHead();
      head.library = library;
      head.groupId = groupId;
      head.groupName = groupName;
      head.owner = owner;
      head.role = role;
      head.isOwner = role === 'owner';
      head.memberCount = ServerMapper.num(groupRec, 'memberCount', 0);
      head.cardCount = ServerMapper.num(groupRec, 'cardCount', 0);
      const headJoinMode: string = ServerMapper.text(groupRec, 'joinMode');
      head.joinMode = headJoinMode.length > 0 ? headJoinMode : 'open';
      head.intro = ServerMapper.text(groupRec, 'intro');
      head.audience = ServerMapper.text(groupRec, 'audience');
      head.hasCover = ServerMapper.flag(groupRec, 'hasCover');
      head.coverUpdatedAt = ServerMapper.text(groupRec, 'coverUpdatedAt');
      head.memberCap = ServerMapper.num(groupRec, 'memberCap', 0);
      outcome.heads.push(head);
      const rawCards: Object | undefined = groupRec['cards'];
      if (rawCards === undefined || rawCards === null) {
        continue;
      }
      const cardList: Object[] = rawCards as Object[];
      for (let j = 0; j < cardList.length; j++) {
        const cardRec: Record<string, Object> | null = ServerMapper.toRecord(cardList[j]);
        const card: WrittenCardInfo | null = ServerMapper.toGroupCard(cardList[j]);
        if (card === null) {
          continue;
        }
        card.groupId = groupId;
        card.groupName = groupName;
        const entry: LibraryEntryInfo = new LibraryEntryInfo();
        entry.library = library;
        entry.groupId = groupId;
        entry.groupName = groupName;
        entry.owner = owner;
        entry.role = role;
        entry.isOwner = role === 'owner';
        entry.completed = cardRec !== null && ServerMapper.text(cardRec, 'completedAt').length > 0;
        entry.createdAt = cardRec !== null ? ServerMapper.text(cardRec, 'createdAt') : '';
        entry.card = card;
        outcome.entries.push(entry);
      }
    }
    return outcome;
  }

  /** groups.create（53）的 result（新建组视图：{ id, name, owner, role, library, members, cards… }）→ GroupCreatedOutcome */
  static toGroupCreated(result: Object): GroupCreatedOutcome {
    const outcome: GroupCreatedOutcome = new GroupCreatedOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.groupId = ServerMapper.num(rec, 'id', 0);
    outcome.groupName = ServerMapper.text(rec, 'name');
    outcome.library = ServerMapper.text(rec, 'library');
    outcome.cardCount = ServerMapper.num(rec, 'cardCount', 0);
    return outcome;
  }

  /** ai.shop（89）的 result（{ card: {…}, model }）→ ShopOutcome；card 缺失或事件/时间为空视为无效推荐 */
  static toShopOutcome(result: Object): ShopOutcome {
    const outcome: ShopOutcome = new ShopOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.model = ServerMapper.text(rec, 'model');
    const cardRec: Record<string, Object> | null = ServerMapper.toRecord(rec['card'] ?? null);
    if (cardRec === null) {
      return outcome;
    }
    const card: ShopCardInfo = new ShopCardInfo();
    card.purpose = ServerMapper.text(cardRec, 'purpose');
    card.event = ServerMapper.text(cardRec, 'event');
    card.time = ServerMapper.text(cardRec, 'time');
    card.reminderTime = ServerMapper.text(cardRec, 'reminderTime');
    card.repeatTime = ServerMapper.text(cardRec, 'repeatTime');
    card.repeatUntil = ServerMapper.text(cardRec, 'repeatUntil');
    card.location = ServerMapper.text(cardRec, 'location');
    card.type = ServerMapper.text(cardRec, 'type');
    card.scene = ServerMapper.text(cardRec, 'scene');
    card.theme = ServerMapper.text(cardRec, 'theme');
    card.tags = ServerMapper.textList(cardRec, 'tags');
    if (card.event.length === 0 || card.time.length === 0) {
      return outcome;
    }
    outcome.card = card;
    return outcome;
  }

  /** Record 读字符串数组字段，缺失返回空数组 */
  static textList(rec: Record<string, Object>, key: string): string[] {
    const list: string[] = [];
    const raw: Object | undefined = rec[key];
    if (raw === undefined || raw === null) {
      return list;
    }
    const arr: Object[] = raw as Object[];
    for (let i = 0; i < arr.length; i++) {
      list.push(`${arr[i]}`);
    }
    return list;
  }

  /** 公开卡片组内单卡（cards.list 3 组视图元素）→ CardSlotInfo；已完成归档卡返回 null（发现页不展示） */
  static toCardSlot(raw: Object, groupId: number, groupName: string, groupIntro: string, groupAudience: string,
    groupJoinMode: string = 'open', groupJoinApplied: boolean = false, groupRole: string = '',
    groupHasCover: boolean = false, groupCoverUpdatedAt: string = ''): CardSlotInfo | null {
    const rec: Record<string, Object> | null = ServerMapper.toRecord(raw);
    if (rec === null) {
      return null;
    }
    if (ServerMapper.text(rec, 'completedAt').length > 0) {
      return null;
    }
    const slot: CardSlotInfo = new CardSlotInfo();
    slot.index = ServerMapper.num(rec, 'index', 0);
    slot.groupId = groupId;
    slot.groupName = groupName;
    slot.groupIntro = groupIntro;
    slot.groupAudience = groupAudience;
    slot.groupHasCover = groupHasCover;
    slot.groupCoverUpdatedAt = groupCoverUpdatedAt;
    slot.groupJoinMode = groupJoinMode;
    slot.groupJoinApplied = groupJoinApplied;
    slot.groupRole = groupRole;
    slot.createdAt = ServerMapper.text(rec, 'createdAt');
    slot.applied = ServerMapper.flag(rec, 'applied');
    const contentRec: Record<string, Object> | null = ServerMapper.toRecord(rec['content'] ?? null);
    if (contentRec === null) {
      return slot;
    }
    slot.purpose = ServerMapper.text(contentRec, 'purpose');
    slot.event = ServerMapper.text(contentRec, 'event');
    slot.time = ServerMapper.text(contentRec, 'time');
    slot.repeatTime = ServerMapper.text(contentRec, 'repeatTime');
    slot.repeatUntil = ServerMapper.text(contentRec, 'repeatUntil');
    slot.location = ServerMapper.text(contentRec, 'location');
    slot.participant = ServerMapper.text(contentRec, 'participant');
    slot.initiator = ServerMapper.text(contentRec, 'initiator');
    slot.reminderTime = ServerMapper.text(contentRec, 'reminderTime');
    slot.friendOnly = ServerMapper.flag(contentRec, 'friendOnly');
    slot.needApproval = ServerMapper.flag(contentRec, 'needApproval');
    slot.capacity = ServerMapper.num(contentRec, 'capacity', 1);
    slot.count = ServerMapper.num(contentRec, 'count', 1);
    slot.tags = ServerMapper.textList(contentRec, 'tags');
    slot.type = ServerMapper.text(contentRec, 'type');
    slot.scene = ServerMapper.text(contentRec, 'scene');
    slot.theme = ServerMapper.text(contentRec, 'theme');
    slot.hasContent = slot.event.length > 0;
    return slot;
  }

  /** cards.list（3）的 result（{ groups: [公开组视图] }）→ 拍平成卡片列表（跳过已完成的归档卡） */
  static toCardList(result: Object): CardListOutcome {
    const outcome: CardListOutcome = new CardListOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const raw: Object | undefined = rec['groups'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const groupList: Object[] = raw as Object[];
    for (let i = 0; i < groupList.length; i++) {
      const groupRec: Record<string, Object> | null = ServerMapper.toRecord(groupList[i]);
      if (groupRec === null) {
        continue;
      }
      const groupId: number = ServerMapper.num(groupRec, 'id', 0);
      const groupName: string = ServerMapper.text(groupRec, 'name');
      const groupIntro: string = ServerMapper.text(groupRec, 'intro');
      const groupAudience: string = ServerMapper.text(groupRec, 'audience');
      const groupJoinMode: string = ServerMapper.text(groupRec, 'joinMode');
      const groupJoinApplied: boolean = ServerMapper.flag(groupRec, 'joinApplied');
      const groupRole: string = ServerMapper.text(groupRec, 'role');
      const groupHasCover: boolean = ServerMapper.flag(groupRec, 'hasCover');
      const groupCoverUpdatedAt: string = ServerMapper.text(groupRec, 'coverUpdatedAt');
      const rawCards: Object | undefined = groupRec['cards'];
      if (rawCards === undefined || rawCards === null) {
        continue;
      }
      const cardList: Object[] = rawCards as Object[];
      for (let j = 0; j < cardList.length; j++) {
        const slot: CardSlotInfo | null = ServerMapper.toCardSlot(cardList[j], groupId, groupName, groupIntro, groupAudience,
          groupJoinMode.length > 0 ? groupJoinMode : 'open', groupJoinApplied, groupRole, groupHasCover, groupCoverUpdatedAt);
        if (slot !== null) {
          outcome.slots.push(slot);
        }
      }
    }
    return outcome;
  }

  /** users.list 的 result → UsersListOutcome */
  static toUsersList(result: Object): UsersListOutcome {
    const outcome: UsersListOutcome = new UsersListOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const raw: Object | undefined = rec['users'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const user: UserInfo = new UserInfo();
      user.userId = ServerMapper.num(itemRec, 'userId', 0);
      user.account = ServerMapper.text(itemRec, 'account');
      user.state = ServerMapper.text(itemRec, 'state');
      if (user.account.length > 0) {
        outcome.users.push(user);
      }
    }
    return outcome;
  }

  /** friends.inbox 的 result → FriendsInboxOutcome */
  static toFriendsInbox(result: Object): FriendsInboxOutcome {
    const outcome: FriendsInboxOutcome = new FriendsInboxOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const rawRequests: Object | undefined = rec['requests'];
    if (rawRequests !== undefined && rawRequests !== null) {
      const reqList: Object[] = rawRequests as Object[];
      for (let i = 0; i < reqList.length; i++) {
        const itemRec: Record<string, Object> | null = ServerMapper.toRecord(reqList[i]);
        if (itemRec === null) {
          continue;
        }
        const req: FriendRequestInfo = new FriendRequestInfo();
        req.id = ServerMapper.num(itemRec, 'id', 0);
        req.fromAccount = ServerMapper.text(itemRec, 'fromAccount');
        req.fromUserId = ServerMapper.num(itemRec, 'fromUserId', 0);
        req.toAccount = ServerMapper.text(itemRec, 'toAccount');
        req.status = ServerMapper.text(itemRec, 'status');
        req.createdAt = ServerMapper.text(itemRec, 'createdAt');
        if (req.fromAccount.length > 0) {
          outcome.requests.push(req);
        }
      }
    }
    const rawFriends: Object | undefined = rec['friends'];
    if (rawFriends !== undefined && rawFriends !== null) {
      const friendList: Object[] = rawFriends as Object[];
      for (let i = 0; i < friendList.length; i++) {
        const itemRec: Record<string, Object> | null = ServerMapper.toRecord(friendList[i]);
        if (itemRec === null) {
          continue;
        }
        const friend: FriendInfo = new FriendInfo();
        friend.userId = ServerMapper.num(itemRec, 'userId', 0);
        friend.account = ServerMapper.text(itemRec, 'account');
        friend.since = ServerMapper.text(itemRec, 'since');
        friend.hasAvatar = ServerMapper.flag(itemRec, 'hasAvatar');
        friend.avatarUpdatedAt = ServerMapper.text(itemRec, 'avatarUpdatedAt');
        if (friend.account.length > 0) {
          outcome.friends.push(friend);
        }
      }
    }
    return outcome;
  }

  /** cards.requests 的 result → CardRequestsOutcome */
  static toCardRequests(result: Object): CardRequestsOutcome {
    const outcome: CardRequestsOutcome = new CardRequestsOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const raw: Object | undefined = rec['requests'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const req: CardRequestInfo = new CardRequestInfo();
      req.id = ServerMapper.num(itemRec, 'id', 0);
      req.groupId = ServerMapper.num(itemRec, 'groupId', 0);
      req.cardIndex = ServerMapper.num(itemRec, 'cardIndex', 0);
      req.fromAccount = ServerMapper.text(itemRec, 'fromAccount');
      req.createdAt = ServerMapper.text(itemRec, 'createdAt');
      if (req.fromAccount.length > 0) {
        outcome.requests.push(req);
      }
    }
    return outcome;
  }

  /** cards.extend（67）的 result → CardExtendOutcome（applied：发起者立即改期 / requested：已生成延时申请） */
  static toCardExtend(result: Object): CardExtendOutcome {
    const outcome: CardExtendOutcome = new CardExtendOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.mode = ServerMapper.text(rec, 'mode');
    outcome.time = ServerMapper.text(rec, 'time');
    outcome.message = ServerMapper.text(rec, 'message');
    return outcome;
  }

  /** cards.extend-requests（68）的 result → ExtendRequestsOutcome */
  static toExtendRequests(result: Object): ExtendRequestsOutcome {
    const outcome: ExtendRequestsOutcome = new ExtendRequestsOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const raw: Object | undefined = rec['requests'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const req: ExtendRequestInfo = new ExtendRequestInfo();
      req.id = ServerMapper.num(itemRec, 'id', 0);
      req.groupId = ServerMapper.num(itemRec, 'groupId', 0);
      req.cardIndex = ServerMapper.num(itemRec, 'cardIndex', 0);
      req.fromAccount = ServerMapper.text(itemRec, 'fromAccount');
      req.event = ServerMapper.text(itemRec, 'event');
      req.targetTime = ServerMapper.text(itemRec, 'targetTime');
      req.targetEndTime = ServerMapper.text(itemRec, 'targetEndTime');
      req.createdAt = ServerMapper.text(itemRec, 'createdAt');
      if (req.fromAccount.length > 0) {
        outcome.requests.push(req);
      }
    }
    return outcome;
  }

  /** groups.join-requests（108）的 result → GroupJoinRequestsOutcome（别人申请加入我创建的组） */
  static toGroupJoins(result: Object): GroupJoinRequestsOutcome {
    const outcome: GroupJoinRequestsOutcome = new GroupJoinRequestsOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const raw: Object | undefined = rec['requests'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const req: GroupJoinRequestInfo = new GroupJoinRequestInfo();
      req.id = ServerMapper.num(itemRec, 'id', 0);
      req.groupId = ServerMapper.num(itemRec, 'groupId', 0);
      req.groupName = ServerMapper.text(itemRec, 'groupName');
      req.fromAccount = ServerMapper.text(itemRec, 'fromAccount');
      req.statement = ServerMapper.text(itemRec, 'statement');
      req.createdAt = ServerMapper.text(itemRec, 'createdAt');
      if (req.fromAccount.length > 0) {
        outcome.requests.push(req);
      }
    }
    return outcome;
  }

  /** cards.conflicts 的 result → ConflictsOutcome */
  static toConflicts(result: Object): ConflictsOutcome {
    const outcome: ConflictsOutcome = new ConflictsOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.descriptions = ServerMapper.textList(rec, 'descriptions');
    return outcome;
  }

  /** conversations.list 的 result → ConversationsOutcome（服务器新 → 旧，翻转为旧 → 新） */
  static toConversations(result: Object): ConversationsOutcome {
    const outcome: ConversationsOutcome = new ConversationsOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const raw: Object | undefined = rec['messages'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = list.length - 1; i >= 0; i--) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const msg: ConversationMessageInfo = new ConversationMessageInfo();
      msg.id = ServerMapper.num(itemRec, 'id', 0);
      msg.direction = ServerMapper.text(itemRec, 'direction');
      msg.time = ServerMapper.text(itemRec, 'time');
      msg.content = ServerMapper.text(itemRec, 'content');
      msg.aigcLabel = ServerMapper.text(itemRec, 'aigc_label');
      if (msg.content.length > 0) {
        outcome.messages.push(msg);
      }
    }
    return outcome;
  }

  /** invited / uninvited 数组（{ account, ok, already?, reason? }）→ 提示语列表 */
  static inviteNotes(rec: Record<string, Object>, key: string, invite: boolean): string[] {
    const notes: string[] = [];
    const raw: Object | undefined = rec[key];
    if (raw === undefined || raw === null) {
      return notes;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const account: string = ServerMapper.text(itemRec, 'account');
      if (account.length === 0) {
        continue;
      }
      const ok: boolean = ServerMapper.flag(itemRec, 'ok');
      if (ok) {
        const already: boolean = ServerMapper.flag(itemRec, 'already');
        notes.push(invite
          ? (already ? `${account} 已在参与人中` : `已邀请 ${account} 加入`)
          : `已把 ${account} 移出参与人`);
      } else {
        notes.push(`${invite ? '邀请' : '移出'} ${account} 失败：${ServerMapper.text(itemRec, 'reason')}`);
      }
    }
    return notes;
  }

  /** chat.list（45）的 result → ChatListOutcome（全部好友在列，没聊过的会话 lastAt=0） */
  static toChatList(result: Object): ChatListOutcome {
    const outcome: ChatListOutcome = new ChatListOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.unread = ServerMapper.num(rec, 'unread', 0);
    const raw: Object | undefined = rec['conversations'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const conv: ChatConversationInfo = new ChatConversationInfo();
      conv.peer = ServerMapper.text(itemRec, 'peer');
      conv.userId = ServerMapper.num(itemRec, 'userId', 0);
      conv.unread = ServerMapper.num(itemRec, 'unread', 0);
      conv.total = ServerMapper.num(itemRec, 'total', 0);
      conv.lastAt = ServerMapper.num(itemRec, 'lastAt', 0);
      conv.lastFromMe = ServerMapper.flag(itemRec, 'lastFromMe');
      conv.lastKind = ServerMapper.text(itemRec, 'lastKind');
      conv.lastSummary = ServerMapper.text(itemRec, 'lastSummary');
      if (conv.peer.length > 0) {
        outcome.conversations.push(conv);
      }
    }
    return outcome;
  }

  /** 聊天卡片邀请里的卡片快照（直接是卡面字段，无组包装）→ WrittenCardInfo */
  static toChatCardSnapshot(raw: Object | null): WrittenCardInfo | null {
    const rec: Record<string, Object> | null = ServerMapper.toRecord(raw);
    if (rec === null) {
      return null;
    }
    const card: WrittenCardInfo = new WrittenCardInfo();
    card.purpose = ServerMapper.text(rec, 'purpose');
    card.event = ServerMapper.text(rec, 'event');
    card.time = ServerMapper.text(rec, 'time');
    card.repeatTime = ServerMapper.text(rec, 'repeatTime');
    card.repeatUntil = ServerMapper.text(rec, 'repeatUntil');
    card.location = ServerMapper.text(rec, 'location');
    card.participant = ServerMapper.text(rec, 'participant');
    card.initiator = ServerMapper.text(rec, 'initiator');
    card.reminderTime = ServerMapper.text(rec, 'reminderTime');
    card.capacity = ServerMapper.num(rec, 'capacity', 1);
    card.needApproval = ServerMapper.flag(rec, 'needApproval');
    card.tags = ServerMapper.textList(rec, 'tags');
    return card;
  }

  /** chat.messages（46）的 result → ChatMessagesOutcome（按时间正序） */
  static toChatMessages(result: Object): ChatMessagesOutcome {
    const outcome: ChatMessagesOutcome = new ChatMessagesOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const raw: Object | undefined = rec['messages'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const msg: ChatMessageInfo = new ChatMessageInfo();
      msg.id = ServerMapper.num(itemRec, 'id', 0);
      msg.fromAccount = ServerMapper.text(itemRec, 'fromAccount');
      msg.toAccount = ServerMapper.text(itemRec, 'toAccount');
      msg.kind = ServerMapper.text(itemRec, 'kind');
      msg.text = ServerMapper.text(itemRec, 'text');
      msg.cardIndex = ServerMapper.num(itemRec, 'cardIndex', 0);
      msg.groupId = ServerMapper.num(itemRec, 'groupId', 0);
      msg.createdAt = ServerMapper.num(itemRec, 'createdAt', 0);
      msg.readAt = ServerMapper.num(itemRec, 'readAt', 0);
      msg.acceptedAt = ServerMapper.num(itemRec, 'acceptedAt', 0);
      const groupRec: Record<string, Object> | null = ServerMapper.toRecord(itemRec['group'] ?? null);
      if (groupRec !== null) {
        msg.groupName = ServerMapper.text(groupRec, 'name');
        msg.groupCardCount = ServerMapper.num(groupRec, 'cardCount', 0);
      }
      if (msg.kind === 'card') {
        msg.card = ServerMapper.toChatCardSnapshot(itemRec['card'] ?? null);
      }
      if (msg.id > 0) {
        outcome.messages.push(msg);
      }
    }
    return outcome;
  }

  /** 群聊消息记录（中转副本 / 发送回执 / 本地存储行同构）→ GroupChatMessageInfo */
  static toGroupChatMessage(rec: Record<string, Object>): GroupChatMessageInfo {
    const msg: GroupChatMessageInfo = new GroupChatMessageInfo();
    msg.id = ServerMapper.num(rec, 'id', 0);
    msg.groupId = ServerMapper.num(rec, 'groupId', 0);
    msg.fromAccount = ServerMapper.text(rec, 'fromAccount');
    msg.toAccount = ServerMapper.text(rec, 'toAccount');
    msg.kind = ServerMapper.text(rec, 'kind');
    msg.text = ServerMapper.text(rec, 'text');
    msg.cardIndex = ServerMapper.num(rec, 'cardIndex', 0);
    msg.cardGroupId = ServerMapper.num(rec, 'cardGroupId', 0);
    msg.createdAt = ServerMapper.num(rec, 'createdAt', 0);
    msg.acceptedAt = ServerMapper.num(rec, 'acceptedAt', 0);
    msg.applied = ServerMapper.flag(rec, 'applied');
    if (msg.kind === 'card') {
      msg.card = ServerMapper.toChatCardSnapshot(rec['card'] ?? null);
    }
    return msg;
  }

  /** group-chat.messages（102）的 result → GroupChatPullOutcome（花名册 = 创建者 + 全部成员） */
  static toGroupChatPull(result: Object): GroupChatPullOutcome {
    const outcome: GroupChatPullOutcome = new GroupChatPullOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.groupId = ServerMapper.num(rec, 'groupId', 0);
    outcome.total = ServerMapper.num(rec, 'total', 0);
    const groupRec: Record<string, Object> | null = ServerMapper.toRecord(rec['group'] ?? null);
    if (groupRec !== null) {
      outcome.group.id = ServerMapper.num(groupRec, 'id', 0);
      outcome.group.name = ServerMapper.text(groupRec, 'name');
      outcome.group.owner = ServerMapper.text(groupRec, 'owner');
      outcome.group.library = ServerMapper.text(groupRec, 'library');
      outcome.group.memberCount = ServerMapper.num(groupRec, 'memberCount', 0);
      const rawMembers: Object | undefined = groupRec['members'];
      if (rawMembers !== undefined && rawMembers !== null) {
        const arr: Object[] = rawMembers as Object[];
        for (let i = 0; i < arr.length; i++) {
          const name: string = typeof arr[i] === 'string' ? arr[i] as string : '';
          if (name.length > 0) {
            outcome.group.members.push(name);
          }
        }
      }
    }
    const raw: Object | undefined = rec['messages'];
    if (raw !== undefined && raw !== null) {
      const list: Object[] = raw as Object[];
      for (let i = 0; i < list.length; i++) {
        const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
        if (itemRec === null) {
          continue;
        }
        const msg: GroupChatMessageInfo = ServerMapper.toGroupChatMessage(itemRec);
        if (msg.id > 0) {
          outcome.messages.push(msg);
        }
      }
    }
    return outcome;
  }

  /** group-chat.send-text（100）/ send-card（101）的 result → GroupChatSendOutcome（sent = 回执消息核心） */
  static toGroupChatSend(result: Object): GroupChatSendOutcome {
    const outcome: GroupChatSendOutcome = new GroupChatSendOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.message = ServerMapper.text(rec, 'message');
    const sentRec: Record<string, Object> | null = ServerMapper.toRecord(rec['sent'] ?? null);
    if (sentRec !== null) {
      outcome.sent = ServerMapper.toGroupChatMessage(sentRec);
    }
    return outcome;
  }

  /** mailbox.list（42）的 result → MailListOutcome（mails 服务器已按新邮件在前返回） */
  static toMailList(result: Object): MailListOutcome {
    const outcome: MailListOutcome = new MailListOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.unread = ServerMapper.num(rec, 'unread', 0);
    const raw: Object | undefined = rec['mails'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const mail: MailInfo = new MailInfo();
      mail.id = ServerMapper.num(itemRec, 'id', 0);
      mail.toAccount = ServerMapper.text(itemRec, 'toAccount');
      mail.fromAccount = ServerMapper.text(itemRec, 'fromAccount');
      mail.title = ServerMapper.text(itemRec, 'title');
      mail.body = ServerMapper.text(itemRec, 'body');
      mail.createdAt = ServerMapper.num(itemRec, 'createdAt', 0);
      mail.readAt = ServerMapper.num(itemRec, 'readAt', 0);
      if (mail.id > 0) {
        outcome.mails.push(mail);
      }
    }
    return outcome;
  }

  /** reminders.due（40）/ reminders.upcoming（41）的 result → RemindersOutcome */
  static toReminders(result: Object): RemindersOutcome {
    const outcome: RemindersOutcome = new RemindersOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    const mailRec: Record<string, Object> | null = ServerMapper.toRecord(rec['mail'] ?? null);
    if (mailRec !== null) {
      outcome.mailSent = ServerMapper.num(mailRec, 'sent', 0);
    }
    outcome.windowHours = ServerMapper.num(rec, 'windowHours', 0);
    const raw: Object | undefined = rec['reminders'];
    if (raw === undefined || raw === null) {
      return outcome;
    }
    const list: Object[] = raw as Object[];
    for (let i = 0; i < list.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(list[i]);
      if (itemRec === null) {
        continue;
      }
      const rem: ReminderInfo = new ReminderInfo();
      rem.groupId = ServerMapper.num(itemRec, 'groupId', 0);
      rem.groupName = ServerMapper.text(itemRec, 'groupName');
      rem.cardIndex = ServerMapper.num(itemRec, 'cardIndex', 0);
      rem.purpose = ServerMapper.text(itemRec, 'purpose');
      rem.event = ServerMapper.text(itemRec, 'event');
      rem.time = ServerMapper.text(itemRec, 'time');
      rem.location = ServerMapper.text(itemRec, 'location');
      rem.participant = ServerMapper.text(itemRec, 'participant');
      rem.remindAt = ServerMapper.text(itemRec, 'remindAt');
      rem.eventStart = ServerMapper.text(itemRec, 'eventStart');
      rem.eventEnd = ServerMapper.text(itemRec, 'eventEnd');
      rem.inMinutes = ServerMapper.num(itemRec, 'inMinutes', 0);
      outcome.reminders.push(rem);
    }
    return outcome;
  }

  /** weather.fetch（97）的 result / 本地天气快照记录（{ location, weather, fetchedAt }）→ WeatherOutcome */
  static toWeather(raw: Object): WeatherOutcome {
    const outcome: WeatherOutcome = new WeatherOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(raw);
    if (rec === null) {
      return outcome;
    }
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.fetchedAt = ServerMapper.text(rec, 'fetchedAt');
    const locRec: Record<string, Object> | null = ServerMapper.toRecord(rec['location'] ?? null);
    if (locRec !== null) {
      outcome.name = ServerMapper.text(locRec, 'name');
      outcome.adm1 = ServerMapper.text(locRec, 'adm1');
      outcome.adm2 = ServerMapper.text(locRec, 'adm2');
      outcome.lat = ServerMapper.text(locRec, 'lat');
      outcome.lon = ServerMapper.text(locRec, 'lon');
    }
    const weatherRec: Record<string, Object> | null = ServerMapper.toRecord(rec['weather'] ?? null);
    if (weatherRec === null) {
      return outcome;
    }
    const forecastRec: Record<string, Object> | null = ServerMapper.toRecord(weatherRec['forecast'] ?? null);
    // 实况
    const nowData: Record<string, Object> | null = ServerMapper.productData(forecastRec, 'now');
    const nowRec: Record<string, Object> | null = ServerMapper.toRecord(nowData === null ? null : nowData['now']);
    if (nowRec !== null) {
      const now: WeatherNowInfo = new WeatherNowInfo();
      now.temp = ServerMapper.text(nowRec, 'temp');
      now.text = ServerMapper.text(nowRec, 'text');
      now.icon = ServerMapper.text(nowRec, 'icon');
      now.feelsLike = ServerMapper.text(nowRec, 'feelsLike');
      now.humidity = ServerMapper.text(nowRec, 'humidity');
      now.windDir = ServerMapper.text(nowRec, 'windDir');
      now.windScale = ServerMapper.text(nowRec, 'windScale');
      now.precip = ServerMapper.text(nowRec, 'precip');
      outcome.now = now;
    }
    // 3 日预报（含日出日落月相）
    const dailyData: Record<string, Object> | null = ServerMapper.productData(forecastRec, 'daily');
    const dailyList: Object[] = ServerMapper.listIn(dailyData, 'daily');
    for (let i = 0; i < dailyList.length; i++) {
      const dayRec: Record<string, Object> | null = ServerMapper.toRecord(dailyList[i]);
      if (dayRec === null) {
        continue;
      }
      const day: WeatherDayInfo = new WeatherDayInfo();
      day.fxDate = ServerMapper.text(dayRec, 'fxDate');
      day.tempMax = ServerMapper.text(dayRec, 'tempMax');
      day.tempMin = ServerMapper.text(dayRec, 'tempMin');
      day.iconDay = ServerMapper.text(dayRec, 'iconDay');
      day.textDay = ServerMapper.text(dayRec, 'textDay');
      day.sunrise = ServerMapper.text(dayRec, 'sunrise');
      day.sunset = ServerMapper.text(dayRec, 'sunset');
      day.moonrise = ServerMapper.text(dayRec, 'moonrise');
      day.moonset = ServerMapper.text(dayRec, 'moonset');
      day.moonPhase = ServerMapper.text(dayRec, 'moonPhase');
      outcome.days.push(day);
    }
    // 24 小时预报
    const hourlyData: Record<string, Object> | null = ServerMapper.productData(forecastRec, 'hourly');
    const hourlyList: Object[] = ServerMapper.listIn(hourlyData, 'hourly');
    for (let i = 0; i < hourlyList.length; i++) {
      const hourRec: Record<string, Object> | null = ServerMapper.toRecord(hourlyList[i]);
      if (hourRec === null) {
        continue;
      }
      const hour: WeatherHourInfo = new WeatherHourInfo();
      hour.fxTime = ServerMapper.text(hourRec, 'fxTime');
      hour.temp = ServerMapper.text(hourRec, 'temp');
      hour.icon = ServerMapper.text(hourRec, 'icon');
      hour.text = ServerMapper.text(hourRec, 'text');
      hour.pop = ServerMapper.text(hourRec, 'pop');
      outcome.hours.push(hour);
    }
    // 分钟级降水摘要
    const minutelyData: Record<string, Object> | null = ServerMapper.productData(weatherRec, 'minutely');
    outcome.minutelySummary = minutelyData !== null ? ServerMapper.text(minutelyData, 'summary') : '';
    // 空气质量（国标 cn-mee 项优先，无则取第一项）
    const airData: Record<string, Object> | null = ServerMapper.productData(weatherRec, 'air');
    const airList: Object[] = ServerMapper.listIn(airData, 'indexes');
    let airPicked: Record<string, Object> | null = null;
    for (let i = 0; i < airList.length; i++) {
      const idxRec: Record<string, Object> | null = ServerMapper.toRecord(airList[i]);
      if (idxRec === null) {
        continue;
      }
      if (ServerMapper.text(idxRec, 'code') === 'cn-mee') {
        airPicked = idxRec;
        break;
      }
      if (airPicked === null) {
        airPicked = idxRec;
      }
    }
    if (airPicked !== null) {
      const air: WeatherAirInfo = new WeatherAirInfo();
      air.aqi = ServerMapper.text(airPicked, 'aqiDisplay');
      if (air.aqi.length === 0) {
        air.aqi = `${ServerMapper.num(airPicked, 'aqi', 0)}`;
      }
      air.category = ServerMapper.text(airPicked, 'category');
      air.level = ServerMapper.text(airPicked, 'level');
      outcome.air = air;
    }
    // 生活指数（16 项里取运动/洗车/穿衣/紫外线）
    const wanted: string[] = ['1', '2', '3', '5'];
    const indicesData: Record<string, Object> | null = ServerMapper.productData(weatherRec, 'indices');
    const idxDaily: Object[] = ServerMapper.listIn(indicesData, 'daily');
    for (let i = 0; i < idxDaily.length; i++) {
      const itemRec: Record<string, Object> | null = ServerMapper.toRecord(idxDaily[i]);
      if (itemRec === null) {
        continue;
      }
      const type: string = ServerMapper.text(itemRec, 'type');
      if (wanted.indexOf(type) < 0) {
        continue;
      }
      const item: WeatherIndexInfo = new WeatherIndexInfo();
      item.type = type;
      item.name = ServerMapper.trimIndexName(ServerMapper.text(itemRec, 'name'));
      item.category = ServerMapper.text(itemRec, 'category');
      item.text = ServerMapper.text(itemRec, 'text');
      outcome.indices.push(item);
    }
    // 气象预警
    const warningData: Record<string, Object> | null = ServerMapper.productData(weatherRec, 'warning');
    const alertList: Object[] = ServerMapper.listIn(warningData, 'alerts');
    for (let i = 0; i < alertList.length; i++) {
      const alertRec: Record<string, Object> | null = ServerMapper.toRecord(alertList[i]);
      if (alertRec === null) {
        continue;
      }
      const alert: WeatherAlertInfo = new WeatherAlertInfo();
      alert.title = ServerMapper.text(alertRec, 'title');
      alert.description = ServerMapper.text(alertRec, 'description');
      alert.startTime = ServerMapper.text(alertRec, 'startTime');
      alert.endTime = ServerMapper.text(alertRec, 'endTime');
      alert.severityColor = ServerMapper.text(alertRec, 'severityColor');
      if (alert.title.length > 0) {
        outcome.alerts.push(alert);
      }
    }
    // 昨日实况（timeMachine.weatherDaily）
    const tmData: Record<string, Object> | null = ServerMapper.productData(weatherRec, 'timeMachine');
    const tmDaily: Record<string, Object> | null = ServerMapper.toRecord(tmData === null ? null : tmData['weatherDaily']);
    if (tmDaily !== null) {
      outcome.yesterdayMax = ServerMapper.text(tmDaily, 'tempMax');
      outcome.yesterdayMin = ServerMapper.text(tmDaily, 'tempMin');
    }
    return outcome;
  }

  /** 天气产品包装（{ ok, code, error, data }）→ ok 时的 data；否则 null */
  private static productData(parent: Record<string, Object> | null, key: string): Record<string, Object> | null {
    if (parent === null) {
      return null;
    }
    const prod: Record<string, Object> | null = ServerMapper.toRecord(parent[key] ?? null);
    if (prod === null || !ServerMapper.flag(prod, 'ok')) {
      return null;
    }
    return ServerMapper.toRecord(prod['data'] ?? null);
  }

  /** Record 读对象数组字段，缺失返回空数组 */
  private static listIn(rec: Record<string, Object> | null, key: string): Object[] {
    if (rec === null) {
      return [];
    }
    const raw: Object | undefined = rec[key];
    if (raw === undefined || raw === null) {
      return [];
    }
    return raw as Object[];
  }

  /** 指数名去掉「指数」后缀（运动指数 → 运动） */
  private static trimIndexName(name: string): string {
    return name.endsWith('指数') ? name.substring(0, name.length - 2) : name;
  }

  /** profile.get（90）的 result → ProfileOutcome（profile 子对象拍平；91 成功响应同构可复用） */
  static toProfile(result: Object): ProfileOutcome {
    const outcome: ProfileOutcome = new ProfileOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.found = ServerMapper.flag(rec, 'found');
    outcome.avatarBase64 = ServerMapper.text(rec, 'avatarBase64');
    const inner: Record<string, Object> | null = ServerMapper.toRecord(rec['profile'] ?? null);
    if (inner === null) {
      return outcome;
    }
    outcome.gender = ServerMapper.text(inner, 'gender');
    outcome.birthday = ServerMapper.text(inner, 'birthday');
    outcome.signature = ServerMapper.text(inner, 'signature');
    outcome.province = ServerMapper.text(inner, 'province');
    outcome.city = ServerMapper.text(inner, 'city');
    outcome.hasAvatar = ServerMapper.flag(inner, 'hasAvatar');
    outcome.updatedAt = ServerMapper.text(inner, 'updatedAt');
    return outcome;
  }

  /** profile.avatar（92）的 result → AvatarOutcome（好友列表按 targetAccount 查头像） */
  static toAvatar(result: Object): AvatarOutcome {
    const outcome: AvatarOutcome = new AvatarOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.found = ServerMapper.flag(rec, 'found');
    outcome.hasAvatar = ServerMapper.flag(rec, 'hasAvatar');
    outcome.avatarBase64 = ServerMapper.text(rec, 'avatarBase64');
    outcome.updatedAt = ServerMapper.text(rec, 'updatedAt');
    return outcome;
  }

  /** groups.cover（112）的 result → GroupCoverOutcome（发现页卡片封面按 groupId 拉取） */
  static toGroupCover(result: Object): GroupCoverOutcome {
    const outcome: GroupCoverOutcome = new GroupCoverOutcome();
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (rec === null) {
      return outcome;
    }
    outcome.found = ServerMapper.flag(rec, 'found');
    outcome.hasCover = ServerMapper.flag(rec, 'hasCover');
    outcome.coverBase64 = ServerMapper.text(rec, 'cover');
    outcome.updatedAt = ServerMapper.text(rec, 'coverUpdatedAt');
    return outcome;
  }
}

/** 'yyyy-MM-dd HH:mm' → 'M月d日 HH:mm'；空串返回兜底文案 */
export function friendlyTime(text: string): string {
  if (text.length < 11) {
    return text.length > 0 ? text : '时间待定';
  }
  const month: number = Number(text.substring(5, 7));
  const day: number = Number(text.substring(8, 10));
  const hm: string = text.substring(11);
  return `${month}月${day}日 ${hm}`;
}

/** ISO 时间戳（yyyy-MM-ddTHH:mm:ss…）→ 'M月d日 HH:mm' */
export function friendlyStamp(text: string): string {
  if (text.length < 16) {
    return text.length > 0 ? text : '';
  }
  const month: number = Number(text.substring(5, 7));
  const day: number = Number(text.substring(8, 10));
  const hm: string = text.substring(11, 16);
  return `${month}月${day}日 ${hm}`;
}

/** 毫秒时间戳 → 'M月d日 HH:mm'（跨年补年份；非正数返回空串） */
export function friendlyMs(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  const month: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const hh: number = d.getHours();
  const mm: number = d.getMinutes();
  const hm: string = `${hh < 10 ? '0' : ''}${hh}:${mm < 10 ? '0' : ''}${mm}`;
  const now: Date = new Date();
  if (d.getFullYear() !== now.getFullYear()) {
    return `${d.getFullYear()}年${month}月${day}日 ${hm}`;
  }
  return `${month}月${day}日 ${hm}`;
}

/** 参与人字段（、/, 分隔的账号列表）→ 账号数组 */
export function splitParticipants(text: string): string[] {
  const list: string[] = [];
  if (text.length === 0) {
    return list;
  }
  const parts: string[] = text.split(new RegExp('[、,，]'));
  for (let i = 0; i < parts.length; i++) {
    const name: string = parts[i].trim();
    if (name.length > 0) {
      list.push(name);
    }
  }
  return list;
}

/** 'yyyy-MM-dd HH:mm' → Date（拼成 yyyy-MM-ddTHH:mm:00 本地时间解析）；失败返回 null */
function parseMoment(text: string): Date | null {
  const ms: number = Date.parse(`${text.substring(0, 10)}T${text.substring(11, 16)}:00`);
  if (Number.isNaN(ms)) {
    return null;
  }
  return new Date(ms);
}

/** 卡片 time 字段的结束时刻；null = 无有效时间（视为仍在招募）。
 * 支持 "YYYY-MM-DD HH:mm"、"…HH:mm~HH:mm"（同日段）、"…HH:mm~YYYY-MM-DD HH:mm"（跨天段） */
export function endMomentOf(text: string): Date | null {
  const trimmed: string = text.trim();
  if (trimmed.length < 16) {
    return null;
  }
  const start: Date | null = parseMoment(trimmed.substring(0, 16));
  if (start === null) {
    return null;
  }
  const wave: number = Math.max(trimmed.indexOf('~'), trimmed.indexOf('～'));
  if (wave < 0) {
    return start;
  }
  const tail: string = trimmed.substring(wave + 1).trim();
  if (tail.length >= 16) {
    const crossDay: Date | null = parseMoment(tail.substring(0, 16));
    if (crossDay !== null) {
      return crossDay;
    }
  }
  if (tail.length >= 5) {
    const h: number = Number(tail.substring(0, 2));
    const m: number = Number(tail.substring(3, 5));
    if (!Number.isNaN(h) && !Number.isNaN(m)) {
      const end: Date = new Date(start.getTime());
      end.setHours(h, m, 0, 0);
      if (end.getTime() < start.getTime()) {
        return new Date(end.getTime() + 24 * 3600 * 1000);
      }
      return end;
    }
  }
  return start;
}

/** 卡片 time 字段的开始时刻；null = 无有效时间（时间筛选时无法归入任何时间段） */
export function startMomentOf(text: string): Date | null {
  const trimmed: string = text.trim();
  if (trimmed.length < 16) {
    return null;
  }
  return parseMoment(trimmed.substring(0, 16));
}
