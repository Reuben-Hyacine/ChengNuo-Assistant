import { ok, fail } from '../utils/response.js';
import { config } from '../config.js';
import { buildMessages, parseAIJson, splitFourPart, MODES } from '../services/ai/index.js';
import {
  runAiAsk,
  getAiControlStatus,
  resetAiCard,
  clearAiContext as clearAiContextService,
  completeAiCard,
  deriveFlowStatus,
  assembleContext
} from '../services/ai/aiAskService.js';
import { setConfirmed } from '../services/aiStatusStore.js';
import { getWorkingCard } from '../services/workingCardStore.js';
import { findAccountByUserId } from '../services/accountStore.js';

function modeForState(state) {
  return state === 2 ? MODES.FINALIZE : (state === 1 ? MODES.CONFIRM : MODES.GATHER);
}

// 管理台只给 userId：按 userId 找到账号名，用户资料库/私人卡片库都以账号为单位定位
async function accountOf(userId) {
  const uid = (Number.isInteger(userId) && userId >= 1) ? userId : 1;
  const found = await findAccountByUserId(uid);
  return found ? found.account : null;
}

export async function getAiStatus(req, res) {
  ok(res, {
    ...(await getAiControlStatus()),
    baseUrl: config.ai.baseUrl,
    model: config.ai.model,
    temperature: config.ai.temperature,
    timeoutMs: config.ai.timeoutMs
  });
}

export async function askAi(req, res) {
  const { task, context = null, schemaHint = '', rules = [], userId = null } = req.body ?? {};
  if (typeof task !== 'string' || task.trim() === '') {
    return fail(res, 40001, 'task must be a non-empty string');
  }
  try {
    const account = await accountOf(userId);
    const out = await runAiAsk({ task, context, schemaHint, rules, userId, account });
    ok(res, out);
  } catch (err) {
    return fail(res, 50000, err.message, err.status ?? 500);
  }
}

export async function confirmAi(req, res) {
  const before = await deriveFlowStatus();
  if (before.state !== 1) {
    return fail(res, 40002, `卡片未填齐，无法确认（当前状态 ${before.state}）`);
  }
  await setConfirmed(true);
  ok(res, { workingCard: await getWorkingCard(), flowStatus: await deriveFlowStatus() });
}

export async function resetAi(req, res) {
  ok(res, await resetAiCard());
}

// 一键清空服务器上的对话记录（用户资料库长期保留）
export async function clearAiContext(req, res) {
  ok(res, await clearAiContextService());
}

export async function completeAi(req, res) {
  const { userId = null } = req.body ?? {};
  try {
    ok(res, await completeAiCard({ userId, account: await accountOf(userId) }));
  } catch (err) {
    return fail(res, 50000, err.message, err.status ?? 500);
  }
}

export async function buildPrompt(req, res) {
  const { task, schemaHint = '', userId = null } = req.body ?? {};
  if (typeof task !== 'string' || task.trim() === '') {
    return fail(res, 40001, 'task must be a non-empty string');
  }
  const flowStatus = await deriveFlowStatus();
  const ctx = await assembleContext(await accountOf(userId));
  ok(res, {
    messages: buildMessages({ task, schemaHint, mode: modeForState(flowStatus.state), context: ctx }),
    flowStatus,
    workingCard: await getWorkingCard()
  });
}

export function parseJsonBody(req, res) {
  const { raw } = req.body ?? {};
  if (typeof raw !== 'string' || raw.trim() === '') {
    return fail(res, 40001, 'raw must be a non-empty string');
  }
  const data = parseAIJson(raw);
  ok(res, { raw, data, parts: splitFourPart(data) });
}
