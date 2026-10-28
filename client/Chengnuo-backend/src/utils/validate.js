const IPV4_RE = /^(25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)){3}$/;

export function isValidIPv4(value) {
  return typeof value === 'string' && IPV4_RE.test(value);
}

export function isValidPort(value) {
  return Number.isInteger(value) && value >= 1 && value <= 65535;
}