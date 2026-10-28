// 词库清洗工具：用「白名单（放行词）」匹配敏感词库，删除词库中被误收录的正常词。
//
// 背景：词库由政治口号等文本切碎生成，混入大量中文高频常用词（「一个」「时间」「计划」…），
//   会系统性误拦正常输入。白名单（server/sensitive-whitelist.txt）声明「这些是正常词，应放行」；
//   本工具把词库中与白名单「归一化后完全相等」的词条删除，让词库文件本身也变干净。
//   引擎侧同样会按白名单跳过（白名单文件保留，作为可追溯、可回退的放行登记）。
//
// 用法（在 server 目录下执行）：
//   node scripts/prune-lexicon.mjs --dry-run   仅报告，不改文件
//   node scripts/prune-lexicon.mjs             实际删除（写回前生成 *.bak 备份）
//
// 安全：全程只做字符串相等比较，输出只打印「白名单里的词」，不会打印词库中的其他词条。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const serverDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const projectDir = path.resolve(serverDir, '..');

const WHITELIST_FILE = path.join(serverDir, 'sensitive-whitelist.txt');

// 需要清洗的词库副本（前端构建产物不放，构建时自动从 rawfile 重新生成；
// client/server 为遗留副本，一并保持一致）
const LEXICON_FILES = [
  path.join(serverDir, 'sensitive-lexicon.txt'),
  path.join(projectDir, 'client', 'Chengnuo-backend', 'harmony', 'src', 'main', 'resources', 'rawfile', 'sensitive-lexicon.txt'),
  path.join(projectDir, 'client', 'server', 'sensitive-lexicon.txt')
];

const dryRun = process.argv.includes('--dry-run');

function normalize(value) {
  return String(value ?? '').toLowerCase().replace(/\s+/g, '');
}

// 读白名单：归一化 → 原词（便于输出与去重）
function readWhitelist() {
  const words = new Map();
  for (const line of fs.readFileSync(WHITELIST_FILE, 'utf8').split(/\r?\n/)) {
    const text = line.trim();
    if (text === '' || text.startsWith('#')) {
      continue;
    }
    words.set(normalize(text), text);
  }
  return words;
}

function prune(file, whitelist) {
  if (!fs.existsSync(file)) {
    console.log(`跳过（文件不存在）：${file}`);
    return 0;
  }
  const raw = fs.readFileSync(file, 'utf8');
  const hasBom = raw.charCodeAt(0) === 0xfeff;
  const text = hasBom ? raw.slice(1) : raw;
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  const kept = [];
  const removed = [];
  for (const line of lines) {
    const trimmed = line.trim();
    // 注释行与分节行原样保留
    if (trimmed !== '' && !trimmed.startsWith('#') && !(trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      const hit = whitelist.get(normalize(trimmed));
      if (hit !== undefined) {
        removed.push(hit);
        continue;
      }
    }
    kept.push(line);
  }
  const rel = path.relative(projectDir, file);
  console.log(`\n[${rel}]`);
  console.log(`  词库总行数：${lines.length}`);
  console.log(`  命中白名单并删除：${removed.length}`);
  if (removed.length > 0) {
    console.log(`  删除词条：${removed.join(' / ')}`);
  }
  if (!dryRun && removed.length > 0) {
    fs.writeFileSync(`${file}.bak`, raw, 'utf8');
    fs.writeFileSync(file, (hasBom ? '\uFEFF' : '') + kept.join(eol), 'utf8');
    console.log(`  已写回（备份：${rel}.bak）`);
  }
  return removed.length;
}

const whitelist = readWhitelist();
console.log(`白名单词数：${whitelist.size}`);
let total = 0;
for (const file of LEXICON_FILES) {
  total += prune(file, whitelist);
}
console.log(`\n合计：${dryRun ? '待删除' : '已删除'} ${total} 条${dryRun ? '（--dry-run，未写回）' : ''}`);