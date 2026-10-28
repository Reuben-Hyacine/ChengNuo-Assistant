import { config } from '../../config.js';
import { cityLookup } from './qweatherClient.js';

// 定位信息归一（优先级：经纬度 > IP > 城市名）。把客户端上送的各种形式整理成可查询的 location：
//  - 经纬度：直接可用，归一成「经度,纬度」（和风天气要求此顺序，最多 2 位小数）；
//  - IP：经第三方 IP 粗定位换成经纬度后同上（本机/内网 IP 定位不到时自动降级）；
//  - 城市名：交给 GeoAPI 换成 LocationID。
// 最终尽量用 GeoAPI 取到 LocationID 与城市名（便于缓存与展示）；GeoAPI 失败时退回经纬度字符串，
// 仍可继续查天气。

function textOf(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function numberOrNull(value) {
  if (value === null || value === undefined || value === '') {
    return null;
  }
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

// 和风天气要求「经度,纬度」，最多 2 位小数
function latLonPair(lat, lon) {
  if (lat === null || lon === null) {
    return null;
  }
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
    return null;
  }
  return `${lon.toFixed(2)},${lat.toFixed(2)}`;
}

// 从 payload 取经纬度：lat/lon 字段，或 location 本身已是「经度,纬度」
function coordsFromPayload(payload) {
  const lat = numberOrNull(payload?.lat);
  const lon = numberOrNull(payload?.lon);
  const pair = latLonPair(lat, lon);
  if (pair) {
    return { pair, lat, lon };
  }
  const raw = textOf(payload?.location);
  if (raw.includes(',')) {
    const [lonPart, latPart] = raw.split(',');
    const lon = numberOrNull(lonPart);
    const lat = numberOrNull(latPart);
    const pair2 = latLonPair(lat, lon);
    if (pair2) {
      return { pair: pair2, lat, lon };
    }
  }
  return null;
}

// IP 粗定位单次尝试（第三方、免费、免 Key）。任何失败都返回 null
async function locateByIpOnce(target) {
  const base = config.qweather.ipGeoUrl.replace(/\/+$/, '');
  const url = `${base}/${encodeURIComponent(target)}?fields=status,lat,lon,city&lang=zh-CN`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.qweather.timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) {
      return null;
    }
    const body = await response.json();
    if (body?.status !== 'success') {
      return null;
    }
    const lat = numberOrNull(body.lat);
    const lon = numberOrNull(body.lon);
    const pair = latLonPair(lat, lon);
    if (!pair) {
      return null;
    }
    return { pair, lat, lon };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// IP 粗定位：免费源实测偶发首次连接超时，重试一次提高成功率；仍失败则返回 null，由上层降级到城市名
async function locateByIp(ip) {
  const target = textOf(ip);
  if (target === '') {
    return null;
  }
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const hit = await locateByIpOnce(target);
    if (hit) {
      return hit;
    }
  }
  return null;
}

// 返回 { ok, source, input, queryLocation, id, name, lat, lon, adm1, adm2, country, geo }
export async function resolveLocation(payload = {}) {
  const input = {
    lat: payload?.lat ?? null,
    lon: payload?.lon ?? null,
    ip: textOf(payload?.ip) || null,
    city: textOf(payload?.city) || null,
    location: textOf(payload?.location) || null
  };

  let source = null;
  let query = null;
  let coords = null;

  const direct = coordsFromPayload(payload);
  if (direct) {
    source = 'latlon';
    query = direct.pair;
    coords = { lat: direct.lat, lon: direct.lon };
  }

  if (query === null && input.ip !== null) {
    const byIp = await locateByIp(input.ip);
    if (byIp) {
      source = 'ip';
      query = byIp.pair;
      coords = { lat: byIp.lat, lon: byIp.lon };
    }
  }

  if (query === null) {
    const city = input.city ?? (input.location !== '' ? input.location : null);
    if (city !== null) {
      source = 'city';
      query = city;
    }
  }

  if (query === null) {
    return { ok: false, source: null, input, queryLocation: null, geo: null };
  }

  // GeoAPI 归一：拿 LocationID 与城市名（本身也是 8 个产品之一）
  const geo = await cityLookup(query);
  const hit = geo.ok && Array.isArray(geo.data?.location) ? geo.data.location[0] : null;
  if (!hit) {
    // 归一失败：经纬度仍可直接查天气；城市名则无法继续
    if (coords) {
      return {
        ok: true, source, input, queryLocation: query,
        id: null, name: null, lat: coords.lat, lon: coords.lon,
        adm1: null, adm2: null, country: null, geo
      };
    }
    return { ok: false, source, input, queryLocation: null, geo };
  }

  const lat = numberOrNull(hit.lat) ?? coords?.lat ?? null;
  const lon = numberOrNull(hit.lon) ?? coords?.lon ?? null;
  return {
    ok: true,
    source,
    input,
    queryLocation: hit.id ?? query,
    id: hit.id ?? null,
    name: hit.name ?? null,
    lat,
    lon,
    adm1: hit.adm1 ?? null,
    adm2: hit.adm2 ?? null,
    country: hit.country ?? null,
    geo
  };
}