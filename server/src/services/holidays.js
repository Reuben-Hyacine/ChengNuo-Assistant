// 节日表：固定公历节日（每年同月日重复）+ 2026/2027 农历与节气节日（公历日期逐年变化，按年硬编码）。
// 卡片小铺（89）生成当日批次时按当天日期取节日名注入 AI 提示，推荐贴合节日氛围的活动。

const FIXED_HOLIDAYS = {
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

// 农历/节气节日（公历日期随年份变化）：腊八、除夕、春节、元宵、清明、端午、七夕、中秋、重阳、冬至
const YEAR_HOLIDAYS = {
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
function isThanksgiving(ymd) {
  if (ymd.slice(5, 7) !== '11') {
    return false;
  }
  const day = Number(ymd.slice(8, 10));
  if (!(day >= 22 && day <= 28)) {
    return false;
  }
  return new Date(Number(ymd.slice(0, 4)), 10, day).getDay() === 4;
}

/** 日期（'YYYY-MM-DD'）→ 节日名，非节日返回空串 */
export function holidayOf(dateText) {
  const ymd = typeof dateText === 'string' ? dateText.trim() : '';
  if (ymd.length !== 10) {
    return '';
  }
  if (YEAR_HOLIDAYS[ymd]) {
    return YEAR_HOLIDAYS[ymd];
  }
  if (FIXED_HOLIDAYS[ymd.slice(5, 10)]) {
    return FIXED_HOLIDAYS[ymd.slice(5, 10)];
  }
  return isThanksgiving(ymd) ? '感恩节' : '';
}

/** 今天（本地时区）的 'YYYY-MM-DD' */
export function todayText() {
  const d = new Date();
  const m = d.getMonth() + 1;
  const day = d.getDate();
  return `${d.getFullYear()}-${m < 10 ? '0' : ''}${m}-${day < 10 ? '0' : ''}${day}`;
}

/** 卡片小铺（89）节日提示：当天是节日时提示 AI 优先推荐与节日相关的活动 */
export function shopHolidayHint(dateText) {
  const holiday = holidayOf(dateText);
  return holiday === '' ? '' : `（今天是${holiday}。请优先推荐与${holiday}相关的活动，贴合节日氛围与习俗。）`;
}
