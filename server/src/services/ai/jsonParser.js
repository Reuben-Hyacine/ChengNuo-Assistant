function stripCodeFence(text) {
  const match = text.match(/```[a-zA-Z]*\s*([\s\S]*?)```/);
  if (!match) {
    return null;
  }
  return match[1].trim();
}

function extractJsonBlock(text) {
  const start = text.search(/[\[{]/);
  if (start === -1) {
    return null;
  }
  const openChar = text[start];
  const closeChar = openChar === '{' ? '}' : ']';
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (ch === '\\' && inString) {
      escaped = true;
      continue;
    }
    if (ch === '"') {
      inString = !inString;
      continue;
    }
    if (inString) {
      continue;
    }
    if (ch === openChar) {
      depth++;
    } else if (ch === closeChar) {
      depth--;
      if (depth === 0) {
        return text.slice(start, i + 1);
      }
    }
  }
  return null;
}

function removeTrailingCommas(text) {
  return text.replace(/,\s*([}\]])/g, '$1');
}

export function parseAIJson(text) {
  if (typeof text !== 'string' || text.trim() === '') {
    const err = new Error('AI response is empty');
    err.status = 502;
    throw err;
  }
  const fence = stripCodeFence(text);
  const sources = [text];
  if (fence !== null) {
    sources.push(fence);
  }
  const candidates = [];
  for (const source of sources) {
    candidates.push(source);
    const block = extractJsonBlock(source);
    if (block !== null && block !== source) {
      candidates.push(block);
    }
  }
  for (const candidate of candidates) {
    try {
      return JSON.parse(candidate);
    } catch {
      try {
        return JSON.parse(removeTrailingCommas(candidate));
      } catch {
      }
    }
  }
  const err = new Error(`failed to parse JSON from AI response: ${text.slice(0, 200)}`);
  err.status = 502;
  throw err;
}

export function splitFourPart(data) {
  const d = (data && typeof data === 'object' && !Array.isArray(data)) ? data : {};
  return {
    cards: Array.isArray(d.cards) ? d.cards : [],
    users: Array.isArray(d.users) ? d.users : [],
    reply: typeof d.reply === 'string' ? d.reply : '',
    status: (d.status && typeof d.status === 'object' && !Array.isArray(d.status)) ? d.status : {}
  };
}
