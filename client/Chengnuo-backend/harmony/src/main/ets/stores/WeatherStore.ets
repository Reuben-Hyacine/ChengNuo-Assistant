import { JsonRec, Jsonl } from '../Jsonl';

/**
 * weather.txt：天气快照（客户端长期保存）。
 * 服务 97（weather.fetch）由服务器调和风天气 8 个产品后返回，服务器不持久化——
 * 由客户端把这一份结果写入本文件长期留存；每次获得新的天气信息即清空旧的，
 * 文件始终只保留最近一份快照。UTF-8 JSONL，可手动编辑。
 */
export class WeatherStore {
  private filePath(): string {
    return Jsonl.dataFilePath('weather.txt');
  }

  /** 读取快照记录（无快照 / 文件损坏返回 null） */
  private readRecord(): Record<string, Object> | null {
    const records: Object[] = Jsonl.readJsonl(this.filePath());
    for (let i = 0; i < records.length; i++) {
      const rec: Record<string, Object> | null = JsonRec.toRecord(records[i]);
      if (rec === null) {
        continue;
      }
      const location: Record<string, Object> | null = JsonRec.toRecord(rec['location']);
      const weather: Record<string, Object> | null = JsonRec.toRecord(rec['weather']);
      if (location === null || weather === null) {
        continue;
      }
      return rec;
    }
    return null;
  }

  /** 最近一份天气快照（无返回 null）：离线展示与刷新时机判断用 */
  latest(): Record<string, Object> | null {
    return this.readRecord();
  }

  /** 保存快照并清空旧数据（文件只留这一份）：location / weather 缺失时不落盘、旧数据保持不动 */
  saveSnapshot(account: string, userId: number | null,
    location: Record<string, Object> | null, weather: Record<string, Object> | null,
    fetchedAt: string): Record<string, Object> | null {
    if (location === null || weather === null) {
      return null;
    }
    const rec: Record<string, Object> = { 'id': 1, 'location': location, 'weather': weather };
    JsonRec.put(rec, 'account', JsonRec.trimText(account).length > 0 ? JsonRec.trimText(account) : null);
    JsonRec.put(rec, 'userId', userId);
    JsonRec.put(rec, 'fetchedAt', fetchedAt.length > 0 ? fetchedAt : JsonRec.isoNow());
    Jsonl.writeJsonl(this.filePath(), [rec]);
    return JsonRec.copyRecord(rec);
  }

  /** 注销账号：清除本机天气快照 */
  clearByAccount(account: string): void {
    const rec: Record<string, Object> | null = this.readRecord();
    if (rec === null || JsonRec.trimText(rec['account']) !== JsonRec.trimText(account)) {
      return;
    }
    Jsonl.writeJsonl(this.filePath(), []);
  }

  /** 改名（82）：快照记录的账号同步换名（userId 不变） */
  renameAccountOf(account: string, newAccount: string): void {
    const oldName: string = JsonRec.trimText(account);
    const newName: string = JsonRec.trimText(newAccount);
    if (oldName.length === 0 || newName.length === 0 || oldName === newName) {
      return;
    }
    const rec: Record<string, Object> | null = this.readRecord();
    if (rec === null || JsonRec.trimText(rec['account']) !== oldName) {
      return;
    }
    rec['account'] = newName;
    Jsonl.writeJsonl(this.filePath(), [rec]);
  }
}

export const weatherStore: WeatherStore = new WeatherStore();
