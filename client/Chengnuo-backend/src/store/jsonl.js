import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 客户端本地存储基座：与服务器各库同一套惯例——UTF-8 JSONL + 懒加载 + 整体重写、写入剥离 BOM。
// 这些文件位于客户端自己的 data/ 目录，可手动编辑（断网时直接改文件，联网后由同步服务上传）。

export function dataFilePath(name) {
  return path.join(config.dataDir, name);
}

export function stripBom(text) {
  return text && text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
}

// 串行化执行链：同一个库的读写按调用顺序排队，避免并发写坏文件
export function serializedChain() {
  let chain = Promise.resolve();
  return function run(task) {
    const current = chain.then(task, task);
    chain = current.then(() => {}, () => {});
    return current;
  };
}

export async function ensureFile(filePath) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  try {
    await fs.access(filePath);
  } catch {
    await fs.writeFile(filePath, '', 'utf8');
  }
}

export async function readJsonl(filePath) {
  await ensureFile(filePath);
  const text = stripBom(await fs.readFile(filePath, 'utf8'));
  const out = [];
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() === '') {
      continue;
    }
    try {
      out.push(JSON.parse(line));
    } catch {
      // 跳过损坏行（手动编辑出错时不影响其它记录）
    }
  }
  return out;
}

export async function writeJsonl(filePath, records) {
  await ensureFile(filePath);
  const lines = records.map(record => JSON.stringify(record));
  await fs.writeFile(filePath, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

// 参与人列表字符串中的账号改名（、/,/， 分隔；命中返回新串，未命中返回 null；对齐 ArkTS JsonRec.renameInParticipants）
export function renameInParticipants(value, oldName, newName) {
  if (typeof value !== 'string') {
    return null;
  }
  const parts = value.split(/[、,，]/).map(s => s.trim()).filter(s => s !== '');
  if (!parts.includes(oldName)) {
    return null;
  }
  return parts.map(p => p === oldName ? newName : p).join('、');
}