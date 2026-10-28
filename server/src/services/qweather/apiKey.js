import fs from 'node:fs';
import { config } from '../../config.js';

// 和风天气 API Key 独立文件保存，每次调用时读取（与 ai/apiKey.js 同一惯例）。
// 不缓存到内存：直接改文件即可生效，无需重启服务器。
export function readWeatherApiKey() {
  try {
    return fs.readFileSync(config.qweather.keyFile, 'utf8').trim();
  } catch {
    return '';
  }
}