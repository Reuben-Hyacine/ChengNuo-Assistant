import { ChatMsg } from './Types';

/**
 * 演示数据（mock）：仅保留离线演示 AI 的开场白；
 * 页面数据一律来自后端/服务器，没有数据时展示空态。
 */
export class MockData {
  static initialChat(): ChatMsg[] {
    return [
      ChatMsg.of('m0', true, '想记点什么？说出你的计划，我来帮你安排 ✍️', [])
    ];
  }
}
