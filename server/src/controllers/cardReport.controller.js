import { ok } from '../utils/response.js';
import { listReportsForAdmin, dismissReport, takedownReport } from '../services/cardReport.service.js';

// 举报管理台（/api/reports，仅本机可访问）：列表 / 驳回 / 下架。
// 服务异常（带 status 的 Error）由全局 errorHandler 统一映射为 HTTP 状态与 message。
export async function listReports(req, res) {
  ok(res, await listReportsForAdmin());
}

export async function dismissReportHandler(req, res) {
  ok(res, await dismissReport(Number(req.params.id)));
}

export async function takedownReportHandler(req, res) {
  ok(res, await takedownReport(Number(req.params.id)));
}
