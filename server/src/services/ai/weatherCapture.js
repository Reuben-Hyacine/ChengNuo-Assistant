// 对话地区捕获与天气编排（AI 提示词天气栏的数据源）：
// 1. 客户端记日程时随 ai.ask 上送本地天气（syncClientWeather）——作为提示词天气栏的默认值；
// 2. 用户消息 / AI 回复文本里出现省市（captureRegion）时捕获该地区，经和风天气拉取实况与
//    今日预报后存入服务器（syncCapturedWeather）——在当前卡片确定之前覆盖默认天气；
// 3. currentWeatherForPrompt() 给 assembleContext 提供天气栏内容：捕获地区优先，回退客户端默认；
// 4. 全链路「不抛错」：和风天气不可用 / 地区解析失败时保留旧值或返回 null，绝不阻塞 AI 对话。

import { captureRegion } from './regionChina.js';
import {
  getClientWeather,
  setClientWeather,
  getCapturedWeather,
  setCapturedWeather
} from './aiWeatherStore.js';
import { resolveLocation } from '../qweather/locationResolver.js';
import { weatherNow, weatherDaily } from '../qweather/qweatherClient.js';

// 同一地区 30 分钟内不重复请求和风天气
const STALE_MS = 30 * 60 * 1000;

// 客户端上送的默认天气：region/text 均为非空字符串才入库
export async function syncClientWeather(weather) {
  try {
    return await setClientWeather(weather ?? null);
  } catch {
    return null;
  }
}

function isFresh(entry) {
  const t = Date.parse(entry?.fetchedAt ?? '');
  return Number.isFinite(t) && (Date.now() - t) < STALE_MS;
}

function textOrNull(value) {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null;
}

// 按地区名拉取天气并格式成一句话摘要：实况 + 今日预报（如「多云 18°C，今日晴 12~24°C」）
async function fetchRegionWeather(captured) {
  const location = await resolveLocation({ city: captured.query });
  if (!location.ok) {
    return null;
  }
  const target = location.queryLocation;
  const [nowRes, dailyRes] = await Promise.all([
    weatherNow(target),
    weatherDaily(target, { days: 3 })
  ]);
  const now = nowRes.ok && nowRes.data?.now ? nowRes.data.now : null;
  const daily = dailyRes.ok && Array.isArray(dailyRes.data?.daily) ? dailyRes.data.daily : [];
  const today = daily.length > 0 ? daily[0] : null;

  const parts = [];
  if (now) {
    const nowBits = [];
    const nowText = textOrNull(now.text);
    const nowTemp = textOrNull(now.temp);
    if (nowText) {
      nowBits.push(nowText);
    }
    if (nowTemp) {
      nowBits.push(`${nowTemp}°C`);
    }
    if (nowBits.length > 0) {
      parts.push(nowBits.join(' '));
    }
  }
  if (today) {
    const dayBits = [];
    const dayText = textOrNull(today.textDay);
    const min = textOrNull(today.tempMin);
    const max = textOrNull(today.tempMax);
    if (dayText) {
      dayBits.push(`今日${dayText}`);
    }
    if (min && max) {
      dayBits.push(`${min}~${max}°C`);
    }
    if (dayBits.length > 0) {
      parts.push(dayBits.join(' '));
    }
  }
  if (parts.length === 0) {
    return null;
  }

  const detailParts = [];
  const adm1 = textOrNull(location.adm1);
  const adm2 = textOrNull(location.adm2);
  const name = textOrNull(location.name);
  if (adm1) {
    detailParts.push(adm1);
  }
  if (adm2 && adm2 !== adm1) {
    detailParts.push(adm2);
  }
  if (name && !detailParts.includes(name)) {
    detailParts.push(name);
  }

  return {
    region: captured.name,
    query: captured.query,
    detail: detailParts.join(' '),
    text: parts.join('，'),
    locationId: location.id
  };
}

// 扫描对话文本：捕获省市 → 同步该地区天气。
// 未出现地名、或同名地区 30 分钟内已拉取过则不重复请求；拉取失败保留旧捕获。永不抛错。
export async function syncCapturedWeather(text) {
  try {
    const captured = captureRegion(typeof text === 'string' ? text : '');
    if (captured === null) {
      return null;
    }
    const stored = await getCapturedWeather();
    if (stored && stored.region === captured.name && isFresh(stored)) {
      return stored;
    }
    const entry = await fetchRegionWeather(captured);
    if (entry === null) {
      console.log(`[weather-capture] ${captured.name} 天气拉取失败，${stored ? '保留旧捕获' : '跳过'}`);
      return stored;
    }
    console.log(`[weather-capture] 捕获地区 ${captured.name}（查询 ${captured.query}）：${entry.text}`);
    return await setCapturedWeather(entry);
  } catch (err) {
    console.log(`[weather-capture] 捕获失败（不影响对话）：${err?.message ?? err}`);
    return null;
  }
}

// 提示词【天气】栏内容：捕获地区优先（当前卡片确定前一直生效），回退客户端上送的默认天气
export async function currentWeatherForPrompt() {
  try {
    const [captured, client] = await Promise.all([getCapturedWeather(), getClientWeather()]);
    if (captured) {
      return { source: 'captured', region: captured.region, detail: captured.detail, text: captured.text };
    }
    if (client) {
      return { source: 'client', region: client.region, detail: '', text: client.text };
    }
    return null;
  } catch {
    return null;
  }
}
