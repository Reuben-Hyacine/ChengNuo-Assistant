import { Jsonl } from '../Jsonl';

/**
 * personalization.txt：首行 1=个性化服务开启 / 0=关闭（缺省视为开启）。
 * 开启：对话记录与 AI 明信片照常记录、随请求上送历史；
 * 关闭：本地对话记录与 AI 明信片全部清空、不再记录、不再生成/保存 AI 明信片，
 *       传输给 AI 的对话记录与用户信息一律为空值。
 */
export class PersonalizationStore {
  private filePath(): string {
    return Jsonl.dataFilePath('personalization.txt');
  }

  /** 读取个性化服务开关（文件缺失 / 内容异常时按开启处理） */
  isEnabled(): boolean {
    const text: string = Jsonl.readText(this.filePath());
    const trimmed: string = text.trim();
    return trimmed !== '0';
  }

  /** 写入个性化服务开关（true=开启 / false=关闭） */
  setEnabled(enabled: boolean): void {
    Jsonl.writeText(this.filePath(), enabled ? '1\n' : '0\n');
  }
}

export const personalizationStore: PersonalizationStore = new PersonalizationStore();
