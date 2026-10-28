import { TaskCard, CardStatus } from '../model/Types';
import { ServerMapper, WeatherOutcome } from '../net/ServerModels';
import { ServerGateway } from '../net/ServerGateway';
import { WeatherTips } from '../common/WeatherTips';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 锁屏卡片共享逻辑：
 * - 从卡片列表挑「最近的未完成/打卡卡片」（今天在重复区间内优先今天，否则最早的将来日期）
 * - 构建 formBindingData 载荷（卡片页 @LocalStorageProp 同名字段）
 * - 锁屏卡片实例 id 持久化（files/lock-card-ids.txt，主进程与卡片进程共享沙箱）
 * 应用侧（SchedulePage）与卡片进程（CardFormAbility）共用，保证锁屏与应用内数据一致
 */
export class FormCardData {
  /** 卡片的下一个有效日期：今天在重复区间内 = 今天；将来的单日/首日 = dateText；过期返回空（不展示） */
  static nextActiveDate(c: TaskCard, todayIso: string): string {
    if (c.repeatEndDate.length === 10) {
      if (c.dateText <= todayIso && todayIso <= c.repeatEndDate) {
        return todayIso;
      }
      if (c.dateText > todayIso) {
        return c.dateText;
      }
      return '';
    }
    return c.dateText >= todayIso ? c.dateText : '';
  }

  /** 最近的未完成卡片：按（下一有效日期，时间）升序取第一张 */
  static pickNextCard(cards: TaskCard[], todayIso: string): TaskCard | undefined {
    let best: TaskCard | undefined = undefined;
    let bestKey: string = '';
    for (let i = 0; i < cards.length; i++) {
      const c: TaskCard = cards[i];
      if (c.status === CardStatus.Done) {
        continue;
      }
      const active: string = FormCardData.nextActiveDate(c, todayIso);
      if (active.length !== 10) {
        continue;
      }
      const key: string = `${active}|${c.timeText}`;
      if (best === undefined || key < bestKey) {
        best = c;
        bestKey = key;
      }
    }
    return best;
  }

  /** 今天/明天/M月d日 */
  static dateLabelOf(iso: string, todayIso: string): string {
    if (iso === todayIso) {
      return '今天';
    }
    const parts: string[] = iso.split('-');
    if (parts.length !== 3) {
      return iso;
    }
    const tomorrow: Date = new Date();
    tomorrow.setDate(tomorrow.getDate() + 1);
    const mm: string = tomorrow.getMonth() + 1 < 10 ? `0${tomorrow.getMonth() + 1}` : `${tomorrow.getMonth() + 1}`;
    const dd: string = tomorrow.getDate() < 10 ? `0${tomorrow.getDate()}` : `${tomorrow.getDate()}`;
    if (iso === `${tomorrow.getFullYear()}-${mm}-${dd}`) {
      return '明天';
    }
    return `${Number(parts[1])}月${Number(parts[2])}日`;
  }

  /** 延时目标时刻（服务器格式 yyyy-MM-dd HH:mm）：卡片计划开始时间 + minutes 分钟，解析不了回退当前时刻 */
  static extendTimeOf(c: TaskCard, minutes: number): string {
    let base: Date = new Date();
    if (c.dateText.length === 10 && c.timeText.length === 5) {
      const dParts: string[] = c.dateText.split('-');
      const tParts: string[] = c.timeText.split(':');
      if (dParts.length === 3 && tParts.length === 2) {
        const dt: Date = new Date(Number(dParts[0]), Number(dParts[1]) - 1, Number(dParts[2]),
          Number(tParts[0]), Number(tParts[1]), 0, 0);
        if (!Number.isNaN(dt.getTime())) {
          base = dt;
        }
      }
    }
    const target: Date = new Date(base.getTime() + minutes * 60000);
    return FormCardData.fmtYyyyMmDdHm(target);
  }

  /** "yyyy-MM-dd HH:mm" */
  static fmtYyyyMmDdHm(dt: Date): string {
    const mm: string = dt.getMonth() + 1 < 10 ? `0${dt.getMonth() + 1}` : `${dt.getMonth() + 1}`;
    const dd: string = dt.getDate() < 10 ? `0${dt.getDate()}` : `${dt.getDate()}`;
    const hh: string = dt.getHours() < 10 ? `0${dt.getHours()}` : `${dt.getHours()}`;
    const mi: string = dt.getMinutes() < 10 ? `0${dt.getMinutes()}` : `${dt.getMinutes()}`;
    return `${dt.getFullYear()}-${mm}-${dd} ${hh}:${mi}`;
  }

  /**
   * 构建锁屏卡片载荷：card 为空 = 无进行中卡片（空态）。
   * 按钮可见性与应用内规则一致：完成/打卡仅指定完成者；取消仅发起者；延时仅服务器卡；
   * 本地演示卡不能在卡片进程完成（碎卡动画在应用内）→ 主按钮为「去完成」（router 打开应用）。
 * 天气话术（WeatherTips）随载荷下发：有卡时为按钮下方独立居中一行（weatherTip）；
 * 空态标题「暂没有日程安排」+ weatherTip（`但话术`，无话术为空串）两行展示。
   */
  static buildPayload(card: TaskCard | undefined, account: string, feedback: string, busy: number): Record<string, Object> {
    const payload: Record<string, Object> = {};
    payload['feedback'] = feedback;
    payload['busy'] = busy > 0 ? '1' : '0';
    // 主进程与卡片进程共用同一份天气快照（weather.txt，同沙箱）；未初始化/无快照时话术为空
    const weather: WeatherOutcome | null = ServerGateway.weatherSnapshot();
    const tip: string = WeatherTips.topTipOf(weather);
    if (card === undefined) {
      payload['hasCard'] = '0';
      payload['symbol'] = '🌱';
      payload['title'] = '暂没有日程安排';
      payload['dateLabel'] = '';
      // 空态：仅剩一次性操作反馈时展示反馈（如刚在卡片上完成）；否则标题 + 「但话术」两行
      payload['timeLine'] = feedback;
      payload['weatherTip'] = feedback.length > 0 ? '' : (tip.length > 0 ? `但${tip}` : '');
      payload['primaryLabel'] = '';
      payload['primaryKind'] = '';
      payload['activeDate'] = '';
      payload['canDelay'] = '0';
      payload['canCancel'] = '0';
      payload['cardId'] = '';
      payload['groupId'] = '';
      payload['cardIndex'] = '';
      return payload;
    }
    const todayIso: string = FormCardData.todayIso();
    const active: string = FormCardData.nextActiveDate(card, todayIso);
    const isServer: boolean = card.id.indexOf('srv-g') === 0 && card.groupId > 0;
    let primaryKind: string = '';
    let primaryLabel: string = '';
    if (isServer) {
      // 完成者固定为发起者本人：锁屏「完成/打卡」按钮仅创建者可见（62 服务器侧同样仅发起者可完成）
      if (card.isOwner) {
        if (card.repeatEndDate.length === 10 && active.length === 10 && active < card.repeatEndDate) {
          primaryKind = 'checkin';
          primaryLabel = '📍 打卡';
        } else {
          primaryKind = 'complete';
          primaryLabel = '✓ 完成';
        }
      }
    } else {
      primaryKind = 'open';
      primaryLabel = '去完成';
    }
    payload['hasCard'] = '1';
    payload['symbol'] = card.symbol.length > 0 ? card.symbol : '📅';
    payload['title'] = card.title;
    payload['dateLabel'] = active.length === 10 ? FormCardData.dateLabelOf(active, todayIso) : '';
    payload['activeDate'] = active;
    const placePart: string = card.place.length > 0 ? ` · 📍${card.place}` : '';
    payload['timeLine'] = feedback.length > 0 ? feedback : `🕒 ${card.timeText}${placePart}`;
    payload['weatherTip'] = tip;
    payload['primaryLabel'] = primaryLabel;
    payload['primaryKind'] = primaryKind;
    payload['canDelay'] = isServer ? '1' : '0';
    payload['canCancel'] = isServer && card.isOwner ? '1' : '0';
    payload['cardId'] = card.id;
    payload['groupId'] = `${card.groupId}`;
    const parts: string[] = card.id.split('-');
    payload['cardIndex'] = parts.length === 3 ? parts[2] : '';
    return payload;
  }

  static todayIso(): string {
    const now: Date = new Date();
    const mm: string = now.getMonth() + 1 < 10 ? `0${now.getMonth() + 1}` : `${now.getMonth() + 1}`;
    const dd: string = now.getDate() < 10 ? `0${now.getDate()}` : `${now.getDate()}`;
    return `${now.getFullYear()}-${mm}-${dd}`;
  }
}

/** 锁屏卡片上按钮动作（postCardAction params / EntryAbility want.parameters 载荷） */
export class LockAction {
  action: string = '';
  cardId: string = '';
  /** 打卡目标日期 yyyy-MM-dd（重复卡的下一有效日；打卡记录在应用内按它写入） */
  date: string = '';

  /** 解析 message 事件的 JSON 字符串 / AppStorage 里主进程消费的 JSON，解析失败返回 action='' */
  static parse(text: string): LockAction {
    const out: LockAction = new LockAction();
    if (text.length === 0) {
      return out;
    }
    try {
      const parsed: Object | null = JSON.parse(text) as Object | null;
      const rec: Record<string, Object> | null = ServerMapper.toRecord(parsed);
      if (rec !== null) {
        // message 事件用 'act'（顶层 action 被包裹层 'message' 占用）；router→AppStorage 路径仍用 'action'
        const act: string = ServerMapper.text(rec, 'act');
        out.action = act.length > 0 ? act : ServerMapper.text(rec, 'action');
        out.cardId = ServerMapper.text(rec, 'cardId');
        out.date = ServerMapper.text(rec, 'date');
      }
    } catch (e) {
      return out;
    }
    return out;
  }
}

/** 已添加的锁屏卡片实例 id（files/lock-card-ids.txt）：主进程据此在数据变化后主动 formProvider.updateForm */
export class FormIds {
  private static readonly FILE_NAME: string = 'lock-card-ids.txt';

  private static pathOf(ctx: common.Context): string {
    return `${ctx.filesDir}/${FormIds.FILE_NAME}`;
  }

  static list(ctx: common.Context): string[] {
    const path: string = FormIds.pathOf(ctx);
    try {
      if (!fileIo.accessSync(path)) {
        return [];
      }
      const text: string = fileIo.readTextSync(path);
      return text.split('\n').filter((s: string) => s.length > 0);
    } catch (e) {
      return [];
    }
  }

  static add(ctx: common.Context, formId: string): void {
    if (formId.length === 0) {
      return;
    }
    try {
      const ids: string[] = FormIds.list(ctx);
      if (ids.indexOf(formId) >= 0) {
        return;
      }
      ids.push(formId);
      FormIds.writeAll(ctx, ids);
    } catch (e) {
    }
  }

  static remove(ctx: common.Context, formId: string): void {
    if (formId.length === 0) {
      return;
    }
    try {
      const ids: string[] = FormIds.list(ctx);
      const next: string[] = ids.filter((s: string) => s !== formId);
      if (next.length === ids.length) {
        return;
      }
      FormIds.writeAll(ctx, next);
    } catch (e) {
    }
  }

  /** 全量回写卡片实例 id 列表（一行一个） */
  private static writeAll(ctx: common.Context, ids: string[]): void {
    const file = fileIo.openSync(FormIds.pathOf(ctx),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, ids.length > 0 ? ids.join('\n') + '\n' : '');
    fileIo.closeSync(file);
  }
}
