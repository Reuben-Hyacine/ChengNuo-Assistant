import { config } from '../../config.js';
import { buildMessages } from './promptBuilder.js';
import { callAI } from './aiClient.js';
import { parseAIJson, splitFourPart } from './jsonParser.js';

export async function runAiJsonTask(options = {}) {
  const { task, context = null, schemaHint = '', rules = [], model, temperature, timeoutMs, mode, system } = options;
  if (typeof task !== 'string' || task.trim() === '') {
    const err = new Error('task must be a non-empty string');
    err.status = 400;
    throw err;
  }
  const safeRules = Array.isArray(rules)
    ? rules.filter(rule => typeof rule === 'string' && rule.trim() !== '')
    : [];
  const messages = buildMessages({ task, context, schemaHint, rules: safeRules, mode, system });
  const raw = await callAI(messages, { model, temperature, timeoutMs });
  const data = parseAIJson(raw);
  const parts = splitFourPart(data);
  return {
    model: model ?? config.ai.model,
    messages,
    raw,
    data,
    parts
  };
}

export { buildMessages, buildSystemPrompt, buildUserPrompt, buildSchema, buildPostcardSchema, buildShopSchema, FOUR_PART_SCHEMA, MODES, CARD_BASE_FIELDS, POSTCARD_TASK, POSTCARD_SYSTEM_PROMPT, SHOP_TASK, SHOP_SYSTEM_PROMPT } from './promptBuilder.js';
export { callAI } from './aiClient.js';
export { parseAIJson, splitFourPart } from './jsonParser.js';
