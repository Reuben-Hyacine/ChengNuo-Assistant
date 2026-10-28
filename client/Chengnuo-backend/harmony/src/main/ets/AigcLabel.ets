/**
 * AI 生成合成内容隐式标识（《人工智能生成合成内容标识办法》第二条、
 * GB 45438-2025《网络安全技术 人工智能生成合成内容标识方法》）
 *
 * AI 生成的文本内容（AI 日程助手回复）写入本机对话记录（conversations.txt）时，
 * 在数据层附加本隐式标识：含标识类型、生成合成服务提供者、生成合成服务名称、
 * 生成合成模型、内容编号、生成时间，不在聊天界面直接展示（隐式）；
 * 用户可在「我的 → 通用设置 → 个人信息 → AI 对话记录」查看每条 AI 回复的隐式标识。
 */
export class AigcLabel {
  /** 生成合成服务提供者（运营主体） */
  static readonly PROVIDER: string = '沈宜其';
  /** 生成合成服务名称 */
  static readonly SERVICE: string = '程诺助手';
  /** 生成合成模型（DeepSeek 第三方 API，经开发者服务器中转调用） */
  static readonly MODEL: string = 'DeepSeek';

  /** 构建隐式标识（JSON 元数据字符串）：
   *  contentId = 内容编号（本条 AI 内容唯一标识），generatedAt = 生成时间（ISO 8601） */
  static build(contentId: string, generatedAt: string): string {
    const label: Record<string, Object> = {
      'LabelType': 'AIGC_TEXT',
      'ServiceProvider': AigcLabel.PROVIDER,
      'ServiceName': AigcLabel.SERVICE,
      'Model': AigcLabel.MODEL,
      'ProduceID': contentId,
      'GeneratedAt': generatedAt
    };
    return JSON.stringify(label);
  }
}
