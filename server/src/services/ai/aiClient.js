import { config } from '../../config.js';
import { readApiKey } from './apiKey.js';

const RETRYABLE_STATUSES = new Set([429, 500, 502, 503, 504]);

export async function callAI(messages, options = {}) {
  const apiKey = options.apiKey ?? readApiKey();
  const baseUrl = options.baseUrl ?? config.ai.baseUrl;
  const model = options.model ?? config.ai.model;
  const temperature = options.temperature ?? config.ai.temperature;
  const timeoutMs = options.timeoutMs ?? config.ai.timeoutMs;
  const maxRetries = options.maxRetries ?? config.ai.maxRetries;

  if (!Array.isArray(messages) || messages.length === 0) {
    const err = new Error('messages must be a non-empty array');
    err.status = 400;
    throw err;
  }
  if (apiKey === '') {
    const err = new Error(`AI is not configured: set your API key in ${config.ai.keyFile}`);
    err.status = 503;
    throw err;
  }

  const url = `${baseUrl.replace(/\/+$/, '')}/chat/completions`;
  let lastError;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await requestOnce(url, { apiKey, model, messages, temperature, timeoutMs });
    } catch (err) {
      lastError = err;
      if (attempt < maxRetries && RETRYABLE_STATUSES.has(err.status)) {
        continue;
      }
      throw err;
    }
  }
  throw lastError;
}

async function requestOnce(url, { apiKey, model, messages, temperature, timeoutMs }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`
      },
      body: JSON.stringify({ model, messages, temperature, stream: false }),
      signal: controller.signal
    });
    if (!response.ok) {
      const detail = await response.text().catch(() => '');
      const err = new Error(`AI API responded ${response.status}: ${detail.slice(0, 300)}`);
      err.status = response.status >= 500 || response.status === 429 ? 502 : response.status;
      throw err;
    }
    const payload = await response.json();
    const content = payload?.choices?.[0]?.message?.content;
    if (typeof content !== 'string' || content === '') {
      const err = new Error('AI API returned empty content');
      err.status = 502;
      throw err;
    }
    return content;
  } catch (err) {
    if (err.name === 'AbortError') {
      const timeoutErr = new Error(`AI request timed out after ${timeoutMs}ms`);
      timeoutErr.status = 504;
      throw timeoutErr;
    }
    if (err instanceof TypeError) {
      const networkErr = new Error(`failed to reach AI API: ${err.message}`);
      networkErr.status = 502;
      throw networkErr;
    }
    throw err;
  } finally {
    clearTimeout(timer);
  }
}
