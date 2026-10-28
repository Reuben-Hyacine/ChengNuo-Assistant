import { common } from '@kit.AbilityKit';
import { BackendConfig } from './BackendConfig';
import { RouteOutcome, handleRoute } from './LocalRouter';
import { SessionRec, sessionStore } from './stores/SessionStore';
import { PostcardRec, RemoveResult, postcardStore } from './stores/PostcardStore';
import { personalizationStore } from './stores/PersonalizationStore';
import { conversationStore } from './stores/ConversationStore';
import { reportStore } from './stores/ReportStore';
import { ProfileRecord, profileStore } from './stores/ProfileStore';
import { friendAvatarStore } from './stores/FriendAvatarStore';
import { groupCoverStore } from './stores/GroupCoverStore';
import { weatherStore } from './stores/WeatherStore';
import { ModerationService } from './ModerationService';

/** HTTP 响应形状（对齐 Node 版 ok()/fail() 的 {code, message, data}） */
export class ApiResult {
  readonly code: number;
  readonly message: string;
  readonly data: Object | null;

  constructor(code: number, message: string, data: Object | null) {
    this.code = code;
    this.message = message;
    this.data = data;
  }
}

/**
 * 后端门面：App 侧唯一入口。
 * 数据全部落在 App 沙箱（filesDir/backend-data），网络转发走出站 NAT（10.0.2.2:3000）。
 */
export class Backend {
  /** App 启动时调用（EntryAbility.onCreate / CardFormAbility）：初始化客户端数据目录 */
  static init(context: common.Context): void {
    BackendConfig.init(context);
  }

  /** 本次安装周期内的首启时刻（毫秒），与 ServerGateway 的 bootId 语义一致 */
  static bootId(): number {
    return BackendConfig.bootId();
  }

  /** 个性化服务是否开启（默认开启） */
  static isPersonalizationEnabled(): boolean {
    return personalizationStore.isEnabled();
  }

  /** 个性化服务开关：关闭时立即清空本机已存的 AI 对话记录并停止记录，传输给 AI 的对话记录与
   *  用户信息改为空值；AI 聊天、卡片、AI 明信片等功能不受影响。开启时恢复记录与历史上送 */
  static setPersonalizationEnabled(enabled: boolean): void {
    personalizationStore.setEnabled(enabled);
    if (!enabled) {
      conversationStore.clearAll();
    }
  }

  /** ServerGateway 探测到新地址后同步（App 端手动改服务器地址的场景） */
  static setServerBase(base: string): void {
    BackendConfig.setServerBase(base);
  }

  /** 本地分流入口：handled=false 表示照旧转发服务器；code=0 表示成功 */
  static async handleRoute(serviceId: number, token: string | null,
    payload: Record<string, Object>): Promise<RouteOutcome> {
    return await handleRoute(serviceId, token, payload);
  }

  /** 智能审核：文本是否通过词库审核（离线演示 AI 复用同一套闸，未通过时回复「请手动输入」不建卡） */
  static textPassesModeration(text: string): boolean {
    return ModerationService.checkText(text).pass;
  }

  /** ---------- 个人空间（服务 90/91 的客户端副本）：本机长期保存一份，服务器另存一份 ---------- */

  /** 该账号的个人空间本地副本（从未保存过返回 null） */
  static getProfileRecord(account: string): ProfileRecord | null {
    return profileStore.getProfileOf(account);
  }

  /** 保存本地副本（avatarBytes：undefined=头像不动 / null=删除 / Uint8Array=覆盖 JPEG），返回落库后的记录 */
  static saveProfileRecord(record: ProfileRecord, avatarBytes: Uint8Array | null | undefined): ProfileRecord {
    return profileStore.saveProfileOf(record, avatarBytes);
  }

  /** 已保存头像的 file:// URI（无头像返回 ''），供 Image 组件直接显示 */
  static profileAvatarUri(account: string): string {
    return profileStore.avatarUriOf(account);
  }

  /** 该账号是否已有落盘头像 */
  static profileHasAvatar(account: string): boolean {
    return profileStore.avatarFileExistsOf(account);
  }

  /** ---------- 好友头像缓存（服务 92 拉取后落盘；与本人个人空间头像分开存） ---------- */

  /** 缓存的好友头像版本（无缓存返回 ''），与服务器 avatarUpdatedAt 比对决定是否重新拉取 */
  static friendAvatarUpdatedAtOf(account: string): string {
    return friendAvatarStore.cachedUpdatedAtOf(account);
  }

  /** 缓存好友头像的 file:// URI（无缓存或文件丢失返回 ''），供 Image 组件直接显示 */
  static friendAvatarUri(account: string): string {
    return friendAvatarStore.avatarUriOf(account);
  }

  /** 保存好友头像（JPEG 字节）与版本号，返回 file:// URI */
  static saveFriendAvatar(account: string, bytes: Uint8Array, updatedAt: string): string {
    return friendAvatarStore.saveAvatarOf(account, bytes, updatedAt);
  }

  /** 移除好友时清该账号的头像缓存（文件与版本记录一并清） */
  static removeFriendAvatar(account: string): void {
    friendAvatarStore.removeAvatarOf(account);
  }

  /** ---------- 卡片组封面缓存（服务 112 拉取后落盘） ---------- */

  /** 缓存的组封面版本（无缓存返回 ''），与服务器 coverUpdatedAt 比对决定是否重新拉取 */
  static groupCoverUpdatedAtOf(groupId: number): string {
    return groupCoverStore.cachedUpdatedAtOf(groupId);
  }

  /** 缓存组封面的 file:// URI（无缓存或文件丢失返回 ''），供 Image 组件直接显示 */
  static groupCoverUri(groupId: number): string {
    return groupCoverStore.coverUriOf(groupId);
  }

  /** 保存组封面（JPEG 字节）与版本号，返回 file:// URI */
  static saveGroupCover(groupId: number, bytes: Uint8Array, updatedAt: string): string {
    return groupCoverStore.saveCoverOf(groupId, bytes, updatedAt);
  }

  /** 删除组封面（105 remove）后同步清本地缓存（文件与版本记录一并清） */
  static removeGroupCover(groupId: number): void {
    groupCoverStore.removeCoverOf(groupId);
  }

  /** 最近一份天气快照（服务 97 成功后由内置后端写入，新结果清空旧数据；无快照返回 null）：
   *  离线展示与刷新时机（fetchedAt 是否超过阈值）判断用 */
  static latestWeather(): Record<string, Object> | null {
    return weatherStore.latest();
  }

  /** GET /api/my/postcards?token=...（「明信片」库：按登录 token 反解账号后读本机记录） */
  static postcardsList(token: string): ApiResult {
    const session: SessionRec | null = sessionStore.resolveSession(token);
    if (session === null) {
      return new ApiResult(40101, '未登录：请先在客户端登录账号', null);
    }
    const postcards: PostcardRec[] = postcardStore.listForAccount(session.account);
    const items: Object[] = [];
    for (let i = 0; i < postcards.length; i++) {
      items.push(postcards[i].toRecord());
    }
    const data: Record<string, Object> = { 'account': session.account, 'total': items.length, 'postcards': items };
    return new ApiResult(0, 'ok', data);
  }

  /** DELETE /api/my/postcards/:id（「明信片」库的删除按钮：只删本机记录，且仅限本账号） */
  static postcardsDelete(token: string, id: number): ApiResult {
    const session: SessionRec | null = sessionStore.resolveSession(token);
    if (session === null) {
      return new ApiResult(40101, '未登录：请先在客户端登录账号', null);
    }
    if (!Number.isInteger(id) || id < 1) {
      return new ApiResult(40001, 'id 必须是正整数', null);
    }
    const removed: RemoveResult = postcardStore.removePostcard(session.account, id);
    if (!removed.removed) {
      return new ApiResult(40401, '明信片不存在或不属于当前账号', null);
    }
    const data: Record<string, Object> =
      { 'account': session.account, 'id': id, 'removed': true, 'message': `已删除明信片 #${id}` };
    return new ApiResult(0, 'ok', data);
  }

  /** 清空本机 AI 对话记录（「个人信息」管理页清空按钮）：conversations.txt 中该用户的全部记录一并删除 */
  static clearConversations(token: string): ApiResult {
    const session: SessionRec | null = sessionStore.resolveSession(token);
    if (session === null) {
      return new ApiResult(40101, '未登录：请先在客户端登录账号', null);
    }
    const cleared: number = session.userId !== null ?
      conversationStore.clearByUser(session.userId) : conversationStore.clearByAccount(session.account);
    const data: Record<string, Object> = { 'account': session.account, 'cleared': cleared > 0 };
    return new ApiResult(0, 'ok', data);
  }

  /** 清空本机周报库（「个人信息」管理页清除按钮）：reports.txt 中该账号的周桶与累计数据一并删除；
   *  下次周报（74）会按服务器快照重新统计本周 */
  static clearWeekReport(token: string): ApiResult {
    const session: SessionRec | null = sessionStore.resolveSession(token);
    if (session === null) {
      return new ApiResult(40101, '未登录：请先在客户端登录账号', null);
    }
    const removed: number = reportStore.clearByAccount(session.account);
    const data: Record<string, Object> = { 'account': session.account, 'cleared': removed > 0 };
    return new ApiResult(0, 'ok', data);
  }
}
