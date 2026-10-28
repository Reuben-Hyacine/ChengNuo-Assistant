/**
 * 展示格式化工具
 */

/** 用户编号（UID）展示文本：不足 5 位左侧补零（1 → 00001，12 → 00012） */
export function uidText(id: number): string {
  let text: string = id.toString();
  while (text.length < 5) {
    text = '0' + text;
  }
  return text;
}
