import { resolveLocation } from './locationResolver.js';
import {
  weatherNow,
  weatherDaily,
  weatherHourly,
  minutelyPrecip,
  airCurrent,
  indicesDaily,
  weatherAlert,
  astronomySun,
  astronomyMoon,
  historicalWeather
} from './qweatherClient.js';

// 服务 97 weather.fetch：接收客户端上送的定位信息（经纬度 / IP / 城市名），整理成可查询的
// location 后并发调用和风天气的 8 个产品，把 8 份结果一并返回。
// 天气数据由客户端写入本地天气文件长期保存，服务器不持久化。

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function pad2(n) {
  return String(n).padStart(2, '0');
}

function toYmd(date) {
  return `${date.getFullYear()}${pad2(date.getMonth() + 1)}${pad2(date.getDate())}`;
}

// 接受 YYYYMMDD / YYYY-MM-DD；非法或未提供时返回 null
function normalizeDate(value) {
  const text = typeof value === 'string' ? value.trim() : '';
  if (text === '') {
    return null;
  }
  const digits = text.replace(/-/g, '');
  return /^\d{8}$/.test(digits) ? digits : null;
}

export async function fetchWeather(payload = {}) {
  const location = await resolveLocation(payload ?? {});
  if (!location.ok) {
    throw badRequest('无法确定位置：请提供经纬度（lat/lon）、IP（ip）或城市名（city）');
  }
  const target = location.queryLocation;
  // 分钟降水 / 空气质量 / 天气预警只认经纬度，其余产品走 LocationID
  const lat = location.lat;
  const lon = location.lon;

  const now = new Date();
  const date = normalizeDate(payload?.date);
  const today = date ?? toYmd(now);
  // 时光机取历史天气：未指定日期时默认「昨天」
  const historyDate = date ?? toYmd(new Date(now.getTime() - 86400000));

  const [nowResult, dailyResult, hourlyResult, minutely, air, indices, warning, sun, moon, timeMachine] = await Promise.all([
    weatherNow(target),
    weatherDaily(target, { days: 3 }),
    weatherHourly(target, { hours: 24 }),
    minutelyPrecip(lat, lon),
    airCurrent(lat, lon),
    indicesDaily(target, { type: 0 }),
    weatherAlert(lat, lon),
    astronomySun(target, today),
    astronomyMoon(target, today),
    historicalWeather(target, historyDate)
  ]);

  return {
    location: {
      source: location.source,
      input: location.input,
      id: location.id,
      name: location.name,
      lat: location.lat,
      lon: location.lon,
      adm1: location.adm1,
      adm2: location.adm2,
      country: location.country
    },
    weather: {
      // 产品一：GeoAPI（定位归一结果，含候选城市列表）
      geo: location.geo,
      // 产品二：天气预报（实时 + 每日 + 逐小时）
      forecast: {
        ok: nowResult.ok && dailyResult.ok && hourlyResult.ok,
        now: nowResult,
        daily: dailyResult,
        hourly: hourlyResult
      },
      // 产品三：分钟级降水
      minutely,
      // 产品四：空气质量
      air,
      // 产品五：天气指数
      indices,
      // 产品六：天气预警
      warning,
      // 产品七：天文（日出日落 / 月相）
      astronomy: {
        ok: sun.ok && moon.ok,
        sun,
        moon
      },
      // 产品八：时光机（历史天气）
      timeMachine
    },
    fetchedAt: new Date().toISOString()
  };
}