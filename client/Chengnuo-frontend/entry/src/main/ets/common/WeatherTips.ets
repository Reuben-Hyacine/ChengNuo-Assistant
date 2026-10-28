import { WeatherOutcome, WeatherDayInfo, WeatherIndexInfo } from '../net/ServerModels';
import { tr } from './I18n';

/**
 * 天气话术库：从天气结果里判定「当前最需要注意」的一条生活提示
 * （雨→带伞、雪→防滑、紫外线强→防晒、污染→戴口罩……）。
 * 按注意程度降序判定、命中即返回，调用方只展示最重要的一条：
 * 暴雨 → 冻雨/雨夹雪 → 雪 → 雨 → 高温 → 严寒 → 雾 → 霾/沙尘 → 大风 → 紫外线 → 空气污染。
 * 文本判定 = 实况 now.text + 今天 days[].textDay；好天气或无数据返回 ''（不打扰）。
 * 注意：WeatherOutcome 可能来自 weatherFetch（ok=true）也可能来自本地快照 weatherSnapshot
 * （ok=false 但数据齐全），故不能以 ok 为准入，以 now/days 是否有数据为准。
 * 消费方：到点提醒弹窗（ReminderPopup）、提醒横幅（Main）、锁屏/桌面卡片（FormCardData）。
 */
export class WeatherTips {
  /** 注意程度最高的一条话术；无数据/无命中返回 '' */
  static topTipOf(w: WeatherOutcome | null): string {
    if (w === null || (w.now === null && w.days.length === 0)) {
      return '';
    }
    const today: string = WeatherTips.todayIso();
    let dayText: string = '';
    let tempMax: string = '';
    let tempMin: string = '';
    for (let i = 0; i < w.days.length; i++) {
      const d: WeatherDayInfo = w.days[i];
      if (d.fxDate === today) {
        dayText = d.textDay;
        tempMax = d.tempMax;
        tempMin = d.tempMin;
        break;
      }
    }
    const nowText: string = w.now !== null ? w.now.text : '';
    const allText: string = `${nowText}${dayText}`;
    // 1 暴雨
    if (allText.indexOf('暴雨') >= 0) {
      return tr('今天有暴雨，非必要不外出，注意安全');
    }
    // 2 冻雨/雨夹雪
    if (allText.indexOf('冻雨') >= 0 || allText.indexOf('雨夹雪') >= 0) {
      return tr('今天有雨夹雪或冻雨，路面湿滑，出行注意安全');
    }
    // 3 雪
    if (allText.indexOf('雪') >= 0) {
      return tr('今天有雪，出行注意保暖防滑');
    }
    // 4 雨
    if (allText.indexOf('雨') >= 0) {
      return tr('今天有雨，出门记得带伞');
    }
    // 5 高温（今日最高或实况 ≥ 35°）
    if (WeatherTips.atLeast(tempMax, 35) || (w.now !== null && WeatherTips.atLeast(w.now.temp, 35))) {
      return tr('今天高温，注意防暑降温、及时补水');
    }
    // 6 严寒（今日最低或实况 ≤ 0°）
    if (WeatherTips.atMost(tempMin, 0) || (w.now !== null && WeatherTips.atMost(w.now.temp, 0))) {
      return tr('今天气温很低，注意防寒保暖');
    }
    // 7 雾
    if (allText.indexOf('雾') >= 0) {
      return tr('今天有雾，能见度低，出行注意安全');
    }
    // 8 霾/沙尘
    if (allText.indexOf('霾') >= 0 || allText.indexOf('沙') >= 0 || allText.indexOf('尘') >= 0) {
      return tr('今天有霾或沙尘，出门戴好口罩');
    }
    // 9 大风（实况风力 ≥ 7 级）
    if (w.now !== null && WeatherTips.atLeast(w.now.windScale, 7)) {
      return tr('今天风力较大，注意防风、远离高空坠物');
    }
    // 10 紫外线（生活指数 type 5，等级强/很强）
    for (let i = 0; i < w.indices.length; i++) {
      const idx: WeatherIndexInfo = w.indices[i];
      if ((idx.type === '5' || idx.name.indexOf('紫外线') >= 0) && idx.category.indexOf('强') >= 0) {
        return tr('今天紫外线强，注意防晒');
      }
    }
    // 11 空气污染（AQI ≥ 150 或类别含「污染」）
    if (w.air !== null && (WeatherTips.atLeast(w.air.aqi, 150) || w.air.category.indexOf('污染') >= 0)) {
      return tr('今天空气污染较重，出门戴好口罩、减少户外活动');
    }
    return '';
  }

  /** 今天 yyyy-MM-dd（本地时区；与 FormCardData.todayIso 同规则） */
  static todayIso(): string {
    const now: Date = new Date();
    const mm: string = now.getMonth() + 1 < 10 ? `0${now.getMonth() + 1}` : `${now.getMonth() + 1}`;
    const dd: string = now.getDate() < 10 ? `0${now.getDate()}` : `${now.getDate()}`;
    return `${now.getFullYear()}-${mm}-${dd}`;
  }

  /** 天气一句话摘要（记日程随 ai.ask 上送服务器，注入 AI 提示词天气栏）：
   *  实况 + 今日预报 + 空气质量，如「雾 23°C，今日 19~25°C 阴，空气54 良」；无数据返回 '' */
  static summaryOf(w: WeatherOutcome | null): string {
    if (w === null || (w.now === null && w.days.length === 0)) {
      return '';
    }
    const parts: string[] = [];
    if (w.now !== null) {
      const nowBits: string[] = [];
      if (w.now.text.length > 0) {
        nowBits.push(w.now.text);
      }
      if (w.now.temp.length > 0) {
        nowBits.push(`${w.now.temp}°C`);
      }
      if (nowBits.length > 0) {
        parts.push(nowBits.join(' '));
      }
    }
    const today: string = WeatherTips.todayIso();
    for (let i = 0; i < w.days.length; i++) {
      if (w.days[i].fxDate !== today) {
        continue;
      }
      const dayBits: string[] = [];
      if (w.days[i].textDay.length > 0) {
        dayBits.push(`今日${w.days[i].textDay}`);
      }
      if (w.days[i].tempMin.length > 0 && w.days[i].tempMax.length > 0) {
        dayBits.push(`${w.days[i].tempMin}~${w.days[i].tempMax}°C`);
      }
      if (dayBits.length > 0) {
        parts.push(dayBits.join(' '));
      }
      break;
    }
    if (w.air !== null && w.air.category.length > 0) {
      const airBits: string = w.air.aqi.length > 0 ? `${w.air.aqi} ${w.air.category}` : w.air.category;
      parts.push(`空气${airBits}`);
    }
    return parts.join('，');
  }

  /** 数值阈值判定：空串/非法值不算命中（Number('') === 0，须先挡空串防严寒误报） */
  private static atLeast(value: string, threshold: number): boolean {
    const s: string = value.trim();
    if (s.length === 0) {
      return false;
    }
    const n: number = Number(s);
    return !Number.isNaN(n) && n >= threshold;
  }

  private static atMost(value: string, threshold: number): boolean {
    const s: string = value.trim();
    if (s.length === 0) {
      return false;
    }
    const n: number = Number(s);
    return !Number.isNaN(n) && n <= threshold;
  }
}
