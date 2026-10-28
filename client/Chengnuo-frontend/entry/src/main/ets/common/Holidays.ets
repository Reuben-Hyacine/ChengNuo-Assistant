/**
 * 节日表：固定公历节日（每年同月日重复）+ 2026/2027 农历与节气节日（公历日期逐年变化，按年硬编码）。
 * 日历（月历格子右下角标注节日名）与后续节日相关功能共用。
 */

/** 固定公历节日（'MM-DD' → 节日名，每年重复） */
const HOLIDAY_FIXED: Record<string, string> = {
  '01-01': '元旦',
  '02-14': '情人节',
  '03-08': '妇女节',
  '03-12': '植树节',
  '05-01': '劳动节',
  '05-04': '青年节',
  '06-01': '儿童节',
  '07-01': '建党节',
  '08-01': '建军节',
  '09-10': '教师节',
  '10-01': '国庆节',
  '10-31': '万圣夜',
  '11-11': '双11',
  '12-24': '平安夜',
  '12-25': '圣诞节'
};

/** 农历与节气节日（'YYYY-MM-DD' → 节日名，公历日期逐年变化） */
const HOLIDAY_BY_YEAR: Record<string, string> = {
  '2026-01-26': '腊八节',
  '2026-02-16': '除夕',
  '2026-02-17': '春节',
  '2026-03-03': '元宵节',
  '2026-04-05': '清明节',
  '2026-06-19': '端午节',
  '2026-08-19': '七夕节',
  '2026-09-25': '中秋节',
  '2026-10-18': '重阳节',
  '2026-12-22': '冬至',
  '2027-01-15': '腊八节',
  '2027-02-05': '除夕',
  '2027-02-06': '春节',
  '2027-02-20': '元宵节',
  '2027-04-05': '清明节',
  '2027-06-09': '端午节',
  '2027-08-08': '七夕节',
  '2027-09-15': '中秋节',
  '2027-10-08': '重阳节',
  '2027-12-22': '冬至'
};

/** 感恩节：11 月第四个周四（22~28 日之间的周四） */
function isThanksgiving(ymd: string): boolean {
  if (ymd.length !== 10 || ymd.substring(5, 7) !== '11') {
    return false;
  }
  const day: number = Number(ymd.substring(8, 10));
  if (day < 22 || day > 28) {
    return false;
  }
  return new Date(Number(ymd.substring(0, 4)), 10, day).getDay() === 4;
}

/** 日期（'YYYY-MM-DD'）→ 节日名，非节日返回空串 */
export function holidayOf(dateText: string): string {
  const ymd: string = dateText.trim();
  if (ymd.length !== 10) {
    return '';
  }
  const byYear: string | undefined = HOLIDAY_BY_YEAR[ymd];
  if (byYear !== undefined) {
    return byYear;
  }
  const fixed: string | undefined = HOLIDAY_FIXED[ymd.substring(5, 10)];
  if (fixed !== undefined) {
    return fixed;
  }
  return isThanksgiving(ymd) ? '感恩节' : '';
}
