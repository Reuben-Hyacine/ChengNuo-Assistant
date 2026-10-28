const IPV4_RE = /^(25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)){3}$/;

// 中国大陆手机号：11 位数字，1 开头，第二位 3-9（覆盖 13x/14x/15x/16x/17x/18x/19x）
const MOBILE_RE = /^1[3-9]\d{9}$/;

// 去掉首尾空白与常见分隔符（空格、连字符），得到纯数字串；非字符串返回空串
export function normalizeMobileNumber(value) {
  return typeof value === 'string' ? value.trim().replace(/[\s-]/g, '') : '';
}

// 是否为符合规范的中国大陆手机号（输入为数字串，容忍空格/连字符分隔）
export function isValidMobileNumber(value) {
  return MOBILE_RE.test(normalizeMobileNumber(value));
}

// 校验手机号并给出可读原因；供注册系统在入库前统一校验使用。
// 返回 { valid, phone（规范化后的数字串）, reason（不通过时的中文原因） }
export function validateMobileNumber(value) {
  const raw = typeof value === 'string' ? value.trim() : '';
  if (raw === '') {
    return { valid: false, phone: '', reason: '手机号不能为空' };
  }
  const phone = normalizeMobileNumber(raw);
  if (!/^\d+$/.test(phone)) {
    return { valid: false, phone, reason: '手机号只能包含数字' };
  }
  if (phone.length !== 11) {
    return { valid: false, phone, reason: '手机号必须是 11 位数字' };
  }
  if (phone[0] !== '1') {
    return { valid: false, phone, reason: '手机号必须以 1 开头' };
  }
  if (!MOBILE_RE.test(phone)) {
    return { valid: false, phone, reason: '手机号第二位必须是 3-9' };
  }
  return { valid: true, phone, reason: '' };
}

export function isValidIPv4(value) {
  return typeof value === 'string' && IPV4_RE.test(value);
}

export function isValidPort(value) {
  return Number.isInteger(value) && value >= 1 && value <= 65535;
}
