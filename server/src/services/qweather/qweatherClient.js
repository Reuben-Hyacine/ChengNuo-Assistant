import { config } from '../../config.js';
import { readWeatherApiKey } from './apiKey.js';

// 和风天气底层请求（服务 97 专用）：所有产品共用同一专属 Host（仅 HTTPS）与 X-QW-Api-Key 请求头。
// 两类接口：
//  - 旧版（/v7/*、/geo/*）：响应体带 code，code==='200' 为成功；
//  - 新版（/airquality/v1、/weatheralert/v1）：经纬度写在路径里，无 code，出错时响应体带 error。
// 每个调用都「永不抛错」，统一返回 { ok, code, error, data }——8 个产品各查各的，
// 某个产品未订阅 / 额度不足 / 参数不合法都不会影响其它产品。

function fail(code, error) {
  return { ok: false, code: code ?? null, error, data: null };
}

async function requestQWeather(pathName, { params = {}, codeBased = true } = {}) {
  const apiKey = readWeatherApiKey();
  if (apiKey === '') {
    return fail(null, `和风天气未配置：请在 ${config.qweather.keyFile} 写入 API Key`);
  }
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== null && value !== undefined && value !== '') {
      query.set(key, String(value));
    }
  }
  const suffix = query.toString();
  const url = `https://${config.qweather.apiHost}${pathName}${suffix ? `?${suffix}` : ''}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.qweather.timeoutMs);
  try {
    const response = await fetch(url, {
      headers: { 'X-QW-Api-Key': apiKey },
      signal: controller.signal
    });
    const text = await response.text().catch(() => '');
    let body = null;
    try {
      body = JSON.parse(text);
    } catch {
      body = null;
    }
    if (!response.ok) {
      const detail = body?.error?.detail ?? body?.error?.title ?? text.slice(0, 200);
      return fail(body?.error?.status ?? body?.code ?? String(response.status), `HTTP ${response.status}: ${detail}`);
    }
    if (!body) {
      return fail(null, `响应不是合法 JSON：${text.slice(0, 200)}`);
    }
    if (codeBased && body.code !== '200') {
      return fail(body.code ?? null, `和风天气返回 code=${body.code}`);
    }
    if (!codeBased && body.error) {
      return fail(body.error.status ?? null, `${body.error.title ?? 'error'}: ${body.error.detail ?? ''}`);
    }
    return { ok: true, code: codeBased ? '200' : String(response.status), error: null, data: body };
  } catch (err) {
    if (err.name === 'AbortError') {
      return fail(null, `请求超时（${config.qweather.timeoutMs}ms）`);
    }
    return fail(null, `请求失败：${err.message}`);
  } finally {
    clearTimeout(timer);
  }
}

// 和风天气要求「经度,纬度」顺序，最多 2 位小数
function latLon(lat, lon) {
  return `${Number(lon).toFixed(2)},${Number(lat).toFixed(2)}`;
}

function hasCoords(lat, lon) {
  return Number.isFinite(Number(lat)) && Number.isFinite(Number(lon));
}

// 产品一：GeoAPI 城市搜索 / 经纬度反查（location 支持「经度,纬度」「城市名」「LocationID」）
export function cityLookup(location, { number = 1, lang = 'zh' } = {}) {
  return requestQWeather('/geo/v2/city/lookup', { params: { location, number, lang } });
}

// 产品二：天气预报（实时 + 每日 + 逐小时），均支持 LocationID 或「经度,纬度」
export function weatherNow(location) {
  return requestQWeather('/v7/weather/now', { params: { location } });
}

export function weatherDaily(location, { days = 3 } = {}) {
  return requestQWeather(`/v7/weather/${days}d`, { params: { location } });
}

export function weatherHourly(location, { hours = 24 } = {}) {
  return requestQWeather(`/v7/weather/${hours}h`, { params: { location } });
}

// 产品三：分钟级降水（仅中国区，未来 2 小时）——只认「经度,纬度」，传 LocationID 会 400
export async function minutelyPrecip(lat, lon) {
  if (!hasCoords(lat, lon)) {
    return fail(null, '缺少经纬度，无法查询分钟级降水');
  }
  return requestQWeather('/v7/minutely/5m', { params: { location: latLon(lat, lon) } });
}

// 产品四：空气质量实时（旧版 /v7/air/now 已废弃，改用新版路径式接口）
export async function airCurrent(lat, lon) {
  if (!hasCoords(lat, lon)) {
    return fail(null, '缺少经纬度，无法查询空气质量');
  }
  return requestQWeather(`/airquality/v1/current/${lat}/${lon}`, { codeBased: false });
}

// 产品五：天气指数（type=0 表示全部指数，1d 为当天）
export function indicesDaily(location, { type = 0 } = {}) {
  return requestQWeather('/v7/indices/1d', { params: { location, type } });
}

// 产品六：天气预警（旧版 /v7/warning/now 已废弃，改用新版路径式接口）
export async function weatherAlert(lat, lon) {
  if (!hasCoords(lat, lon)) {
    return fail(null, '缺少经纬度，无法查询天气预警');
  }
  return requestQWeather(`/weatheralert/v1/current/${lat}/${lon}`, { codeBased: false });
}

// 产品七：天文（日出日落 / 月相），date 形如 20261012
export function astronomySun(location, date) {
  return requestQWeather('/v7/astronomy/sun', { params: { location, date } });
}

export function astronomyMoon(location, date) {
  return requestQWeather('/v7/astronomy/moon', { params: { location, date } });
}

// 产品八：时光机（历史天气），date 形如 20261012
export function historicalWeather(location, date) {
  return requestQWeather('/v7/historical/weather', { params: { location, date } });
}