import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// 智能审核：外置敏感词库（server/sensitive-lexicon.txt，5 万+ 词条）规则引擎。
// 引擎为 Aho–Corasick 自动机（Trie + BFS 失配链 + 词尾上报链）：
//   构建一次 O(总词长)，单次扫描 O(文本长度)（与词库规模无关），适合超大词库。
// 词库按文件修改时间自动热加载：变化后整体重建自动机，无需重启服务器。
// 三个拦截点共用本模块（全部在「构建 AI 提示词之前」执行，未通过审核不调用 AI）：
//   1) ai.ask（服务 0）     ：审核用户输入 → 未通过返回固定回复「请手动输入」（响应结构与正常流程一致，前端零改动）
//   2) postcard.make（66）  ：审核卡片内容 → 未通过返回预设寄语「祝你开心」（model 记为 moderation-preset）
//   3) 公开卡片组库入库口（cardGroupStore 六处闸）：审核卡片内容 + 组名 → 未通过抛 409 拒绝入公开库
// 词库格式：每行一个词条（默认分类「敏感词」）；支持「#」注释行与「[分类]」分节行（可选扩展）；
// 词条与待审文本匹配前统一归一化（转小写 + 删全部空白），「F U C K」同样命中「fuck」。

const WORD_FILE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'sensitive-lexicon.txt');
// 白名单（放行词）：与词库同目录，一行一词；命中者的同名词条在构建自动机时被跳过。
// 词库由政治口号等文本切碎生成，混入大量中文高频常用词（「一个」「时间」「计划」…）会误拦正常输入，
// 用本文件把这些正常词排除；词库其余真实代号不受影响。缺失/损坏按「无白名单」处理。
const WHITELIST_FILE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'sensitive-whitelist.txt');
const DEFAULT_CATEGORY = '敏感词';

export const MODERATION_ASK_REPLY = '请手动输入';
export const MODERATION_POSTCARD_TEXT = '祝你开心';
export const MODERATION_POSTCARD_MODEL = 'moderation-preset';

// 词库分节名 → 展示名（未登记的分节按原样展示，便于自行扩展分类）
const CATEGORY_LABELS = {
  porn: '色情',
  violence: '暴力',
  illegal: '违法',
  crime: '犯罪',
  profanity: '不良语言',
  extremism: '极端言论'
};

// 账号类字段是身份标识而非内容文本，不参与审核
const ACCOUNT_KEYS = new Set([
  'account', 'userId', 'initiator', 'participant', 'invite', 'uninvite',
  'completableBy', 'completedBy', 'owner', 'toAccount', 'fromAccount'
]);

// 匹配前归一化：转小写 + 删除全部空白字符（「敏 感 词」「敏*感*词」同样命中「敏感词」）
function normalizeText(text) {
  return String(text ?? '').toLowerCase().replace(/\s+/g, '');
}

// 词条是否为纯 ASCII（不含任何中文字符）：纯 ASCII 词条按「词边界」判定，含中文词条按子串判定
function isAsciiWord(word) {
  for (let i = 0; i < word.length; i++) {
    if (word.charCodeAt(i) > 0x7f) {
      return false;
    }
  }
  return true;
}

// 归一化文本（已转小写、已删空白）中，位于 endIndex 结束、长度为 wordLength 的命中是否为「独立词」：
// 前后字符都不是 ASCII 字母数字（0-9 / a-z），或在文本两端
function isWordBoundary(value, wordLength, endIndex) {
  const start = endIndex - wordLength + 1;
  const before = start > 0 ? value.charCodeAt(start - 1) : -1;
  const after = endIndex + 1 < value.length ? value.charCodeAt(endIndex + 1) : -1;
  return !isAsciiAlnum(before) && !isAsciiAlnum(after);
}

function isAsciiAlnum(code) {
  return (code >= 48 && code <= 57) || (code >= 97 && code <= 122);
}

// ---- Aho–Corasick 自动机 ----
// 边表用单层 Map 压缩存储：键 = 节点编号 * 2^21 + 字符码（UTF-16 码元 ≤ 0xFFFF < 2^21），值 = 子节点；
// 避免逐节点 Map 对象在数十万节点下的内存膨胀。children 仅建树/BFS 阶段使用，finalize 后释放。
const CHAR_SPAN = 0x200000; // 2^21

class Automaton {
  constructor() {
    this.children = [new Map()];  // 建树阶段：节点 → Map(字符码 → 子节点)
    this.goto = null;             // 匹配阶段：Map(节点*2^21+字符码 → 子节点)
    this.fail = [0];              // 失配链（根为 0）
    this.report = [-1];           // 节点 → 失配链上最近的词尾节点（含自身；无则 -1）
    this.wordIndexAt = [-1];      // 节点 → 词表下标（非词尾为 -1）
    this.words = [];              // 归一化词条
    this.categories = [];         // 与 words 对应的分类
    this.nodeCount = 1;           // 0 号为根
  }

  insert(word, category) {
    const wordIndex = this.words.push(word) - 1;
    this.categories.push(category);
    let state = 0;
    for (let i = 0; i < word.length; i++) {
      const code = word.charCodeAt(i);
      let next = this.children[state].get(code);
      if (next === undefined) {
        next = this.nodeCount++;
        this.children[state].set(code, next);
        this.children.push(new Map());
        this.fail.push(0);
        this.report.push(-1);
        this.wordIndexAt.push(-1);
      }
      state = next;
    }
    this.wordIndexAt[state] = wordIndex;
  }

  // BFS 建立失配链与词尾上报链，随后展平边表并释放建树结构（构建 O(总词长)）
  finalize() {
    const queue = [];
    for (const [, child] of this.children[0]) {
      this.fail[child] = 0;
      this.report[child] = this.wordIndexAt[child] !== -1 ? child : -1;
      queue.push(child);
    }
    for (let head = 0; head < queue.length; head++) {
      const u = queue[head];
      for (const [code, child] of this.children[u]) {
        let f = this.fail[u];
        while (f !== 0 && !this.children[f].has(code)) {
          f = this.fail[f];
        }
        const target = this.children[f].get(code);
        this.fail[child] = target !== undefined ? target : 0;
        this.report[child] = this.wordIndexAt[child] !== -1 ? child : this.report[this.fail[child]];
        queue.push(child);
      }
    }
    this.goto = new Map();
    for (let state = 0; state < this.nodeCount; state++) {
      for (const [code, child] of this.children[state]) {
        this.goto.set(state * CHAR_SPAN + code, child);
      }
    }
    this.children = null;
  }

  // 扫描归一化文本：返回首个命中（词表下标），未命中返回 null。
  // 纯 ASCII 词条（字母/数字）按「词边界」判定：命中位置前后不得是 ASCII 字母数字，
  // 避免 64 命中 1964、ice 命中 service、BJ 命中任意英文串；含中文词条维持子串匹配（中文无空格分词）。
  match(value) {
    let state = 0;
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      let next = this.goto.get(state * CHAR_SPAN + code);
      while (next === undefined && state !== 0) {
        state = this.fail[state];
        next = this.goto.get(state * CHAR_SPAN + code);
      }
      state = next !== undefined ? next : 0;
      // 同一位置可能同时结束多个词条（失配链上的词尾），逐个校验边界
      let reportNode = this.report[state];
      while (reportNode !== -1) {
        const wordIndex = this.wordIndexAt[reportNode];
        const word = this.words[wordIndex];
        if (!isAsciiWord(word) || isWordBoundary(value, word.length, i)) {
          return wordIndex;
        }
        reportNode = this.report[this.fail[reportNode]];
      }
    }
    return null;
  }
}

let cache = { key: '', automaton: null };

// 读取白名单（放行词）为集合；文件缺失/损坏返回空集合（= 无白名单，不影响词库）
function readWhitelist() {
  try {
    const stat = fs.statSync(WHITELIST_FILE);
    const words = new Set();
    for (const rawLine of fs.readFileSync(WHITELIST_FILE, 'utf8').split(/\r?\n/)) {
      const line = rawLine.trim();
      if (line === '' || line.startsWith('#')) {
        continue;
      }
      words.add(normalizeText(line));
    }
    return { words, mtimeMs: stat.mtimeMs };
  } catch {
    return { words: new Set(), mtimeMs: -1 };
  }
}

// 读取词库并构建自动机（词库或白名单变化自动重建；文件缺失/损坏按空词库处理 = 全部放行，不阻塞业务）
function loadAutomaton() {
  try {
    const stat = fs.statSync(WORD_FILE);
    const whitelist = readWhitelist();
    const key = `${stat.mtimeMs}|${whitelist.mtimeMs}`;
    if (key === cache.key && cache.automaton !== null) {
      return cache.automaton;
    }
    const automaton = new Automaton();
    let category = DEFAULT_CATEGORY;
    for (const rawLine of fs.readFileSync(WORD_FILE, 'utf8').split(/\r?\n/)) {
      const line = rawLine.trim();
      if (line === '' || line.startsWith('#')) {
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        category = line.slice(1, -1).trim() || DEFAULT_CATEGORY;
        continue;
      }
      const word = normalizeText(line);
      // 单字符词条（如数字「1」、字母「b」、常用字「日」）无区分度且造成系统性误报
      //（一切含数字/日期的文本均被拦截），统一跳过；词库其余 5 万+ 词条不受影响。
      // 白名单命中的词条一并跳过（多为正常高频词，见 sensitive-whitelist.txt）。
      if (word.length >= 2 && !whitelist.words.has(word)) {
        automaton.insert(word, category);
      }
    }
    automaton.finalize();
    cache = { key, automaton };
    return automaton;
  } catch {
    cache = { key: '', automaton: null };
    return null;
  }
}

function passResult() {
  return { pass: true, category: null, word: null };
}

function scan(automaton, value) {
  const wordIndex = automaton.match(value);
  if (wordIndex === null) {
    return passResult();
  }
  return { pass: false, category: automaton.categories[wordIndex], word: automaton.words[wordIndex] };
}

// 审核一段文本：命中任意词条即拦截；返回 { pass, category, word }
export function checkText(text) {
  const value = normalizeText(text);
  if (value === '') {
    return passResult();
  }
  const automaton = loadAutomaton();
  if (automaton === null) {
    return passResult();
  }
  return scan(automaton, value);
}

// 审核结构化内容（卡片内容 / 组名等）：递归收集全部字符串（跳过账号类字段）逐段审核
export function checkContent(value) {
  const strings = [];
  collectStrings(value, strings);
  const automaton = loadAutomaton();
  if (automaton === null) {
    return passResult();
  }
  for (const text of strings) {
    const value = normalizeText(text);
    if (value === '') {
      continue;
    }
    const result = scan(automaton, value);
    if (!result.pass) {
      return result;
    }
  }
  return passResult();
}

function collectStrings(value, out) {
  if (typeof value === 'string') {
    if (value.trim() !== '') {
      out.push(value);
    }
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      collectStrings(item, out);
    }
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      if (ACCOUNT_KEYS.has(key)) {
        continue;
      }
      collectStrings(child, out);
    }
  }
}

// 拦截提示语前缀：如「卡片内容未通过智能审核（敏感词）」，调用方按场景拼接后缀
export function moderationPrefix(result) {
  const label = result.category !== null ? (CATEGORY_LABELS[result.category] ?? result.category) : '未分类';
  return `卡片内容未通过智能审核（${label}）`;
}
