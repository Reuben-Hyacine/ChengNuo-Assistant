import { fileIo } from '@kit.CoreFileKit';
import { BackendConfig } from './BackendConfig';

/**
 * JSON 值读取/规范化工具：对齐 Node 版 store 的字段访问惯例。
 * 本库统一约束：
 * 1. 动态 JSON 一律以 Record<string, Object> 承载，读取全部走 JsonRec 显式兜底；
 * 2. 落盘 omit-null：值为 null 时直接省略键（页面端 mapper 均为 fallback 读，语义等价）；
 * 3. undefined / null / 缺失键在读取侧等价处理。
 */
export class JsonRec {
  /** typeof x === 'string' */
  static isString(value: Object | undefined | null): boolean {
    return value !== undefined && value !== null && typeof value === 'string';
  }

  /** typeof x === 'string' ? x : ''（不 trim） */
  static text(value: Object | undefined | null): string {
    return JsonRec.isString(value) ? value as string : '';
  }

  /** typeof x === 'string' ? x.trim() : '' */
  static trimText(value: Object | undefined | null): string {
    return JsonRec.isString(value) ? (value as string).trim() : '';
  }

  /** typeof x === 'string' ? x : null */
  static strOrNull(value: Object | undefined | null): string | null {
    return JsonRec.isString(value) ? value as string : null;
  }

  /** Number(x)：undefined → NaN、null → 0（逐位对齐 JS Number()） */
  static rawNum(value: Object | undefined | null): number {
    if (value === undefined) {
      return Number.NaN;
    }
    if (value === null) {
      return 0;
    }
    return Number(value);
  }

  /** Number.isInteger(x)：非 number 一律 false（原样判断，不做 Number() 强转） */
  static rawIsInt(value: Object | undefined | null): boolean {
    return value !== undefined && value !== null && typeof value === 'number' && Number.isInteger(value as number);
  }

  /** Number.isInteger(Number(x)) ? Number(x) : null（强制转换式判断；注意 JS 里 Number(null)=0 会通过） */
  static coercedInt(value: Object | undefined | null): number | null {
    const n: number = JsonRec.rawNum(value);
    return Number.isInteger(n) ? n : null;
  }

  /** Number.isInteger(x) ? x : null（原样判断） */
  static intOrNull(value: Object | undefined | null): number | null {
    return JsonRec.rawIsInt(value) ? value as number : null;
  }

  /** 正整数或 null：Number(x) 后校验（对齐 JS positiveIntOrNull） */
  static posIntOrNull(value: Object | undefined | null): number | null {
    const n: number = JsonRec.rawNum(value);
    return Number.isInteger(n) && n >= 1 ? n : null;
  }

  /** 纯对象或 null：null/undefined/数组/非对象一律 null（对齐 JS objectOrNull） */
  static obj(value: Object | undefined | null): Record<string, Object> | null {
    if (value === undefined || value === null) {
      return null;
    }
    if (typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  /** JsonRec.obj 的惯用名（服务器 data / 手编 JSON 行 → Record） */
  static toRecord(raw: Object | undefined | null): Record<string, Object> | null {
    return JsonRec.obj(raw);
  }

  /** 数组或 null（对齐 JS Array.isArray 守卫） */
  static arr(value: Object | undefined | null): Object[] | null {
    if (value === undefined || value === null) {
      return null;
    }
    return Array.isArray(value) ? value as Object[] : null;
  }

  /** JS 真值判断（JSON 值域内与 !!x 一致） */
  static truthy(value: Object | undefined | null): boolean {
    if (value === undefined || value === null) {
      return false;
    }
    if (typeof value === 'boolean') {
      return value as boolean;
    }
    if (typeof value === 'number') {
      const n: number = value as number;
      return n !== 0 && !Number.isNaN(n);
    }
    if (typeof value === 'string') {
      return (value as string).length > 0;
    }
    return true;
  }

  /** 字符串数组：过滤非字符串/空串并去重（对齐 JS [...new Set(list.filter(...))]） */
  static stringList(value: Object | undefined | null): string[] {
    const out: string[] = [];
    const list: Object[] | null = JsonRec.arr(value);
    if (list === null) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const s: string = JsonRec.text(list[i]);
      if (s.length > 0 && out.indexOf(s) < 0) {
        out.push(s);
      }
    }
    return out;
  }

  /** 读取键值（rec 为 null 或键缺失时返回 undefined），配合 ?? 使用对齐 JS 的 obj?.key */
  static val(rec: Record<string, Object> | null, key: string): Object | undefined {
    return rec !== null ? rec[key] : undefined;
  }

  /** omit-null 写入：value 为 null 时省略键（本库落盘统一策略） */
  static put(rec: Record<string, Object>, key: string, value: Object | null): void {
    if (value !== null) {
      rec[key] = value;
    }
  }

  /** 浅拷贝（对齐 JS {...rec}；键序不保证，不影响 JSON 语义） */
  static copyRecord(source: Record<string, Object>): Record<string, Object> {
    const out: Record<string, Object> = {};
    const keys: string[] = Object.keys(source);
    for (let i = 0; i < keys.length; i++) {
      out[keys[i]] = source[keys[i]];
    }
    return out;
  }

  /** 重建记录并剔除指定键（ArkTS 禁用 delete，清除已有键须整体重建） */
  static omitKeys(src: Record<string, Object>, banned: string[]): Record<string, Object> {
    const out: Record<string, Object> = {};
    const keys: string[] = Object.keys(src);
    for (let i = 0; i < keys.length; i++) {
      let bannedKey: boolean = false;
      for (let b = 0; b < banned.length; b++) {
        if (keys[i] === banned[b]) {
          bannedKey = true;
          break;
        }
      }
      if (!bannedKey) {
        out[keys[i]] = src[keys[i]];
      }
    }
    return out;
  }

  /** 写入可能为 null 的字段：非 null 直接写入；null 时剔除该键（重建记录，omit-null 语义） */
  static withField(src: Record<string, Object>, key: string, value: Object | null): Record<string, Object> {
    if (value !== null) {
      src[key] = value;
      return src;
    }
    if (src[key] === undefined) {
      return src;
    }
    return JsonRec.omitKeys(src, [key]);
  }

  /** 参与人列表字符串中的账号改名（、/,/， 分隔；命中返回新串，未命中返回 null；对齐 JS renameInParticipants） */
  static renameInParticipants(value: Object | undefined | null, oldName: string, newName: string): string | null {
    if (!JsonRec.isString(value)) {
      return null;
    }
    const parts: string[] = (value as string).split(new RegExp('[、,，]'));
    const out: string[] = [];
    let hit: boolean = false;
    for (let i = 0; i < parts.length; i++) {
      const piece: string = parts[i].trim();
      if (piece.length === 0) {
        continue;
      }
      if (piece === oldName) {
        out.push(newName);
        hit = true;
      } else {
        out.push(piece);
      }
    }
    if (!hit) {
      return null;
    }
    return out.join('、');
  }

  /** 现在时刻的 ISO 串（对齐 JS new Date().toISOString()） */
  static isoNow(): string {
    return new Date().toISOString();
  }
}

/** UTF-8 JSONL 文件读写（全同步）：懒加载 + 整体重写 + 剥离 BOM + 跳过损坏行 */
export class Jsonl {
  static dataFilePath(name: string): string {
    return BackendConfig.dataFilePath(name);
  }

  /** 剥离 UTF-8 BOM（对齐 JS stripBom） */
  static stripBom(text: string): string {
    return text.length > 0 && text.charCodeAt(0) === 0xFEFF ? text.substring(1) : text;
  }

  /** 文件不存在则创建空文件（目录由 BackendConfig.init 保证存在） */
  static ensureFile(filePath: string): void {
    try {
      // fs.accessSync 对不存在的路径会抛 13900002（而非返回 false），单独兜底
      let exists: boolean = false;
      try {
        exists = fileIo.accessSync(filePath);
      } catch (e) {
        exists = false;
      }
      if (!exists) {
        const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        fileIo.closeSync(file);
      }
    } catch (e) {
      // 创建失败：读取侧按空数据兜底
    }
  }

  /** 读全文（不存在/失败返回 ''） */
  static readText(filePath: string): string {
    try {
      return Jsonl.stripBom(fileIo.readTextSync(filePath));
    } catch (e) {
      return '';
    }
  }

  /** 覆写全文（TRUNC） */
  static writeText(filePath: string, text: string): void {
    const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, text);
    fileIo.closeSync(file);
  }

  /** 按 \r?\n 切行（等价 JS text.split(/\r?\n/)，ArkTS 禁正则字面量故用 RegExp 构造） */
  static splitLines(text: string): string[] {
    return text.split(new RegExp('\\r?\\n'));
  }

  /** 读取 JSONL：跳过空行/损坏行；解析出 null 的行也跳过 */
  static readJsonl(filePath: string): Object[] {
    Jsonl.ensureFile(filePath);
    const text: string = Jsonl.readText(filePath);
    const out: Object[] = [];
    const lines: string[] = Jsonl.splitLines(text);
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      try {
        const parsed: Object | null = JSON.parse(line);
        if (parsed !== null) {
          out.push(parsed);
        }
      } catch (e) {
        // 跳过损坏行（手动编辑出错时不影响其它记录）
      }
    }
    return out;
  }

  /** 写入 JSONL：每行 JSON.stringify，结尾补 \n；空集写空文件 */
  static writeJsonl(filePath: string, records: Object[]): void {
    Jsonl.ensureFile(filePath);
    const lines: string[] = [];
    for (let i = 0; i < records.length; i++) {
      lines.push(JSON.stringify(records[i]));
    }
    Jsonl.writeText(filePath, lines.length > 0 ? `${lines.join('\n')}\n` : '');
  }
}
