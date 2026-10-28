import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Backend } from '@chengnuo/backend';
import { groupChatStore } from '../store/GroupChatStore';
import { ServerGateway } from '../net/ServerGateway';
import { CardExtendOutcome, CompleteCardOutcome, LibraryEntryInfo, LibraryListOutcome,
  MessageOutcome, splitParticipants, WrittenCardInfo } from '../net/ServerModels';
import { CardKind, CardStatus, TaskCard } from '../model/Types';
import { petStore, petPointsOfTime } from '../store/PetStore';
import { FormCardData, FormIds, LockAction } from './FormCardData';

const DOMAIN: number = 0x0003;
const TAG: string = 'ChengNuoLockCard';
const FORM_IDENTITY_KEY: string = 'ohos.extra.param.key.form_identity';

/**
 * 锁屏卡片提供方：展示「最近的未完成/打卡卡片」，锁屏上直接执行服务器动作（不解锁）：
 * - 完成：62（标记完成 + 后端 AI 出稿明信片 + 出稿成功即归档删卡）
 * - 延时：67（计划开始时间 +30 分钟；非创建者提交申请等待审批）
 * - 取消：创建者 57 删卡 / 参与者 15 退卡，删后顺带清理空组（55）
 * - 打卡为应用本地记录，卡片页走 router 拉起应用执行（不在本进程处理）
 * 卡片进程与主进程共享沙箱：Backend.init 后可读登录态文件恢复会话（11 重登拿 token）
 */
export default class CardFormAbility extends FormExtensionAbility {
  /** 本进程会话是否已恢复（token 就绪） */
  private static sessionReady: boolean = false;
  /** 本进程记录的登录账号（会话恢复后回填；删卡清聊天记录按账号定位本地文件） */
  private static sessionAccount: string = '';
  /** 动作串行守卫（避免连点并发打服务器） */
  private static actionBusy: boolean = false;
  private static backendReady: boolean = false;

  onAddForm(want: Want): formBindingData.FormBindingData {
    const params: Record<string, Object> | undefined = want.parameters;
    const formIdObj: Object | undefined = params !== undefined ? params[FORM_IDENTITY_KEY] : undefined;
    const formId: string = typeof formIdObj === 'string' ? formIdObj : '';
    if (formId.length > 0) {
      FormIds.add(this.context, formId);
    }
    hilog.info(DOMAIN, TAG, `onAddForm formId=${formId}`);
    const placeholder: Record<string, Object> = FormCardData.buildPayload(undefined, '', '', 0);
    this.refreshForm(formId, '');
    return formBindingData.createFormBindingData(placeholder);
  }

  onUpdateForm(formId: string): void {
    this.refreshForm(formId, '');
  }

  onFormEvent(formId: string, message: string): void {
    const action: LockAction = LockAction.parse(message);
    hilog.info(DOMAIN, TAG, `onFormEvent formId=${formId} action=${action.action} cardId=${action.cardId}`);
    if (action.action === 'complete' || action.action === 'delay' || action.action === 'cancel') {
      this.runAction(formId, action);
    }
  }

  onRemoveForm(formId: string): void {
    FormIds.remove(this.context, formId);
    hilog.info(DOMAIN, TAG, `onRemoveForm formId=${formId}`);
  }

    /** 初始化内置后端（读共享沙箱登录态）、探测服务器地址并恢复会话；返回是否就绪 */
  private async ensureSession(): Promise<boolean> {
    if (!CardFormAbility.backendReady) {
      Backend.init(this.context);
      petStore.init(this.context);
      CardFormAbility.backendReady = true;
    }
    if (CardFormAbility.sessionReady && ServerGateway.getToken().length > 0) {
      return true;
    }
    // 卡片进程没有主进程的 AppStorage 服务器地址缓存，转发型服务（11/54/62/67/57/15/55）前须先探测
    if (!(await ServerGateway.ensureBase())) {
      CardFormAbility.sessionReady = false;
      return false;
    }
    const state = await ServerGateway.loginState();
    if (!state.ok || state.state !== 1 || state.account.length === 0) {
      CardFormAbility.sessionReady = false;
      return false;
    }
    const outcome = await ServerGateway.login(state.account, state.password);
    CardFormAbility.sessionReady = outcome.ok;
    CardFormAbility.sessionAccount = outcome.ok ? state.account : '';
    return CardFormAbility.sessionReady;
  }

  /** 54 拉取卡片库并映射为日程卡视图（与应用内 serverCardOf 同规则，排除服务器侧已完成卡） */
  private async fetchCards(): Promise<TaskCard[]> {
    const lib: LibraryListOutcome = await ServerGateway.myLibraryList();
    const out: TaskCard[] = [];
    if (!lib.ok) {
      return out;
    }
    for (let i = 0; i < lib.entries.length; i++) {
      const mapped: TaskCard | null = CardFormAbility.toCard(lib.entries[i]);
      if (mapped !== null) {
        out.push(mapped);
      }
    }
    return out;
  }

  private static toCard(entry: LibraryEntryInfo): TaskCard | null {
    const card: WrittenCardInfo = entry.card;
    if (entry.completed) {
      return null;
    }
    if (card.time.length < 10) {
      return null;
    }
    const title: string = card.event.length > 0 ? card.event
      : (card.purpose.length > 0 ? card.purpose : '未命名卡片');
    const id: string = `srv-g${entry.groupId}-${card.index}`;
    const c: TaskCard = TaskCard.of(id, title, CardKind.Schedule, CardStatus.Set,
      card.time.length >= 16 ? card.time.substring(11, 16) : '时间待定',
      card.location.length > 0 ? card.location : '地点待定',
      entry.library === 'public' ? '🤝' : '📅');
    c.dateText = card.time.substring(0, 10);
    c.groupId = entry.groupId;
    c.isOwner = entry.isOwner;
    c.completableBy = card.completableBy;
    const repeatEnd: string = card.repeatUntil.length >= 10 ? card.repeatUntil.substring(0, 10) : '';
    c.repeatEndDate = repeatEnd >= c.dateText ? repeatEnd : '';
    if (entry.library === 'public') {
      const participants: string[] = splitParticipants(card.participant);
      if (participants.length > 0) {
        c.note = `与 ${participants.join('、')} 一起`;
      }
    }
    return c;
  }

  /** 重拉数据并推送锁屏卡片（feedback 为一次性提示文案，随下次刷新清除） */
  private async refreshForm(formId: string, feedback: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      let payload: Record<string, Object> = FormCardData.buildPayload(undefined, CardFormAbility.sessionAccount, feedback, 0);
      if (await this.ensureSession()) {
        const cards: TaskCard[] = await this.fetchCards();
        const next: TaskCard | undefined = FormCardData.pickNextCard(cards, FormCardData.todayIso());
        payload = FormCardData.buildPayload(next, CardFormAbility.sessionAccount, feedback, 0);
      } else if (feedback.length === 0) {
        payload = FormCardData.buildPayload(undefined, '', '请先打开程诺登录', 0);
      }
      const formInfo: formBindingData.FormBindingData = formBindingData.createFormBindingData(payload);
      await formProvider.updateForm(formId, formInfo);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `refreshForm failed: ${(e as BusinessError).message}`);
    }
  }

  /** 执行锁屏动作：动作完成后重拉数据回填反馈。
   *  注意不可在 onFormEvent 同步栈内调 formProvider.updateForm（会在 FMS 消息分发期间
   *  发起对 FMS 的重入 IPC 导致死锁，10 秒后被系统回收），忙碌态由 actionBusy 防连点兜底 */
  private async runAction(formId: string, action: LockAction): Promise<void> {
    if (CardFormAbility.actionBusy) {
      return;
    }
    CardFormAbility.actionBusy = true;
    let feedback: string = '';
    try {
      if (!(await this.ensureSession())) {
        feedback = '请先打开程诺登录';
      } else {
        const cards: TaskCard[] = await this.fetchCards();
        const target: TaskCard | undefined = this.findById(cards, action.cardId);
        if (target === undefined) {
          feedback = '卡片刚刚有了新变化';
        } else if (action.action === 'complete') {
          feedback = await this.doComplete(target);
        } else if (action.action === 'delay') {
          feedback = await this.doDelay(target);
        } else {
          feedback = await this.doCancel(target);
        }
      }
      await this.refreshForm(formId, feedback);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `runAction ${action.action} failed: ${(e as BusinessError).message}`);
      await this.refreshForm(formId, '操作失败，请稍后再试');
    } finally {
      CardFormAbility.actionBusy = false;
    }
  }

  private findById(cards: TaskCard[], cardId: string): TaskCard | undefined {
    for (let i = 0; i < cards.length; i++) {
      if (cards[i].id === cardId) {
        return cards[i];
      }
    }
    return undefined;
  }

  /** 62 完成：后端顺带 AI 出稿明信片并归档删卡 */
  private async doComplete(c: TaskCard): Promise<string> {
    const parts: string[] = c.id.split('-');
    const cardIndex: number = parts.length === 3 ? Number(parts[2]) : NaN;
    if (Number.isNaN(cardIndex) || c.groupId <= 0) {
      return '该卡片无法在锁屏完成';
    }
    const outcome: CompleteCardOutcome = await ServerGateway.groupsCompleteCard(c.groupId, cardIndex);
    if (!outcome.ok) {
      return outcome.message;
    }
    // 出稿成功即删卡归档（54 再看不到该卡）：按计划时长把积分现场记入宠物账本（key 查重不重复记；
    // 出稿失败的卡留在组内，由宠物页打开时经 54 补记）
    if (outcome.postcard !== null && outcome.postcard.time.length > 0) {
      petStore.addEarned(CardFormAbility.sessionAccount, `pc-${outcome.postcard.id}`,
        petPointsOfTime(outcome.postcard.time));
    }
    return outcome.postcard !== null ? '已兑现 ✓ 明信片已生成' : '已兑现 ✓';
  }

  /** 67 延时：计划开始时间 +30 分钟（创建者立即改期 / 其余提交申请） */
  private async doDelay(c: TaskCard): Promise<string> {
    const parts: string[] = c.id.split('-');
    const cardIndex: number = parts.length === 3 ? Number(parts[2]) : NaN;
    if (Number.isNaN(cardIndex) || c.groupId <= 0) {
      return '该卡片无法延时';
    }
    const newTime: string = FormCardData.extendTimeOf(c, 30);
    const outcome: CardExtendOutcome = await ServerGateway.cardsExtend(c.groupId, cardIndex, newTime);
    if (!outcome.ok) {
      return outcome.message;
    }
    if (outcome.mode === 'applied') {
      // 服务器时间文本 "yyyy-MM-dd HH:mm" → 短展示 "MM-dd HH:mm"（解析不了回退提交值）
      const cn: string = outcome.time.length >= 16 ? outcome.time.substring(5, 16) : newTime;
      return `已延时至 ${cn}`;
    }
    return '延时申请已提交 ⏳';
  }

  /** 取消：创建者 57 删卡 / 参与者 15 退卡；创建者删卡后组若空顺带 55 清理 */
  private async doCancel(c: TaskCard): Promise<string> {
    const parts: string[] = c.id.split('-');
    const cardIndex: number = parts.length === 3 ? Number(parts[2]) : NaN;
    if (Number.isNaN(cardIndex) || c.groupId <= 0) {
      return '该卡片无法取消';
    }
    const outcome: MessageOutcome = c.isOwner
      ? await ServerGateway.groupRemoveCard(c.groupId, cardIndex)
      : await ServerGateway.cardsLeave(c.groupId, cardIndex);
    if (!outcome.ok) {
      return outcome.message;
    }
    if (c.isOwner) {
      // 创建者删除的卡不再兑现（无明信片）：该群本地聊天记录一并清掉（卡片进程与主进程共享沙箱）
      groupChatStore.init(this.context);
      groupChatStore.deleteThread(CardFormAbility.sessionAccount, c.groupId);
      await this.cleanupEmptyGroup(c.groupId);
    }
    return c.isOwner ? '已取消 ✓' : '已退出该卡 ✓';
  }

  /** 54 重拉确认该组再无任何条目（含已完成归档）→ 55 删除空组；失败静默（应用侧会再清理） */
  private async cleanupEmptyGroup(groupId: number): Promise<void> {
    try {
      const lib: LibraryListOutcome = await ServerGateway.myLibraryList();
      if (!lib.ok) {
        return;
      }
      let count: number = 0;
      for (let i = 0; i < lib.entries.length; i++) {
        if (lib.entries[i].groupId === groupId) {
          count += 1;
        }
      }
      if (count === 0) {
        await ServerGateway.groupsDelete(groupId);
      }
    } catch (e) {
    }
  }
}
