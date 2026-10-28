/**
 * 和风天气图标编码 → 表情标志（天气块正文、日历格子角标共用）。
 * 编码段：1xx 云况（15x 夜间）/ 3xx 降水 / 4xx 冰雪 / 5xx 雾霾沙尘 / 9xx 冷热。
 */
export class WeatherMark {
  /** 图标编码（如 '100'、'302'）→ 表情；未知编码返回 ''（不展示，保证只显示真实预报） */
  static emojiOfIcon(icon: string): string {
    const code: string = icon.trim();
    if (code.length === 0) {
      return '';
    }
    if (code === '100') {
      return '☀️';
    }
    if (code === '101') {
      return '⛅';
    }
    if (code === '102' || code === '103') {
      return '🌤️';
    }
    if (code === '104') {
      return '☁️';
    }
    if (code === '150' || code === '152' || code === '153') {
      return '🌙';
    }
    if (code.startsWith('15')) {
      return '☁️';
    }
    if (code === '300' || code === '301' || code === '350' || code === '351') {
      return '🌦️';
    }
    if (code === '302' || code === '303' || code === '304') {
      return '⛈️';
    }
    if (code.startsWith('3')) {
      return '🌧️';
    }
    if (code === '407' || code === '408' || code === '409' || code === '499') {
      return '🌨️';
    }
    if (code.startsWith('4')) {
      return '❄️';
    }
    if (code === '500' || code === '501' || code === '509' || code === '510' || code === '514' || code === '515') {
      return '🌫️';
    }
    if (code === '502' || code === '511' || code === '512' || code === '513') {
      return '😷';
    }
    if (code.startsWith('5')) {
      return '🌪️';
    }
    if (code === '900') {
      return '🥵';
    }
    if (code === '901') {
      return '🥶';
    }
    return '';
  }

  /** 图标编码 → 表情；未知编码用兜底表情（天气块大图标用，避免空图） */
  static emojiOfIconOr(icon: string, fallback: string): string {
    const emoji: string = WeatherMark.emojiOfIcon(icon);
    return emoji.length > 0 ? emoji : fallback;
  }
}
