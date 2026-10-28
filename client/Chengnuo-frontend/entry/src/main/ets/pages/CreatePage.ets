import { appStore } from '../store/AppStore';
import { groupChatStore } from '../store/GroupChatStore';
import { MockData } from '../model/MockData';
import { CardKind, CardStatus, ChatMsg, TaskCard } from '../model/Types';
import { Theme } from '../common/Theme';
import { Card } from '../components/Card';
import { ChatBubble } from '../components/ChatBubble';
import { EmptyState } from '../components/EmptyState';
import { TagPicker, typeTagOptions, sceneTagOptions, themeTagOptions } from '../components/TagPicker';
import { ServerGateway } from '../net/ServerGateway';
import { Backend } from '@chengnuo/backend';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import {
  AskOutcome, CompleteOutcome, ConflictsOutcome, ConversationMessageInfo, ConversationsOutcome,
  FlowOutcome, LibraryEntryInfo, LibraryGroupHead, LibraryListOutcome,
  MessageOutcome, PickOutcome, StatusOutcome, WorkingCardInfo, WrittenCardInfo,
  friendlyTime
} from '../net/ServerModels';
import { tr, trf, trEq } from '../common/I18n';

/**
 * 创建页：AI 对话成卡 + 我的卡片库看板（真实分组）。
 * 看板列与服务器真实卡片组一一对应（groups.list 54 组级摘要，含空组），每组顶端恒为一张空卡片，
 * 页面最右端恒为虚拟「✨ 新卡片组」列（顶端空卡）；屏幕正中间的卡片即「正在设置卡片」：
 * 空卡在哪个卡片组顶端，确定后就记录进哪个卡片组（新建组列确定 = 服务器新建同名组收纳）。
 * 工作卡面板：确定 7（按居中组落库：新建组 / 追加进组 / 原位更新）/ 取消 6
 *            / 冲突查询 33 / 对话历史恢复 39
 *            / 手动制作 cards.edit 51 / 删除入库卡（创建者删卡 groups.remove-card 57 / 参与者退卡 cards.leave 15）。
 * 滑到已入库卡片上时经 cards.pick 76 整份载入工作卡（原新卡草稿本地缓存），AI 对话与手动制作的
 * 改动实时呈现在该卡片槽位上；滑回头槽（新卡片位）自动释放并还原草稿；确定/取消后草稿缓存一并清空，
 * 工作卡从空白重新开始（选取确定 = 原位更新该卡并抑制立即重选）。
 * 服务器离线或未配置 API Key：回退离线演示对话流程。
 */
@Entry
@Component
struct CreatePage {
  @StorageProp('appLang') appLang: string = 'zh';
  @State libraryCards: TaskCard[] = [];
  /** 看板列头：与服务器真实卡片组一一对应（54 组级摘要，含空组），末位恒为虚拟「新卡片组」列（groupId=0） */
  @State boardHeads: BoardHead[] = [];
  @State chatMsgs: ChatMsg[] = [];
  @State chatStep: number = 0;
  @State buffer: string = '';
  /** 服务器 AI 可用（已登录 + 已配置 API Key） */
  @State aiReady: boolean = false;
  @State aiThinking: boolean = false;
  /** 服务器工作卡快照（无内容时 hasContent=false，面板隐藏） */
  @State working: WorkingCardInfo = new WorkingCardInfo();
  /** 流程状态：0 收集信息 / 1 待确认 / 2 已定稿 */
  @State flowState: number = 0;
  /** 手动制作面板（cards.edit 51 直接编辑工作卡文本字段，写完仍用 ai.complete 7 落库） */
  @State manualVisible: boolean = false;
  @State mEvent: string = '';
  @State mTime: string = '';
  @State mLocation: string = '';
  @State mReminder: string = '';
  @State mPurpose: string = '';
  @State mRepeat: string = '';
  @State mRepeatUntil: string = '';
  /** 手动制作面板：三维度标签（类型/场景/主题，点选；空 = 尚未选择 = 保持工作卡现状不写入） */
  @State mType: string = '';
  @State mScene: string = '';
  @State mTheme: string = '';
  /** 手动制作面板：话题标签（≤5 个、每个 ≤12 字；#、空格或、分隔；留空 = 清空） */
  @State mTags: string = '';
  @State isRefreshing: boolean = false;
  /** 输入框聚焦时聊天区底部留白稍大 */
  @State inputFocused: boolean = false;
  /** 键盘高度（vp）：手动避让，根布局留出底部内边距，输入框始终露在键盘上方 */
  @State kbHeight: number = 0;
  /** 卡片背面停留期间的全屏点击遮罩：点卡片=翻回并确定，点外部=翻回取消 */
  @State flipGuardActive: boolean = false;
  /** 被选取为「正在设置卡片」的已入库卡片 id（srv-g{groupId}-{cardIndex}；空 = 新卡片模式）：
   *  屏幕正中间的卡片即编辑目标 —— 滑到已入库卡片上时经 cards.pick（76）整份载入工作卡，
   *  AI 对话与手动制作的改动实时呈现在该卡片槽位上 */
  @State pickedCardId: string = '';
  /** 背面朝上的卡片及其页面坐标（遮罩命中判定） */
  private flippedCardId: string = '';
  private flipRectX: number = 0;
  private flipRectY: number = 0;
  private flipRectW: number = 0;
  private flipRectH: number = 0;
  private pendingCardId: string = '';
  private chatScroller: Scroller = new Scroller();
  private savedAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  /** 键盘高度监听所在窗口及其回调（aboutToDisappear 解绑） */
  private kbWindow: window.Window | null = null;
  private kbCallback: (height: number) => void = (): void => {};
  /** 键盘上移回退量（vp）：上报键盘高度偏大，内容整体小幅下调让输入框贴近键盘上沿 */
  private kbLiftTrim: number = 40;
  private msgSeq: number = 0;
  private idSeq: number = 0;
  /** 看板最近上报的居中卡片 id（'' = 头槽「新卡片」位），是编辑目标的期望值 */
  private reportedTargetId: string = '';
  /** 选取/还原期间不再并发触发（进行中上报只更新期望值，完成后循环内重读收敛） */
  private syncingTarget: boolean = false;
  /** 「确定/取消」后抑制对同一张卡片的立即重选（避免刚确认又被 76 载入），滑走后自动解除 */
  private suppressTargetId: string = '';
  /** 选取前缓存的新卡片草稿（76 会整份覆写服务器工作卡；滑回头槽时还原）。确定/取消成功后清空，
   *  保证下一次设置从空白开始 */
  private draftCache: WorkingCardInfo | null = null;
  /** 看板当前居中的卡片组（0 = 最右「新卡片组」列）：顶端空卡确定后就记录进该组 */
  private centeredGroupId: number = 0;

  aboutToAppear(): void {
    if (appStore.serverOnline && ServerGateway.getToken().length > 0) {
      this.initServerChat();
      this.loadLibrary();
    } else {
      this.chatMsgs = MockData.initialChat();
      // 离线演示：单列看板收纳演示卡（真实分组列仅服务器在线时存在）
      const demo: BoardHead = new BoardHead();
      demo.name = tr('我的卡片库');
      this.boardHeads = [demo];
    }
  }

  aboutToDisappear(): void {
    if (this.kbWindow !== null) {
      this.kbWindow.off('keyboardHeightChange', this.kbCallback);
      this.kbWindow = null;
    }
  }

  /** 键盘弹出时本页改用「手动」避让：窗口不压缩不偏移，监听键盘高度为根布局留出底部内边距，输入框始终露在键盘上方 */
  onPageShow(): void {
    this.savedAvoidMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    this.bindKeyboard();
  }

  onPageHide(): void {
    this.getUIContext().setKeyboardAvoidMode(this.savedAvoidMode);
  }

  /** 绑定主窗口键盘高度监听（仅一次），高度变化换算为 vp 存入 kbHeight */
  private bindKeyboard(): void {
    if (this.kbWindow !== null) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    window.getLastWindow(ctx).then((win: window.Window) => {
      this.kbWindow = win;
      this.kbCallback = (height: number): void => {
        this.kbHeight = this.getUIContext().px2vp(height);
      };
      win.on('keyboardHeightChange', this.kbCallback);
    }).catch((): void => {
    });
  }

  private nextMsgId(): string {
    this.msgSeq += 1;
    return `m-${this.msgSeq}`;
  }

  private pushUser(text: string): void {
    this.chatMsgs = [...this.chatMsgs, ChatMsg.of(this.nextMsgId(), false, text, [])];
    this.scrollChat();
  }

  private pushAI(text: string, chips: string[]): void {
    this.chatMsgs = [...this.chatMsgs, ChatMsg.of(this.nextMsgId(), true, text, chips)];
    this.scrollChat();
  }

  private scrollChat(): void {
    setTimeout(() => {
      if (this.chatMsgs.length > 0) {
        this.chatScroller.scrollToIndex(this.chatMsgs.length - 1);
      }
    }, 80);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** ---------- 服务器 AI 模式 ---------- */

  private async initServerChat(): Promise<void> {
    const status: StatusOutcome = await ServerGateway.aiStatus();
    if (!status.ok) {
      this.chatMsgs = MockData.initialChat();
      return;
    }
    if (!status.configured) {
      this.chatMsgs = MockData.initialChat();
      this.pushAI(tr('服务器 AI 还没配置 API Key，先用离线演示陪你聊 🍊'), []);
      return;
    }
    this.aiReady = true;
    this.working = status.working ?? new WorkingCardInfo();
    this.flowState = status.flow !== null ? status.flow.state : 0;
    this.chatMsgs = [];
    // 恢复服务器保存的最近对话（conversations.list 39，旧 → 新）
    const history: ConversationsOutcome = await ServerGateway.conversationsList();
    if (history.ok) {
      history.messages.forEach((m: ConversationMessageInfo) => {
        this.chatMsgs = [...this.chatMsgs,
          ChatMsg.of(this.nextMsgId(), m.direction !== 'in', m.content.length > 0 ? m.content : '…', [])];
      });
    }
    this.pushAI(tr('我是程诺 AI 🤖 说出你的想法，我来帮你安排成卡。'), []);
    if (this.working.hasContent && this.chatMsgs.length <= 1) {
      const last: string = status.lastReply.length > 0 ? status.lastReply : tr('上次的卡片还在');
      this.pushAI(trf('接着上次继续：{0}', last), [tr('✅ 确定'), tr('🔄 重新开始')]);
    }
  }

  /** 在线发送：ai.ask 真实对话，同步工作卡与流程状态；
   *  居中组定位随请求上送，FINALIZE 阶段自动落库时按它落位（与「确定」一致） */
  private async sendToAi(text: string): Promise<void> {
    if (this.aiThinking) {
      return;
    }
    this.pushUser(text);
    this.aiThinking = true;
    const coords: number[] = this.pickedCardId !== '' ? this.parseServerCardId(this.pickedCardId) : [];
    const targetGroupId: number = coords.length === 2 ? coords[0] : this.centeredGroupId;
    const targetCardIndex: number = coords.length === 2 ? coords[1] : 0;
    const outcome: AskOutcome = await ServerGateway.aiAsk(text, targetGroupId, targetCardIndex);
    this.aiThinking = false;
    if (!outcome.ok) {
      this.pushAI(trf('AI 暂时没法回复：{0} 🍊 稍后再试试', outcome.message), []);
      return;
    }
    this.working = outcome.working ?? new WorkingCardInfo();
    this.flowState = outcome.flow !== null ? outcome.flow.state : 0;
    let reply: string = outcome.reply.length > 0 ? outcome.reply : tr('（AI 走神了，再说一次？）');
    if (outcome.notes.length > 0) {
      reply = `${reply}\n💬 ${outcome.notes.join('；')}`;
    }
    if (outcome.writtenCard !== null) {
      this.addWrittenCard(outcome.writtenCard);
    }
    const chips: string[] = this.flowState === 1 || this.flowState === 2 ? [tr('✅ 确定'), tr('🔄 重新开始')] : [];
    this.pushAI(reply, chips);
    this.syncTarget();
  }

  /** 确定：ai.complete 校验提醒时间/时间冲突后按看板居中的卡片组落库——
   *  选取已入库卡确定 = 原位更新该卡；真实组顶端空卡确定 = 追加进该组；最右「新卡片组」列确定 = 服务器新建同名组收纳 */
  private async doComplete(): Promise<void> {
    if (this.aiThinking) {
      return;
    }
    const coords: number[] = this.pickedCardId !== '' ? this.parseServerCardId(this.pickedCardId) : [];
    let targetGroupId: number = 0;
    let targetCardIndex: number = 0;
    if (coords.length === 2) {
      targetGroupId = coords[0];
      targetCardIndex = coords[1];
    } else {
      targetGroupId = this.centeredGroupId;
      const head: BoardHead | undefined = this.headOf(targetGroupId);
      if (head !== undefined && !head.isOwner) {
        this.toast(tr('只有创建者能在该组添加卡片：请滑到最右侧「✨ 新卡片组」再确定'));
        return;
      }
    }
    this.aiThinking = true;
    const res: CompleteOutcome = await ServerGateway.aiComplete(targetGroupId, targetCardIndex);
    this.aiThinking = false;
    if (res.ok && res.writtenCard !== null) {
      if (coords.length === 2 && res.writtenCard.groupId !== targetGroupId) {
        // 选取的卡被「转公开/转私人」移到了新卡片组：整板重拉，原列中的旧卡随之移除
        this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
          this.working = new WorkingCardInfo();
          this.flowState = 0;
          this.draftCache = null;
        });
        this.releasePickAfterComplete();
        await this.loadLibrary();
      } else {
        this.addWrittenCard(res.writtenCard);
        this.releasePickAfterComplete();
      }
      this.pushAI(trf('{0}，卡片已加入你的看板 ✅', res.message.length > 0 ? res.message : tr(tr('已写入卡片库'))), []);
    } else if (res.ok) {
      this.working = new WorkingCardInfo();
      this.flowState = 0;
      this.draftCache = null;
      this.releasePickAfterComplete();
      this.pushAI(res.message.length > 0 ? res.message : tr('确定完成 ✅'), []);
    } else {
      this.pushAI(trf('暂时不能确定：{0}', res.message), []);
    }
    this.syncTarget();
  }

  /** 选取状态下「确定」成功：释放选取（原卡片恢复原样），并抑制对居中卡片的立即重选 */
  private releasePickAfterComplete(): void {
    if (this.pickedCardId !== '') {
      this.pickedCardId = '';
      this.suppressTargetId = this.reportedTargetId;
    }
  }

  /** 取消：ai.reset 清空工作卡并重置确认状态 */
  private async doReset(): Promise<void> {
    if (this.aiThinking) {
      return;
    }
    this.aiThinking = true;
    const res: FlowOutcome = await ServerGateway.aiReset();
    this.aiThinking = false;
    if (res.ok) {
      this.working = res.working ?? new WorkingCardInfo();
      this.flowState = res.flow !== null ? res.flow.state : 0;
      // 选取状态下「取消」：释放选取（卡片恢复原样），不立即重选同一张卡；
      // 草稿缓存一并清空——取消后从头开始，旧草稿不再回填到空卡片上
      this.draftCache = null;
      if (this.pickedCardId !== '') {
        this.pickedCardId = '';
        this.suppressTargetId = this.reportedTargetId;
      }
      this.pushAI(tr('已清空当前卡片，我们重新开始 🔄'), []);
    } else {
      this.pushAI(trf('取消失败：{0}', res.message), []);
    }
    this.syncTarget();
  }

  /** ---------- 选取居中卡片为「正在设置卡片」（cards.pick 76） ---------- */

  /** 看板上报居中卡片变化：头槽（新卡片位）= ''，其余为该卡片 id；居中组号一并上报——
   *  空卡在哪个组顶端，确定后就记录进哪个组 */
  private handleCenteredCardChange(groupId: number, card: TaskCard | null): void {
    this.centeredGroupId = groupId;
    const id: string = card === null ? '' : card.id;
    if (id !== this.suppressTargetId) {
      this.suppressTargetId = '';
    }
    this.reportedTargetId = id;
    this.syncTarget();
  }

  /** 把服务器工作卡同步为居中卡片：滑到已入库卡片 → 76 选取；滑回头槽 → 释放并还原草稿。
   *  进行中的上报只更新期望值，本方法串行收敛（每步完成后重读期望值，直到与当前模式一致） */
  private async syncTarget(): Promise<void> {
    if (!this.aiReady || this.syncingTarget) {
      return;
    }
    this.syncingTarget = true;
    try {
      let guard: number = 0;
      while (guard < 8) {
        guard += 1;
        const want: string = this.reportedTargetId;
        if (this.pickedCardId === '' && want !== '' && want === this.suppressTargetId) {
          break; // 「确定/取消」后的抑制位：同一张卡先不重选，滑走即解除
        }
        if (want === '') {
          if (this.pickedCardId === '') {
            break; // 已是新卡片模式
          }
          const released: boolean = await this.releasePickToNewCard();
          if (!released) {
            break; // 失败：保持现状，下次上报或 AI 动作完成后重试
          }
        } else {
          if (want === this.pickedCardId || want.indexOf('srv-g') !== 0) {
            break; // 已选取该卡 / 居中为不可选取的本地演示卡：保持现状
          }
          const picked: boolean = await this.pickCardAsTarget(want);
          if (!picked) {
            break;
          }
        }
      }
    } finally {
      this.syncingTarget = false;
    }
  }

  /** srv-g{groupId}-{cardIndex} → [groupId, cardIndex]；其余 id 返回空数组 */
  private parseServerCardId(id: string): number[] {
    const parts: string[] = id.split('-');
    if (parts.length !== 3 || parts[0] !== 'srv' || parts[1].length <= 1 || parts[1].charAt(0) !== 'g') {
      return [];
    }
    const groupIdNum: number = Number(parts[1].substring(1));
    const cardIndexNum: number = Number(parts[2]);
    if (Number.isNaN(groupIdNum) || Number.isNaN(cardIndexNum)) {
      return [];
    }
    return [groupIdNum, cardIndexNum];
  }

  /** 选取一张已入库卡片为编辑目标（76）：先缓存未完成的新卡草稿（服务器工作卡是单槽，会被整份覆写） */
  private async pickCardAsTarget(id: string): Promise<boolean> {
    const coords: number[] = this.parseServerCardId(id);
    if (coords.length !== 2) {
      return false;
    }
    if (this.pickedCardId === '' && this.working.hasContent && this.draftCache === null) {
      this.draftCache = this.cloneWorking(this.working);
    }
    const outcome: PickOutcome = await ServerGateway.aiPick(coords[0], coords[1]);
    if (!outcome.ok) {
      this.toast(trf('选取失败：{0}', outcome.message));
      return false;
    }
    this.pickedCardId = id;
    this.working = outcome.working ?? new WorkingCardInfo();
    this.flowState = outcome.flow !== null ? outcome.flow.state : 0;
    this.toast(tr('已选取该卡片：AI 对话与手动制作将直接修改它 ✏️'));
    return true;
  }

  /** 滑回头槽（新卡片位）：释放选取并按缓存还原草稿 —— ai.reset 清空后用 cards.edit 51 全量覆写
   *  七个文本字段（空串=清空） */
  private async releasePickToNewCard(): Promise<boolean> {
    const draft: WorkingCardInfo | null = this.draftCache;
    const res: FlowOutcome = await ServerGateway.aiReset();
    if (!res.ok) {
      this.toast(trf('还原新卡片失败：{0}', res.message));
      return false;
    }
    this.working = res.working ?? new WorkingCardInfo();
    this.flowState = res.flow !== null ? res.flow.state : 0;
    this.pickedCardId = '';
    if (draft === null || !draft.hasContent) {
      this.draftCache = null;
      return true;
    }
    const fields: Record<string, Object> = {
      'event': draft.event,
      'time': draft.time,
      'location': draft.location,
      'reminderTime': draft.reminderTime,
      'purpose': draft.purpose,
      'repeatTime': draft.repeatTime,
      'repeatUntil': draft.repeatUntil
    };
    const edit: FlowOutcome = await ServerGateway.cardsEdit(fields);
    if (!edit.ok) {
      this.toast(trf('草稿恢复不完整：{0}', edit.message));
      return false; // 草稿缓存保留，下次滑回头槽再试
    }
    this.working = edit.working ?? this.working;
    this.flowState = edit.flow !== null ? edit.flow.state : this.flowState;
    this.draftCache = null;
    return true;
  }

  /** WorkingCardInfo 深拷贝（全部字段为基础类型） */
  private cloneWorking(w: WorkingCardInfo): WorkingCardInfo {
    const c: WorkingCardInfo = new WorkingCardInfo();
    c.hasContent = w.hasContent;
    c.isPublic = w.isPublic;
    c.friendOnly = w.friendOnly;
    c.needApproval = w.needApproval;
    c.purpose = w.purpose;
    c.event = w.event;
    c.time = w.time;
    c.repeatTime = w.repeatTime;
    c.repeatUntil = w.repeatUntil;
    c.location = w.location;
    c.participant = w.participant;
    c.initiator = w.initiator;
    c.reminderTime = w.reminderTime;
    c.capacity = w.capacity;
    c.count = w.count;
    return c;
  }

  /** 冲突查询（cards.conflicts 33）：结果以 AI 消息展示 */
  private async doConflicts(): Promise<void> {
    if (this.aiThinking) {
      return;
    }
    this.aiThinking = true;
    const res: ConflictsOutcome = await ServerGateway.cardsConflicts();
    this.aiThinking = false;
    if (!res.ok) {
      this.pushAI(trf('冲突查询失败：{0}', res.message), []);
      return;
    }
    if (res.descriptions.length === 0) {
      this.pushAI(tr('当前卡片没有时间冲突，放心确定 ✅'), []);
      return;
    }
    this.pushAI(trf('发现 {0} 处时间冲突：\n· {1}', res.descriptions.length, res.descriptions.join('\n· ')), []);
  }

  /** 手动制作面板打开：从当前工作卡预填七个文本字段与三维度标签 */
  private openManualPanel(): void {
    this.mEvent = this.working.event;
    this.mTime = this.working.time;
    this.mLocation = this.working.location;
    this.mReminder = this.working.reminderTime;
    this.mPurpose = this.working.purpose;
    this.mRepeat = this.working.repeatTime;
    this.mRepeatUntil = this.working.repeatUntil;
    this.mType = this.working.type;
    this.mScene = this.working.scene;
    this.mTheme = this.working.theme;
    this.mTags = this.working.tags.map((t: string): string => `#${t}`).join(' ');
    this.manualVisible = true;
  }

  /** 手动写入工作卡（cards.edit 51）：七个文本字段整体覆盖（空串=清空），
   *  三维度标签选中才写入（未选 = 保持工作卡现状），写完仍用 ai.complete 7 入库 */
  private async doManualEdit(): Promise<void> {
    if (this.aiThinking) {
      return;
    }
    const event: string = this.mEvent.trim();
    if (event.length === 0) {
      this.toast(tr('事件不能为空（其余字段可留空）'));
      return;
    }
    this.aiThinking = true;
    const fields: Record<string, Object> = {
      'event': event,
      'time': this.mTime.trim(),
      'location': this.mLocation.trim(),
      'reminderTime': this.mReminder.trim(),
      'purpose': this.mPurpose.trim(),
      'repeatTime': this.mRepeat.trim(),
      'repeatUntil': this.mRepeatUntil.trim()
    };
    if (this.mType.length > 0) {
      fields['type'] = this.mType;
    }
    if (this.mScene.length > 0) {
      fields['scene'] = this.mScene;
    }
    if (this.mTheme.length > 0) {
      fields['theme'] = this.mTheme;
    }
    fields['tags'] = this.mTags.trim();
    const res: FlowOutcome = await ServerGateway.cardsEdit(fields);
    this.aiThinking = false;
    if (!res.ok) {
      this.toast(res.message);
      return;
    }
    this.working = res.working ?? new WorkingCardInfo();
    this.flowState = res.flow !== null ? res.flow.state : 0;
    this.manualVisible = false;
    const chips: string[] = this.flowState === 1 || this.flowState === 2 ? [tr('✅ 确定'), tr('🔄 重新开始')] : [];
    this.pushAI(tr('✍️ 手动内容已写入当前卡片。没问题就点「确定」入库，也可以继续让 AI 调整。'), chips);
  }

  /** 已写入卡片库的卡片 → 按目标组落位看板：选取确定 = 原位替换该卡（保留组内角色）；
   *  追加/新建 = 放进所在组列末尾；新建组时把新组头插到最右「新卡片组」列之前（原居中位即新组）。
   *  落位后清空本地工作卡快照与草稿缓存（服务器已同步重置），下一次设置从空白开始 */
  private addWrittenCard(card: WrittenCardInfo): void {
    const view: TaskCard = this.writtenToCard(card);
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
      const kept: TaskCard[] = [];
      let replaced: boolean = false;
      this.libraryCards.forEach((c: TaskCard) => {
        if (c.id === view.id) {
          view.isOwner = c.isOwner;
          kept.push(view);
          replaced = true;
        } else {
          kept.push(c);
        }
      });
      this.libraryCards = replaced ? kept : [...kept, view];
      if (!replaced && card.groupId > 0 && !this.headExists(card.groupId)) {
        const head: BoardHead = new BoardHead();
        head.groupId = card.groupId;
        head.name = card.groupName.length > 0 ? card.groupName : trf('卡片组 #{0}', card.groupId);
        head.isOwner = true;
        head.library = card.isPublic ? 'public' : 'private';
        const heads: BoardHead[] = [];
        let inserted: boolean = false;
        this.boardHeads.forEach((h: BoardHead) => {
          if (!inserted && h.groupId === 0) {
            heads.push(head);
            inserted = true;
          }
          heads.push(h);
        });
        this.boardHeads = inserted ? heads : [...heads, head];
      }
      this.working = new WorkingCardInfo();
      this.flowState = 0;
      this.draftCache = null;
    });
  }

  /** 看板列头定位：返回 undefined = 该组不在看板上（离线或已被删除） */
  private headOf(groupId: number): BoardHead | undefined {
    for (let i = 0; i < this.boardHeads.length; i++) {
      if (this.boardHeads[i].groupId === groupId) {
        return this.boardHeads[i];
      }
    }
    return undefined;
  }

  private headExists(groupId: number): boolean {
    return this.headOf(groupId) !== undefined;
  }

  /** 拉取我的卡片库（54：我创建/加入的卡片组）→ 看板真实分组列（组级摘要含空组，含成员组），
   *  最右端恒补一列虚拟「新卡片组」（顶端空卡，确定即服务器新建组收纳）；
   *  服务器侧已完成的卡不再上板（完成即归档为明信片，从卡片库消失） */
  private async loadLibrary(): Promise<void> {
    const outcome: LibraryListOutcome = await ServerGateway.myLibraryList();
    if (!outcome.ok) {
      return;
    }
    const heads: BoardHead[] = [];
    outcome.heads.forEach((h: LibraryGroupHead) => {
      const head: BoardHead = new BoardHead();
      head.groupId = h.groupId;
      head.name = h.groupName;
      head.isOwner = h.isOwner;
      head.library = h.library;
      heads.push(head);
    });
    const virtualHead: BoardHead = new BoardHead();
    virtualHead.name = tr('新卡片组');
    heads.push(virtualHead);
    this.boardHeads = heads;
    const cards: TaskCard[] = [];
    outcome.entries.forEach((entry: LibraryEntryInfo) => {
      if (entry.completed) {
        return;
      }
      cards.push(this.entryToCard(entry));
    });
    this.libraryCards = cards;
  }

  /** 卡片库条目 → 看板 TaskCard：id 用 srv-g{groupId}-{cardIndex} 稳定定位（删除时解析回传服务器），并记下组内角色 */
  private entryToCard(entry: LibraryEntryInfo): TaskCard {
    const view: TaskCard = this.writtenToCard(entry.card);
    if (entry.groupId > 0) {
      view.id = `srv-g${entry.groupId}-${entry.card.index}`;
    }
    view.groupId = entry.groupId;
    view.isOwner = entry.isOwner;
    return view;
  }

  /** 下拉刷新：重拉卡片库 + AI 工作卡状态（不动聊天记录），动画至少展示 600ms 再收起 */
  private handleRefresh(): void {
    const start: number = Date.now();
    this.doRefresh().then((): void => {
      const rest: number = Math.max(600 - (Date.now() - start), 0);
      setTimeout(() => {
        this.isRefreshing = false;
      }, rest);
    });
  }

  private async doRefresh(): Promise<void> {
    if (!appStore.serverOnline) {
      return;
    }
    await this.loadLibrary();
    if (this.aiReady) {
      const status: StatusOutcome = await ServerGateway.aiStatus();
      if (status.ok && status.configured) {
        this.working = status.working ?? new WorkingCardInfo();
        this.flowState = status.flow !== null ? status.flow.state : 0;
      }
    }
  }

  /** WrittenCardInfo → 看板 TaskCard：id 用 srv-g{groupId}-{index} 稳定定位
   *  （index = 服务器返回的组内编号：新建组首卡 1 / 追加进组为组内新编号 / 原位更新沿用原编号） */
  private writtenToCard(card: WrittenCardInfo): TaskCard {
    const title: string = card.event.length > 0 ? card.event
      : (card.purpose.length > 0 ? card.purpose : tr('新日程'));
    const added: TaskCard = TaskCard.of(card.groupId > 0 ? `srv-g${card.groupId}-${card.index}` : `srv-local-${card.index}`,
      title, CardKind.Schedule, CardStatus.Set,
      card.time.length > 0 ? friendlyTime(card.time) : tr('时间待定'),
      card.location.length > 0 ? card.location : tr('地点待定'), '✨');
    added.groupId = card.groupId;
    added.isOwner = true;
    const notes: string[] = [];
    if (card.reminderTime.length > 0) {
      notes.push(`⏰ ${friendlyTime(card.reminderTime)}`);
    }
    added.note = notes.join(' · ');
    added.tags = card.tags.slice();
    return added;
  }

  /** 工作卡 → 正中间卡片组顶端的卡片视图：正在填写时展示已收集字段，否则为空卡片占位（其余组为静态占位，见 ProjectBoard） */
  private workingViewCard(): TaskCard {
    const view: TaskCard = new TaskCard();
    view.id = 'working';
    view.kind = CardKind.Schedule;
    view.symbol = '✨';
    if (this.working.hasContent) {
      view.status = CardStatus.Set;
      view.title = this.working.event.length > 0 ? this.working.event
        : (this.working.purpose.length > 0 ? this.working.purpose : tr('新卡片'));
      view.timeText = this.working.time.length > 0 ? friendlyTime(this.working.time) : tr('时间待定');
      view.place = this.working.location;
      const parts: string[] = [];
      if (this.working.repeatTime.length > 0) {
        parts.push(`🔁 ${this.working.repeatTime}`);
      }
      if (this.working.reminderTime.length > 0) {
        parts.push(`⏰ ${friendlyTime(this.working.reminderTime)}`);
      }
      view.note = parts.join(' · ');
      view.confirmText = tr('⏳ 正在与 AI 设置 · 字段随对话更新');
    } else {
      view.status = CardStatus.Empty;
      view.title = tr('新卡片');
      view.timeText = tr('待定');
      view.place = tr('地点待定');
      view.confirmText = '';
    }
    return view;
  }

  /** ---------- 离线演示模式（原 mock 流程） ---------- */

  private appendNamedCard(text: string): void {
    this.idSeq += 1;
    const named: TaskCard = TaskCard.of(`u-${this.idSeq}`, text, CardKind.Schedule,
      CardStatus.Empty, tr('待定'), tr('地点待定'), '✨');
    this.libraryCards = [named, ...this.libraryCards];
    this.pendingCardId = named.id;
  }

  private flipCurrentEmptyCard(): void {
    const cards: TaskCard[] = this.libraryCards;
    const next: TaskCard[] = [];
    let flipped: boolean = false;
    cards.forEach((c: TaskCard) => {
      if (!flipped && c.status === CardStatus.Empty &&
        (this.pendingCardId.length === 0 || c.id === this.pendingCardId)) {
        this.idSeq += 1;
        const s: TaskCard = c.cloneWithId(`${c.id}-s-${this.idSeq}`);
        s.status = CardStatus.Set;
        s.timeText = '19:00';
        s.place = tr('图书馆三楼');
        s.flipToken = c.flipToken + 1;
        next.push(s);
        flipped = true;
      } else {
        next.push(c);
      }
    });
    this.libraryCards = next;
  }

  private finishGeneration(): void {
    this.chatStep = 9;
    const generated: TaskCard[] = [
      TaskCard.of(`g-${this.idSeq + 1}`, tr('单词打卡 Day 1'), CardKind.Task, CardStatus.Set, '19:00', tr('图书馆三楼'), '📖'),
      TaskCard.of(`g-${this.idSeq + 2}`, tr('听力精听半套'), CardKind.Task, CardStatus.Set, '20:00', tr('自习室 B203'), '🎧'),
      TaskCard.of(`g-${this.idSeq + 3}`, tr('阅读真题一篇'), CardKind.Task, CardStatus.Set, '21:00', tr('图书馆三楼'), '📄'),
      TaskCard.of(`g-${this.idSeq + 4}`, tr('错题复盘 30 分钟'), CardKind.Task, CardStatus.Set, '22:00', tr('宿舍'), '🔍'),
      TaskCard.of(`g-${this.idSeq + 5}`, tr('睡前词汇速刷'), CardKind.Task, CardStatus.Set, '23:00', tr('宿舍'), '🌙')
    ];
    this.idSeq += 5;
    let i: number = 0;
    for (i = 0; i < generated.length; i++) {
      const card: TaskCard = generated[i];
      const delay: number = 150 * (i + 1);
      setTimeout(() => {
        this.libraryCards = [...this.libraryCards, card];
      }, delay);
    }
    appStore.bumpUnread();
    this.pushAI(tr('已生成 5 张备考日程卡并加入「我的卡片库」✅ 18:30 会提醒你，每完成一张记得回来打卡！'), []);
  }

  private mockHandleChip(chip: string): void {
    this.pushUser(chip);
    if (this.chatStep === 0) {
      this.chatStep = 1;
      this.pushAI(tr('这个计划是为了什么？🤔'), [tr('考四六级'), tr('完成工作'), tr('兴趣使然')]);
      return;
    }
    if (this.chatStep === 1) {
      this.chatStep = 2;
      this.pushAI(tr('离考试还有 85 天 ⏳ 我建议今晚 19:00 背核心词 List 1-2，可以吗？'), [tr('可以呀'), tr('换个时间')]);
      return;
    }
    if (this.chatStep === 2) {
      if (trEq(chip, '可以呀')) {
        this.chatStep = 3;
        this.flipCurrentEmptyCard();
        this.pushAI(tr('已加入日程，18:30 提醒你。要生成整套备考日程纲吗？'), [tr('生成日程纲'), tr('先不用')]);
      } else {
        this.pushAI(tr('那我们改到 20:00 ？背完刚好赶上宿舍门禁 😴'), [tr('可以呀')]);
      }
      return;
    }
    if (this.chatStep === 3) {
      if (trEq(chip, '生成日程纲')) {
        this.chatStep = 4;
        this.pushAI(tr('AI 生成中…'), []);
        setTimeout(() => {
          this.finishGeneration();
        }, 1200);
      } else {
        this.chatStep = 9;
        this.pushAI(tr('好的，需要时随时叫我 😊'), []);
      }
      return;
    }
    this.pushAI(tr('先从手头的卡片开始吧，我随时在 ✨'), []);
  }

  private mockSend(text: string): void {
    this.pushUser(text);
    // 智能审核：离线演示与服务器 AI 同一套闸——脏输入不建演示卡，固定回复「请手动输入」
    if (!Backend.textPassesModeration(text)) {
      this.pushAI(tr('请手动输入'), []);
      return;
    }
    if (this.chatStep === 0) {
      this.appendNamedCard(text);
      this.chatStep = 1;
      this.pushAI(tr('这个计划是为了什么？🤔'), [tr('考四六级'), tr('完成工作'), tr('兴趣使然')]);
    } else {
      this.pushAI(tr('记下来了！点卡片或选上面的快捷回复继续 ✨'), []);
    }
  }

  /** 删除已入库卡片：本地卡直接移除；服务器卡（id 形如 srv-g{groupId}-{cardIndex}）按角色调用——
   *  创建者删组内卡片（groups.remove-card 57），参与者退出组内卡片（cards.leave 15）；成功后移除。
   *  创建者删除的卡不再兑现（无明信片）→ 该群本地聊天记录一并清掉 */
  private async handleDeleteCard(card: TaskCard): Promise<void> {
    const coords: number[] = this.parseServerCardId(card.id);
    if (coords.length === 2) {
      const res: MessageOutcome = card.isOwner
        ? await ServerGateway.groupRemoveCard(coords[0], coords[1])
        : await ServerGateway.cardsLeave(coords[0], coords[1]);
      if (!res.ok) {
        this.toast(trf('删除失败：{0}', res.message));
        return;
      }
      if (card.isOwner) {
        groupChatStore.deleteThread(appStore.getAccount(), coords[0]);
      }
    }
    if (card.id === this.pickedCardId) {
      // 被选取的卡片已删除：释放选取，随后的居中上报会自动同步新目标
      this.pickedCardId = '';
      this.suppressTargetId = '';
    }
    const next: TaskCard[] = [];
    this.libraryCards.forEach((c: TaskCard) => {
      if (c.id !== card.id) {
        next.push(c);
      }
    });
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
      this.libraryCards = next;
    });
    this.toast(tr('已从卡片库删除 ✅'));
  }

  /** Card.onFlipChange：卡片翻到背面升起全屏遮罩（缓存其页面坐标），翻回后收起 */
  private handleFlipChange(cardId: string, back: boolean, x: number, y: number, w: number, h: number): void {
    if (back) {
      this.flippedCardId = cardId;
      this.flipRectX = x;
      this.flipRectY = y;
      this.flipRectW = w;
      this.flipRectH = h;
      this.flipGuardActive = true;
      return;
    }
    if (cardId === this.flippedCardId) {
      this.flippedCardId = '';
      this.flipGuardActive = false;
    }
  }

  /** 遮罩点击：落在卡片区域内 → 广播确定；区域外 → 广播取消翻回 */
  private handleGuardTap(e: ClickEvent): void {
    const insideX: boolean = e.x >= this.flipRectX && e.x <= this.flipRectX + this.flipRectW;
    const insideY: boolean = e.y >= this.flipRectY && e.y <= this.flipRectY + this.flipRectH;
    if (insideX && insideY) {
      AppStorage.setOrCreate('flipConfirmToken', (AppStorage.get<number>('flipConfirmToken') ?? 0) + 1);
    } else {
      AppStorage.setOrCreate('flipCancelToken', (AppStorage.get<number>('flipCancelToken') ?? 0) + 1);
    }
  }

  /** ---------- 统一入口 ---------- */

  private async handleSend(): Promise<void> {
    const text: string = this.buffer.trim();
    if (text.length === 0 || this.aiThinking) {
      return;
    }
    this.buffer = '';
    if (this.aiReady) {
      await this.sendToAi(text);
      return;
    }
    this.mockSend(text);
  }

  private handleChip(chip: string): void {
    if (this.aiReady) {
      if (trEq(chip, '✅ 确定')) {
        this.doComplete();
        return;
      }
      if (trEq(chip, '🔄 重新开始')) {
        this.doReset();
        return;
      }
      this.sendToAi(chip);
      return;
    }
    this.mockHandleChip(chip);
  }

  /** 手动制作面板（顶部抽屉，键盘弹出不遮挡输入）：七个文本字段整体写入工作卡 */
  @Builder
  private ManualFormPanel(): void {
    Column() {
      Column({ space: 12 }) {
        Row() {
          Text(tr('✍️ 手动制作卡片'))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text('✕')
            .fontSize(Theme.fontBody)
            .fontColor($r('app.color.text_tertiary'))
            .onClick(() => {
              this.manualVisible = false;
            })
        }
        .width('100%')

        Text(tr('直接填写卡片字段：留空 = 清空该字段。写入后同步到当前工作卡，点聊天里的「确定」即可入库。'))
          .fontSize(Theme.fontTag)
          .fontColor($r('app.color.text_tertiary'))
        Text(tr('类型 / 场景 / 主题三个维度标签为必选（点选）：用于积分计算、周报统计、推荐与筛选，卡片上不展示；未选维度保持现状。'))
          .fontSize(Theme.fontTag)
          .fontColor($r('app.color.text_tertiary'))

        Scroll() {
          Column({ space: 10 }) {
            ManualField({
              label: tr('事件 *'), value: this.mEvent, hint: tr('要做什么，如：周六羽毛球局'),
              onInput: (v: string) => {
                this.mEvent = v;
              }
            })
            ManualField({
              label: tr('时间'), value: this.mTime, hint: tr('2026-10-03 19:00（绝对时间，可填区间）'),
              onInput: (v: string) => {
                this.mTime = v;
              }
            })
            ManualField({
              label: tr('地点'), value: this.mLocation, hint: tr('在哪里'),
              onInput: (v: string) => {
                this.mLocation = v;
              }
            })
            ManualField({
              label: tr('提醒时间'), value: this.mReminder, hint: tr('2026-10-03 18:30（绝对时间）'),
              onInput: (v: string) => {
                this.mReminder = v;
              }
            })
            ManualField({
              label: tr('目的 / 说明'), value: this.mPurpose, hint: tr('为什么做这件事'),
              onInput: (v: string) => {
                this.mPurpose = v;
              }
            })
            ManualField({
              label: tr('重复'), value: this.mRepeat, hint: tr('如：每周六 09:00'),
              onInput: (v: string) => {
                this.mRepeat = v;
              }
            })
            ManualField({
              label: tr('重复截止'), value: this.mRepeatUntil, hint: tr('如：2026-12-31'),
              onInput: (v: string) => {
                this.mRepeatUntil = v;
              }
            })
            TagPicker({
              label: tr('类型 *（这是什么性质的事）'),
              options: typeTagOptions(),
              selected: this.mType,
              onPick: (key: string) => {
                this.mType = key;
              }
            })
            TagPicker({
              label: tr('场景 *（在哪里做）'),
              options: sceneTagOptions(),
              selected: this.mScene,
              onPick: (key: string) => {
                this.mScene = key;
              }
            })
            TagPicker({
              label: tr('主题 *（关于什么内容）'),
              options: themeTagOptions(),
              selected: this.mTheme,
              onPick: (key: string) => {
                this.mTheme = key;
              }
            })
            ManualField({
              label: tr('话题标签'),
              value: this.mTags,
              hint: tr('如：#晨读 #英语 · 最多 5 个、每个 ≤12 字；留空 = 清空（AI 也会自动提炼）'),
              onInput: (v: string) => {
                this.mTags = v;
              }
            })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        Text(this.aiThinking ? tr('写入中…') : tr('写入工作卡'))
          .fontSize(Theme.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .width('100%')
          .height(44)
          .textAlign(TextAlign.Center)
          .linearGradient({
            angle: 135,
            colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
          })
          .borderRadius(Theme.radiusBtn)
          .onClick(() => {
            this.doManualEdit();
          })
      }
      .width('100%')
      .height('62%')
      .padding(Theme.spaceLg)
      .backgroundColor($r('app.color.bg_page'))
      .borderRadius({ bottomLeft: Theme.radiusModal, bottomRight: Theme.radiusModal })

      Column()
        .layoutWeight(1)
        .width('100%')
        .onClick(() => {
          this.manualVisible = false;
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.overlay_mask'))
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 10 }) {
          Text('‹')
            .fontSize(24)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
          Text(tr('记日程'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.aiReady ? tr('🤖 服务器 AI') : tr('🍊 离线演示 AI'))
            .fontSize(Theme.fontTag)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        Column() {
          ProjectBoard({
            heads: this.boardHeads,
            cards: this.libraryCards,
            workingCard: this.workingViewCard(),
            showWorking: this.aiReady,
            pickedCardId: this.pickedCardId,
            onDeleteCard: (c: TaskCard) => {
              this.handleDeleteCard(c);
            },
            onWorkingConfirm: () => {
              this.doComplete();
            },
            onCenteredCardChange: (groupId: number, card: TaskCard | null) => {
              this.handleCenteredCardChange(groupId, card);
            },
            onFlipChange: (cardId: string, back: boolean, x: number, y: number, w: number, h: number) => {
              this.handleFlipChange(cardId, back, x, y, w, h);
            }
          })
        }
        .layoutWeight(3)
        .width('100%')
        .constraintSize({ minHeight: this.kbHeight > 0 ? 190 : 260 })
        .justifyContent(FlexAlign.Center)

        if (this.aiReady) {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text(tr('取消'))
                .fontSize(Theme.fontTag)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.brandDeep())
                .layoutWeight(1)
                .height(32)
                .textAlign(TextAlign.Center)
                .backgroundColor(Theme.brandSoft())
                .borderRadius(8)
                .onClick(() => {
                  this.doReset();
                })
              Text(tr('✍️ 手动'))
                .fontSize(Theme.fontTag)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.brandDeep())
                .layoutWeight(1)
                .height(32)
                .textAlign(TextAlign.Center)
                .backgroundColor(Theme.brandSoft())
                .borderRadius(8)
                .onClick(() => {
                  this.openManualPanel();
                })
              Text(tr('冲突查询'))
                .fontSize(Theme.fontTag)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.brandDeep())
                .layoutWeight(1)
                .height(32)
                .textAlign(TextAlign.Center)
                .backgroundColor(Theme.brandSoft())
                .borderRadius(8)
                .onClick(() => {
                  this.doConflicts();
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusBtn)
          .border({ width: 1, color: $r('app.color.divider') })
          .margin({ left: 20, right: 20 })
        }

        Column() {
          Refresh({ refreshing: $$this.isRefreshing }) {
            List({ space: 10, scroller: this.chatScroller }) {
              ForEach(this.chatMsgs, (m: ChatMsg) => {
                ListItem() {
                  ChatBubble({
                    msg: m,
                    onChipTap: (chip: string) => {
                      this.handleChip(chip);
                    }
                  })
                }
              }, (m: ChatMsg) => m.id)
            }
            .height('100%')
            .width('100%')
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          }
          .layoutWeight(1)
          .width('100%')
          .onRefreshing(() => {
            this.handleRefresh();
          })

          if (this.aiThinking) {
            Text(tr('AI 正在思考… 🤔'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
              .padding({ top: 2, bottom: 2 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }

          Row({ space: 8 }) {
            TextInput({ placeholder: this.aiReady ? tr('说说你的安排，AI 帮你成卡') : tr('和 AI 聊聊…'), text: this.buffer })
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.input_bg'))
              .borderRadius(Theme.radiusBtn)
              .height(40)
              .padding({ left: 12, right: 12 })
              .layoutWeight(1)
              .enabled(!this.aiThinking)
              .onFocus(() => {
                this.inputFocused = true;
                setTimeout(() => {
                  if (this.chatMsgs.length > 0) {
                    this.chatScroller.scrollToIndex(this.chatMsgs.length - 1);
                  }
                }, 350);
              })
              .onBlur(() => {
                this.inputFocused = false;
              })
              .onChange((value: string) => {
                this.buffer = value;
              })
            Text(this.aiThinking ? '…' : tr('发送'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .width(64)
              .height(40)
              .textAlign(TextAlign.Center)
              .linearGradient({
                angle: 135,
                colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
              })
              .borderRadius(Theme.radiusBtn)
              .onClick(() => {
                this.handleSend();
              })
          }
          .width('100%')
          .padding({ top: 8 })
        }
        .layoutWeight(2)
        .width('100%')
        .padding({ left: 20, right: 20, bottom: this.inputFocused ? 18 : 8 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      .padding({ bottom: Math.max(this.kbHeight - this.kbLiftTrim, 0) })

      if (this.flipGuardActive) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.guard_mask'))
          .onClick((e: ClickEvent) => {
            this.handleGuardTap(e);
          })
      }

      if (this.manualVisible) {
        this.ManualFormPanel()
      }
    }
    .width('100%')
    .height('100%')
  }
}

/** 看板卡片组列：与服务器真实卡片组（54 组级摘要）或最右虚拟「新卡片组」列对应 */
class BoardGroup {
  /** 服务器卡片组号（0 = 虚拟「新卡片组」列） */
  id: number = 0;
  name: string = '';
  cards: TaskCard[] = [];

  constructor(id: number, name: string, cards: TaskCard[]) {
    this.id = id;
    this.name = name;
    this.cards = cards;
  }
}

/** 看板列头（宿主页 → ProjectBoard）：与服务器真实卡片组一一对应；
 *  groupId=0 为最右端虚拟「新卡片组」列，顶端空卡确定后服务器新建同名组 */
class BoardHead {
  /** 服务器卡片组号；0 = 虚拟「新卡片组」列 */
  groupId: number = 0;
  name: string = '';
  /** 我在组内的角色：true = 创建者（可在顶端空卡确定时往组里加卡） */
  isOwner: boolean = true;
  /** 虚拟「新卡片组」列标记（列头带 ✨ 前缀） */
  isNew: boolean = false;
  /** public=公开卡片组库 private=私人卡片组库 */
  library: string = '';
}

/** 手动制作面板的单行字段：标签 + 输入框（输入经 onInput 回调同步宿主页状态） */
@Component
struct ManualField {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop hint: string = '';
  onInput: (v: string) => void = (_v: string) => {};

  build() {
    Column({ space: 4 }) {
      Text(this.label)
        .fontSize(Theme.fontTag)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_secondary'))
      TextInput({ text: this.value, placeholder: this.hint })
        .fontSize(Theme.fontCaption)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(Theme.radiusBtn)
        .height(40)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.onInput(v);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 我的卡片库：真实卡片组看板。
 * 每列对应一个服务器真实卡片组（heads：我创建/加入的组，含空组），列内纵向滑动逐张查看；
 * 每列顶端恒为一张空卡片：居中列顶端为「正在设置卡片」（AI 对话实时修改），其余列顶端为静态空卡占位；
 * 页面最右端恒为虚拟「✨ 新卡片组」列（仅顶端空卡），其上确定 = 服务器新建同名组收纳。
 * 屏幕正中间的卡片在哪个卡片组里，确定后就记录进哪个卡片组（onCenteredCardChange 上报列号 + 卡片）：
 * 滑到已入库卡片上时宿主页调 cards.pick（76）把它载入工作卡，该卡片槽位随即渲染实时工作卡视图；
 * 滑回头槽（新卡片位）自动释放选取并还原草稿。
 * 工作卡视图（头槽 / 被选取槽位）可点击翻转露出背面「确定」，再点一次翻回并触发 onWorkingConfirm 执行确定。
 * 已入库卡片正面上角为「删除」按钮：点卡片本体不翻面，点「删除」翻到背面，再点卡片（或遮罩命中）
 * 翻回并触发 onDeleteCard 执行删除，点卡片外部翻回取消；卡片背面停留时通过 onFlipChange 通知宿主页升起遮罩。
 */
@Component
struct ProjectBoard {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop @Watch('onBoardPropChanged') heads: BoardHead[] = [];
  @Prop @Watch('onBoardPropChanged') cards: TaskCard[] = [];
  /** 顶端工作卡视图（正在填写的新卡片 / 空卡片占位） */
  @Prop workingCard: TaskCard = new TaskCard();
  /** 服务器 AI 模式：每组顶端展示工作卡 */
  @Prop showWorking: boolean = false;
  /** 被选取为编辑目标的已入库卡片 id（空 = 新卡片模式）：该卡片槽位渲染实时工作卡视图 */
  @Prop pickedCardId: string = '';
  /** 当前展示的卡片组索引（导航点高亮） */
  @State groupIndex: number = 0;
  /** 各组内当前竖向页索引（与列头顺序平行） */
  @State cardIndexes: number[] = [];
  /** 最近上报的居中卡片 id（'' = 头槽新卡片位）：卡片数组替换后按它保持居中不跳位 */
  private lastCenteredId: string = '';
  onDeleteCard: (card: TaskCard) => void = () => {};
  onWorkingConfirm: () => void = () => {};
  /** 居中卡片变化上报：groupId = 居中列的组号（0 = 新卡片组列），card 为 null = 头槽（新卡片位） */
  onCenteredCardChange: (groupId: number, card: TaskCard | null) => void = () => {};
  onFlipChange: (cardId: string, back: boolean, x: number, y: number, w: number, h: number) => void = () => {};

  /** 组装看板列：每列 = 顶端空卡（居中列为实时工作卡 / 其余为静态占位）+ 该组全部入库卡
   *  （被选取卡片槽位渲染实时工作卡视图）；离线模式（无工作卡）时空列不展示 */
  private groupsOf(): BoardGroup[] {
    const groups: BoardGroup[] = [];
    for (let i = 0; i < this.heads.length; i++) {
      const head: BoardHead = this.heads[i];
      const list: TaskCard[] = [];
      if (this.showWorking) {
        if (i === this.groupIndex) {
          if (this.pickedCardId === '') {
            list.push(this.workingViewFor());
          } else {
            list.push(this.newCardIdle());
          }
        } else {
          list.push(this.idleSlotCard(i));
        }
      }
      for (let j = 0; j < this.cards.length; j++) {
        if (this.cards[j].groupId === head.groupId) {
          if (i === this.groupIndex && this.cards[j].id === this.pickedCardId) {
            list.push(this.pickedViewFor(this.cards[j]));
          } else {
            list.push(this.cards[j]);
          }
        }
      }
      if (list.length > 0) {
        groups.push(new BoardGroup(head.groupId, head.isNew ? `✨ ${head.name}` : `🗂️ ${head.name}`, list));
      }
    }
    return groups;
  }

  /** 居中列顶端的工作卡视图：内容随对话更新（配色沿用工作卡视图本身） */
  private workingViewFor(): TaskCard {
    return this.workingCard.cloneWithId(this.workingCard.id);
  }

  /** 被选取卡片槽位的实时工作卡视图：内容跟随工作卡（AI 对话 / 手动制作即时呈现），
   *  id、类型与符号沿用原卡片（翻面遮罩与键值签名保持定位） */
  private pickedViewFor(c: TaskCard): TaskCard {
    const view: TaskCard = this.workingCard.cloneWithId(c.id);
    view.kind = c.kind;
    view.symbol = c.symbol;
    return view;
  }

  /** 选取模式下头槽的静态占位：滑回这里（正中间）即回到「新卡片」模式 */
  private newCardIdle(): TaskCard {
    const idle: TaskCard = TaskCard.of('new-card-idle', tr('新卡片'), CardKind.Schedule, CardStatus.Empty,
      tr('待定'), tr('地点待定'), '✨');
    idle.confirmText = tr('正在设置选中的卡片 · 滑回这里开始新卡片');
    return idle;
  }

  /** 非居中列顶端的静态空卡占位：不被 AI 对话修改，滑到正中间才接管编辑 */
  private idleSlotCard(kindIndex: number): TaskCard {
    const idle: TaskCard = TaskCard.of(`idle-slot-${kindIndex}`, tr('新卡片'), CardKind.Schedule, CardStatus.Empty,
      tr('待定'), tr('地点待定'), '✨');
    idle.confirmText = tr('把本组滑到屏幕正中间即可编辑');
    return idle;
  }

  /** 该槽位是否为「正在设置卡片」的实时视图槽：新卡片模式 = 居中组头槽；选取模式 = 被选取卡片槽位。
   *  决定点击翻转背面文案（确定）与 onSequenceDone 路由（确定入库 / 删除） */
  private isWorkingSlot(gi: number, ci: number, c: TaskCard): boolean {
    if (!this.showWorking || gi !== this.groupIndex) {
      return false;
    }
    return this.pickedCardId === '' ? ci === 0 : c.id === this.pickedCardId;
  }

  /** 解析当前居中列与居中卡片并上报（card 为 null = 头槽新卡片位；组号一并上报，
   *  宿主页据此决定「确定」落进哪个卡片组），同步维护 lastCenteredId 供数组替换后定位 */
  private reportCentered(): void {
    const groups: BoardGroup[] = this.groupsOf();
    if (groups.length === 0) {
      this.lastCenteredId = '';
      this.onCenteredCardChange(0, null);
      return;
    }
    const gi: number = Math.min(this.groupIndex, groups.length - 1);
    const g: BoardGroup = groups[gi];
    const ci: number = Math.min(this.cardIndexes.length > gi ? this.cardIndexes[gi] : 0,
      Math.max(g.cards.length - 1, 0));
    if (this.showWorking && ci === 0) {
      this.lastCenteredId = '';
      this.onCenteredCardChange(g.id, null);
      return;
    }
    this.lastCenteredId = g.cards[ci].id;
    this.onCenteredCardChange(g.id, g.cards[ci]);
  }

  /** 列头 / 卡片数组替换（确定入库 / 删除 / 刷新）：按 lastCenteredId 重新定位居中卡片（不跳位）后上报 */
  private onBoardPropChanged(): void {
    if (this.lastCenteredId !== '') {
      const groups: BoardGroup[] = this.groupsOf();
      if (groups.length > 0) {
        const gi: number = Math.min(this.groupIndex, groups.length - 1);
        const g: BoardGroup = groups[gi];
        for (let i = 0; i < g.cards.length; i++) {
          if (g.cards[i].id === this.lastCenteredId) {
            if ((this.cardIndexes.length > gi ? this.cardIndexes[gi] : 0) !== i) {
              this.syncCardIndex(gi, i);
            }
            break;
          }
        }
      }
    }
    this.reportCentered();
  }

  /** 组内竖向翻页后同步位置角标（整组数组替换，保证 V1 刷新） */
  private syncCardIndex(gi: number, index: number): void {
    const total: number = this.groupsOf().length;
    const next: number[] = [];
    for (let i = 0; i < total; i++) {
      if (i === gi) {
        next.push(index);
      } else {
        next.push(this.cardIndexes.length > i ? this.cardIndexes[i] : 0);
      }
    }
    this.cardIndexes = next;
  }

  /** 组头右侧「x/y 张」位置角标 */
  private posText(gi: number, total: number): string {
    const cur: number = this.cardIndexes.length > gi ? this.cardIndexes[gi] : 0;
    return trf('{0}/{1} 张', Math.min(cur + 1, total), total);
  }

  /** 卡片内容签名：V1 ForEach 同键值会复用旧组件导致数据不刷新，键值必须反映可变内容（工作卡字段随 AI 对话更新） */
  private cardSig(c: TaskCard): string {
    return `${c.id}|${c.kind}|${c.status}|${c.symbol}|${c.title}|${c.dateText}|${c.timeText}|${c.place}|${c.note}|${c.confirmText}|${c.flipToken}`;
  }

  /** 卡片组键值：组号 + 组名 + 全部卡片内容签名，任一卡片内容变化即触发该组重建刷新 */
  private groupKey(g: BoardGroup): string {
    const sigs: string[] = [];
    for (let i = 0; i < g.cards.length; i++) {
      sigs.push(this.cardSig(g.cards[i]));
    }
    return `${g.id}#${g.name}#${sigs.join(';')}`;
  }

  build() {
    Column({ space: Theme.spaceSm }) {
      if (this.groupsOf().length === 0) {
        EmptyState({
          emoji: '🗂️',
          title: tr('卡片库还是空的'),
          subtitle: tr('在下方和 AI 聊聊，确定后卡片会出现在这里')
        })
      } else {
        Swiper() {
          ForEach(this.groupsOf(), (g: BoardGroup, gi: number) => {
            Column({ space: Theme.spaceSm }) {
              Row() {
                Text(g.name)
                  .fontSize(Theme.fontCaption)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.posText(gi, g.cards.length))
                  .fontSize(Theme.fontTag)
                  .fontColor($r('app.color.text_tertiary'))
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .backgroundColor($r('app.color.chip_bg'))
                  .borderRadius(Theme.radiusTag)
              }
              .width('100%')

              Swiper() {
                ForEach(g.cards, (c: TaskCard, ci: number) => {
                  Card({
                    card: c,
                    interactive: true,
                    cardHeight: 168,
                    deleteMode: !this.isWorkingSlot(gi, ci, c) && c.status !== CardStatus.Empty,
                    onSequenceDone: (done: TaskCard) => {
                      if (this.isWorkingSlot(gi, ci, done)) {
                        this.onWorkingConfirm();
                      } else {
                        this.onDeleteCard(done);
                      }
                    },
                    onFlipChange: (cardId: string, back: boolean, x: number, y: number, w: number, h: number) => {
                      this.onFlipChange(cardId, back, x, y, w, h);
                    }
                  })
                }, (c: TaskCard, ci: number) => `${ci}#${this.cardSig(c)}`)
              }
              .width('100%')
              .height(168)
              .index(Math.min(this.cardIndexes.length > gi ? this.cardIndexes[gi] : 0, Math.max(g.cards.length - 1, 0)))
              .vertical(true)
              .loop(false)
              .indicator(false)
              .onChange((index: number) => {
                this.syncCardIndex(gi, index);
                if (gi === this.groupIndex) {
                  this.reportCentered();
                }
              })
            }
            .width('100%')
            .padding(Theme.spaceMd)
            .backgroundColor($r('app.color.nav_bg'))
            .borderRadius(Theme.radiusModal)
            .border({ width: 1, color: $r('app.color.divider') })
          }, (g: BoardGroup, gi: number) => `${gi}#${this.groupKey(g)}`)
        }
        .width(Theme.boardCardWidth() + 24)
        .height(224)
        .loop(false)
        .indicator(false)
        .onChange((index: number) => {
          this.groupIndex = index;
          this.reportCentered();
        })

        if (this.groupsOf().length > 1) {
          Row({ space: 6 }) {
            ForEach(this.groupsOf(), (g: BoardGroup, gi: number) => {
              Column()
                .width(gi === this.groupIndex ? 14 : 6)
                .height(6)
                .borderRadius(3)
                .backgroundColor(gi === this.groupIndex ? Theme.brand() : $r('app.color.divider'))
            }, (g: BoardGroup, gi: number) => `${gi}-${g.id}`)
          }
        }
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
