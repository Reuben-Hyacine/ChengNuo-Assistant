import fs from 'node:fs';
import { config } from '../../config.js';

export function readApiKey() {
  try {
    return fs.readFileSync(config.ai.keyFile, 'utf8').trim();
  } catch {
    return '';
  }
}