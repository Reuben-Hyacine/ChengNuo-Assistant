// 路由入站调用日志（内存，重启即失）。服务器控制台据此回显客户端经路由发起的调用
const MAX_ITEMS = 100;

let seq = 0;
const items = [];

function trim() {
  if (items.length > MAX_ITEMS) {
    items.splice(0, items.length - MAX_ITEMS);
  }
}

// entry: { serviceId, service, summary, ok }
export function pushActivity(entry) {
  seq += 1;
  items.push({ id: seq, time: new Date().toISOString(), ...entry });
  trim();
  return seq;
}

export function listActivity() {
  return items.map(item => ({ ...item }));
}
