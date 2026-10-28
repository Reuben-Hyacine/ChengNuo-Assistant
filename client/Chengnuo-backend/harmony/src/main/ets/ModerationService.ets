import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { JsonRec, Jsonl } from './Jsonl';
import { BackendConfig } from './BackendConfig';

/**
 * 智能审核：外置敏感词库规则引擎，对齐 Node 版 server/src/services/moderation.service.js
 * （词库来源、单字符过滤、归一化、拦截行为完全一致）。
 *
 * 词库 = rawfile 内置 sensitive-lexicon.txt（5.1 万词条）：首次使用时自动拷贝到
 * 沙箱 filesDir/backend-data/sensitive-lexicon.txt，此后以沙箱文件为准。
 * 真机上可 hdc file send 推送编辑好的词库（按 mtime+size 自动热重建，无需重启应用）：
 *   hdc -t <serial> file send <本地 sensitive-lexicon.txt> /data/app/el2/100/base/com.chengnuo.app/haps/entry/files/backend-data/sensitive-lexicon.txt
 *
 * 引擎为 Aho–Corasick 自动机（Trie + BFS 失配链 + 词尾上报链）：
 *   构建一次 O(总词长)（首次审核时惰性执行，约数百毫秒），单次扫描 O(文本长度)，
 *   与词库规模无关；词库变化（mtime+size）自动整体重建。
 *   单字符词条（数字「1」、字母「b」、常用字「日」等）无区分度且系统性误报，统一跳过。
 *
 * 客户端拦截点（经 Backend.textPassesModeration，未通过不落库不建卡）：
 *   1) 离线演示入口（CreatePage.mockSend）：脏文本不建演示卡
 *   2) 个人空间签名（PersonalSpace）：未通过审核的签名不保存
 *
 * 词库格式：每行一个词条（默认分类「敏感词」）；支持「#」注释行与「[分类]」分节行（可选扩展）；
 * 词条与待审文本匹配前统一归一化（转小写 + 删全部空白），「F U C K」同样命中「fuck」。
 */

/** AC 自动机边表压缩键步长：UTF-16 码元 ≤ 0xFFFF < 2^21 */
const CHAR_SPAN: number = 0x200000;
/** 无分节词条的默认分类 */
const DEFAULT_CATEGORY: string = '敏感词';
/** 归一化用全局空白正则（与 Node /\s+/g 对齐：删全部空白而非仅首段） */
const WHITESPACE_RE: RegExp = new RegExp('\\s+', 'g');

/** 词条是否为纯 ASCII（不含中文字符）：纯 ASCII 按词边界判定，含中文按子串判定 */
function isAsciiWord(word: string): boolean {
  for (let i = 0; i < word.length; i++) {
    if (word.charCodeAt(i) > 0x7f) {
      return false;
    }
  }
  return true;
}

/** ASCII 字母数字判定（文本已归一化为小写）：0-9 / a-z */
function isAsciiAlnum(code: number): boolean {
  return (code >= 48 && code <= 57) || (code >= 97 && code <= 122);
}

/** 归一化文本中该命中是否为「独立词」：前后字符都不是 ASCII 字母数字，或在文本两端 */
function isWordBoundary(value: string, wordLength: number, endIndex: number): boolean {
  const start: number = endIndex - wordLength + 1;
  const before: number = start > 0 ? value.charCodeAt(start - 1) : -1;
  const after: number = endIndex + 1 < value.length ? value.charCodeAt(endIndex + 1) : -1;
  return !isAsciiAlnum(before) && !isAsciiAlnum(after);
}

/**
 * Aho–Corasick 自动机。goto 边表用单层 Map 压缩存储：
 * 键 = 节点编号 × 2^21 + 字符码，值 = 子节点；避免逐节点 Map 对象
 * 在数十万节点下的内存膨胀。childMaps 仅建树/BFS 阶段使用，finalize 后释放。
 */
class AcAutomaton {
  /** 匹配阶段：Map(节点×2^21+字符码 → 子节点) */
  private gotoMap: Map<number, number> = new Map<number, number>();
  /** 建树/BFS 阶段：节点 → Map(字符码 → 子节点) */
  private childMaps: Map<number, number>[] = [new Map<number, number>()];
  /** 失配链（根为 0） */
  private failTable: number[] = [0];
  /** 节点 → 失配链上最近的词尾节点（含自身；无则 -1） */
  private reportTable: number[] = [-1];
  /** 节点 → 词表下标（非词尾为 -1） */
  private wordIndexAt: number[] = [-1];
  /** 归一化词条（与 categories 一一对应） */
  readonly words: string[] = [];
  /** 与 words 对应的分类 */
  readonly categories: string[] = [];
  private nodeCount: number = 1;

  /** 插入一个归一化词条（长度 ≥ 2，调用方已过滤） */
  insert(word: string, category: string): void {
    const wordIndex: number = this.words.length;
    this.words.push(word);
    this.categories.push(category);
    let state: number = 0;
    for (let i = 0; i < word.length; i++) {
      const code: number = word.charCodeAt(i);
      let next: number | undefined = this.childMaps[state].get(code);
      if (next === undefined) {
        next = this.nodeCount;
        this.nodeCount += 1;
        this.childMaps[state].set(code, next);
        this.childMaps.push(new Map<number, number>());
        this.failTable.push(0);
        this.reportTable.push(-1);
        this.wordIndexAt.push(-1);
      }
      state = next;
    }
    this.wordIndexAt[state] = wordIndex;
  }

  /** BFS 建立失配链与词尾上报链，随后展平边表并释放建树结构（构建 O(总词长)） */
  finalize(): void {
    const queue: number[] = [];
    // 根的直接子节点：失配恒指回根
    this.childMaps[0].forEach((child: number, code: number) => {
      this.failTable[child] = 0;
      this.reportTable[child] = this.wordIndexAt[child] !== -1 ? child : -1;
      queue.push(child);
    });
    for (let head = 0; head < queue.length; head++) {
      const u: number = queue[head];
      this.childMaps[u].forEach((child: number, code: number) => {
        let f: number = this.failTable[u];
        while (f !== 0 && !this.childMaps[f].has(code)) {
          f = this.failTable[f];
        }
        const target: number | undefined = this.childMaps[f].get(code);
        this.failTable[child] = target !== undefined ? target : 0;
        this.reportTable[child] =
          this.wordIndexAt[child] !== -1 ? child : this.reportTable[this.failTable[child]];
        queue.push(child);
      });
    }
    // 展平边表供匹配查询
    this.gotoMap = new Map<number, number>();
    for (let state = 0; state < this.nodeCount; state++) {
      this.childMaps[state].forEach((child: number, code: number) => {
        this.gotoMap.set(state * CHAR_SPAN + code, child);
      });
    }
    this.childMaps = [];
  }

  /** 扫描归一化文本：返回首个命中词条下标，未命中返回 -1。
   *  纯 ASCII 词条（字母/数字）按「词边界」判定：命中位置前后不得是 ASCII 字母数字，
   *  避免 64 命中 1964、ice 命中 service、BJ 命中任意英文串；含中文词条维持子串匹配。 */
  match(value: string): number {
    let state: number = 0;
    for (let i = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      let next: number | undefined = this.gotoMap.get(state * CHAR_SPAN + code);
      while (next === undefined && state !== 0) {
        state = this.failTable[state];
        next = this.gotoMap.get(state * CHAR_SPAN + code);
      }
      state = next !== undefined ? next : 0;
      // 同一位置可能同时结束多个词条（失配链上的词尾），逐个校验边界
      let reportNode: number = this.reportTable[state];
      while (reportNode !== -1) {
        const wordIndex: number = this.wordIndexAt[reportNode];
        const word: string = this.words[wordIndex];
        if (!isAsciiWord(word) || isWordBoundary(value, word.length, i)) {
          return wordIndex;
        }
        reportNode = this.reportTable[this.failTable[reportNode]];
      }
    }
    return -1;
  }
}

/** 审核结果：pass=false 时携带命中分类与词条 */
export class ModerationResult {
  readonly pass: boolean;
  readonly category: string | null;
  readonly word: string | null;

  constructor(pass: boolean, category: string | null, word: string | null) {
    this.pass = pass;
    this.category = category;
    this.word = word;
  }
}

export class ModerationService {
  /** ai.ask 未通过审核时的固定回复 */
  static readonly ASK_REPLY: string = '请手动输入';
  /** postcard.make 未通过审核时的预设寄语 */
  static readonly POSTCARD_TEXT: string = '祝你开心';
  /** 预设寄语的 model 标记（区别于真实 AI 模型名） */
  static readonly POSTCARD_MODEL: string = 'moderation-preset';

  /** 账号类字段是身份标识而非内容文本，不参与审核 */
  private static readonly ACCOUNT_KEYS: string[] = [
    'account', 'userId', 'initiator', 'participant', 'invite', 'uninvite',
    'completableBy', 'completedBy', 'owner', 'toAccount', 'fromAccount'
  ];

  /** 词库自动机缓存：mtime+size 变化才整体重建（秒级 mtime 以 size 补足粒度） */
  private static cacheKey: string = '';
  private static cacheAutomaton: AcAutomaton | null = null;

  /** 词库文件路径（filesDir/backend-data/sensitive-lexicon.txt） */
  static wordsFilePath(): string {
    return BackendConfig.dataFilePath('sensitive-lexicon.txt');
  }

  /** 沙箱词库缺失时从 rawfile 内置词库拷贝一次（约 729KB）；rawfile 读取失败按空词库放行 */
  private static ensureLexiconFile(): void {
    const path: string = ModerationService.wordsFilePath();
    let exists: boolean = false;
    try {
      exists = fileIo.accessSync(path);
    } catch (e) {
      exists = false;
    }
    if (exists) {
      return;
    }
    const ctx: common.Context | null = BackendConfig.context();
    if (ctx === null) {
      return;
    }
    try {
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync('sensitive-lexicon.txt');
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, bytes.buffer);
      fileIo.closeSync(file);
    } catch (e) {
      // rawfile 读取失败：交由 loadAutomaton 按空词库放行
    }
  }

  /** 白名单文件路径（filesDir/backend-data/sensitive-whitelist.txt），对齐 Node 端 sensitive-whitelist.txt */
  static whitelistFilePath(): string {
    return BackendConfig.dataFilePath('sensitive-whitelist.txt');
  }

  /** 沙箱白名单缺失时从 rawfile 拷贝一次；rawfile 不存在时按「无白名单」处理 */
  private static ensureWhitelistFile(): void {
    const path: string = ModerationService.whitelistFilePath();
    let exists: boolean = false;
    try {
      exists = fileIo.accessSync(path);
    } catch (e) {
      exists = false;
    }
    if (exists) {
      return;
    }
    const ctx: common.Context | null = BackendConfig.context();
    if (ctx === null) {
      return;
    }
    try {
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync('sensitive-whitelist.txt');
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, bytes.buffer);
      fileIo.closeSync(file);
    } catch (e) {
      // rawfile 缺失：按无白名单处理
    }
  }

  /** 读取白名单（放行词）为集合；文件不可读返回空集合 */
  private static readWhitelist(): Set<string> {
    ModerationService.ensureWhitelistFile();
    const words: Set<string> = new Set<string>();
    try {
      const text: string = Jsonl.readText(ModerationService.whitelistFilePath());
      const lines: string[] = Jsonl.splitLines(text);
      for (let i = 0; i < lines.length; i++) {
        const line: string = lines[i].trim();
        if (line.length === 0 || line.charAt(0) === '#') {
          continue;
        }
        words.add(ModerationService.normalizeText(line));
      }
    } catch (e) {
      // 读取失败：空白名单
    }
    return words;
  }

  /** 词库状态键（mtime|size）；文件不可读返回 ''（= 空词库放行） */
  private static lexiconStatKey(path: string): string {
    try {
      const stat = fileIo.statSync(path);
      return `${stat.mtime}|${stat.size}`;
    } catch (e) {
      return '';
    }
  }

  /** 读取词库并构建自动机（沙箱词库或白名单变化自动重建；缺失/损坏按空词库处理 = 全部放行，不阻塞业务） */
  private static loadAutomaton(): AcAutomaton | null {
    ModerationService.ensureLexiconFile();
    ModerationService.ensureWhitelistFile();
    const path: string = ModerationService.wordsFilePath();
    const key: string = ModerationService.lexiconStatKey(path);
    if (key === '') {
      ModerationService.cacheKey = '';
      ModerationService.cacheAutomaton = null;
      return null;
    }
    const whitelistKey: string = ModerationService.lexiconStatKey(ModerationService.whitelistFilePath());
    const combinedKey: string = `${key}|${whitelistKey}`;
    if (combinedKey === ModerationService.cacheKey && ModerationService.cacheAutomaton !== null) {
      return ModerationService.cacheAutomaton;
    }
    const whitelist: Set<string> = ModerationService.readWhitelist();
    const text: string = Jsonl.readText(path);
    const automaton: AcAutomaton = new AcAutomaton();
    const lines: string[] = Jsonl.splitLines(text);
    let category: string = DEFAULT_CATEGORY;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0 || line.charAt(0) === '#') {
        continue;
      }
      if (line.charAt(0) === '[' && line.charAt(line.length - 1) === ']') {
        const name: string = line.substring(1, line.length - 1).trim();
        category = name.length > 0 ? name : DEFAULT_CATEGORY;
        continue;
      }
      const word: string = ModerationService.normalizeText(line);
      // 单字符词条（如数字「1」、字母「b」、常用字「日」）无区分度且造成系统性误报
      //（一切含数字/日期的文本均被拦截），统一跳过；词库其余 5 万+ 词条不受影响。
      // 白名单命中的词条一并跳过（多为正常高频词，见 sensitive-whitelist.txt）。
      if (word.length >= 2 && !whitelist.has(word)) {
        automaton.insert(word, category);
      }
    }
    automaton.finalize();
    ModerationService.cacheKey = combinedKey;
    ModerationService.cacheAutomaton = automaton;
    return automaton;
  }

  /** 匹配前归一化：转小写 + 删除全部空白字符（「敏 感 词」「敏*感*词」同样命中「敏感词」） */
  private static normalizeText(text: string): string {
    return text.toLowerCase().replace(WHITESPACE_RE, '');
  }

  /** 审核一段文本：命中任意词条即拦截 */
  static checkText(text: string): ModerationResult {
    const value: string = ModerationService.normalizeText(text);
    if (value.length === 0) {
      return new ModerationResult(true, null, null);
    }
    const automaton: AcAutomaton | null = ModerationService.loadAutomaton();
    if (automaton === null) {
      return new ModerationResult(true, null, null);
    }
    return ModerationService.scan(automaton, value);
  }

  /** 审核结构化内容（卡片内容 / 组名等）：递归收集字符串（跳过账号类字段）逐段审核 */
  static checkContent(value: Object | undefined | null): ModerationResult {
    const strings: string[] = [];
    ModerationService.collectStrings(value, strings);
    const automaton: AcAutomaton | null = ModerationService.loadAutomaton();
    if (automaton === null) {
      return new ModerationResult(true, null, null);
    }
    for (let i = 0; i < strings.length; i++) {
      const value: string = ModerationService.normalizeText(strings[i]);
      if (value.length === 0) {
        continue;
      }
      const result: ModerationResult = ModerationService.scan(automaton, value);
      if (!result.pass) {
        return result;
      }
    }
    return new ModerationResult(true, null, null);
  }

  private static scan(automaton: AcAutomaton, value: string): ModerationResult {
    const wordIndex: number = automaton.match(value);
    if (wordIndex < 0) {
      return new ModerationResult(true, null, null);
    }
    return new ModerationResult(false, automaton.categories[wordIndex], automaton.words[wordIndex]);
  }

  private static collectStrings(value: Object | undefined | null, out: string[]): void {
    if (value === undefined || value === null) {
      return;
    }
    if (JsonRec.isString(value)) {
      const s: string = (value as string).trim();
      if (s.length > 0) {
        out.push(value as string);
      }
      return;
    }
    const list: Object[] | null = JsonRec.arr(value);
    if (list !== null) {
      for (let i = 0; i < list.length; i++) {
        ModerationService.collectStrings(list[i], out);
      }
      return;
    }
    const rec: Record<string, Object> | null = JsonRec.toRecord(value);
    if (rec !== null) {
      const keys: string[] = Object.keys(rec);
      for (let i = 0; i < keys.length; i++) {
        if (ModerationService.ACCOUNT_KEYS.indexOf(keys[i]) >= 0) {
          continue;
        }
        ModerationService.collectStrings(rec[keys[i]], out);
      }
    }
  }

  /** 分类编号 → 展示名（未登记的分类按原样展示，便于自行扩展分节） */
  private static categoryLabel(category: string | null): string {
    switch (category) {
      case 'porn':
        return '色情';
      case 'violence':
        return '暴力';
      case 'illegal':
        return '违法';
      case 'crime':
        return '犯罪';
      case 'profanity':
        return '不良语言';
      case 'extremism':
        return '极端言论';
      default:
        return category !== null && category.length > 0 ? category : '未分类';
    }
  }

  /** 拦截提示语前缀：如「卡片内容未通过智能审核（敏感词）」，调用方按场景拼接后缀 */
  static blockedMessage(result: ModerationResult): string {
    return `卡片内容未通过智能审核（${ModerationService.categoryLabel(result.category)}）`;
  }
}
