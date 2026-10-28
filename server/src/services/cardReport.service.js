import { getGroupView, moveGroupToPrivate } from './cardGroupStore.js';
import { pushMail } from './mailboxStore.js';
import { checkText } from './moderation.service.js';
import {
  createCardReport,
  getCardReport,
  listCardReports,
  settleCardReport,
  REPORT_REASONS,
  MAX_REPORT_DETAIL_LEN
} from './cardReportStore.js';

// 公开卡片举报（发现页卡片 ⋯ 菜单提交，服务 104 report.submit）：
//   提交时校验目标仍是公开卡片组内的卡片，快照卡片内容与创建者（防事后改卡/删卡影响记录）；
//   补充说明走智能审核，避免举报通道被用来向维护者传播敏感内容。
// 处理（管理台 /api/reports，仅本机）：驳回 dismiss / 下架 takedown——
//   下架复用 52 cards.unpublish 语义：代创建者把整个卡片组转为私人（清成员与参与人、逐一收件箱通知、
//   清未处理申请），并另行致函创建者说明因举报核实被下架。

export const REPORT_REASON_LABELS = {
  illegal: '违法违规',
  porn: '色情低俗',
  attack: '人身攻击',
  spam: '广告骚扰',
  other: '其他'
};

function accountName(account) {
  return typeof account === 'string' ? account.trim() : '';
}

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function notFound(message) {
  const err = new Error(message);
  err.status = 404;
  return err;
}

function conflict(message) {
  const err = new Error(message);
  err.status = 409;
  return err;
}

function requirePositiveInt(value, label) {
  const num = Number(value);
  if (!Number.isInteger(num) || num < 1) {
    throw badRequest(`${label} must be a positive integer`);
  }
  return num;
}

// 服务 104 report.submit：举报公开卡片组内的一张卡片（同一人对同一卡片的未处理举报幂等去重）
export async function submitCardReport({ account = null, userId = null, groupId = null, cardIndex = null, reason = '', detail = '' } = {}) {
  const reporter = accountName(account);
  if (reporter === '') {
    throw badRequest('需要账号身份才能举报');
  }
  const gid = requirePositiveInt(groupId, 'groupId');
  const idx = requirePositiveInt(cardIndex, 'cardIndex');
  if (!REPORT_REASONS.includes(reason)) {
    throw badRequest('举报理由不合法');
  }
  let extra = typeof detail === 'string' ? detail.trim() : '';
  if (extra.length > MAX_REPORT_DETAIL_LEN) {
    extra = extra.slice(0, MAX_REPORT_DETAIL_LEN);
  }
  if (extra !== '') {
    const moderation = checkText(extra);
    if (!moderation.pass) {
      throw conflict('补充说明未通过智能审核，请修改后重试');
    }
  }
  let group;
  try {
    group = await getGroupView(gid, reporter);
  } catch (err) {
    if (err.status === 404) {
      throw notFound('举报的卡片组不存在');
    }
    // 私人卡片组对非创建者/成员不可见（403）：举报目标只能是被公开浏览的卡片
    if (err.status === 403) {
      throw badRequest('只能举报公开卡片组的卡片');
    }
    throw err;
  }
  if (group.library !== 'public') {
    throw badRequest('只能举报公开卡片组的卡片');
  }
  const card = group.cards.find(c => c.index === idx);
  if (!card) {
    throw notFound('组内卡片不存在');
  }
  const snapshot = {
    groupName: group.name,
    ownerAccount: group.owner,
    cardEvent: typeof card.content.event === 'string' ? card.content.event.trim() : '',
    cardPurpose: typeof card.content.purpose === 'string' ? card.content.purpose.trim() : '',
    cardLocation: typeof card.content.location === 'string' ? card.content.location.trim() : '',
    cardTime: typeof card.content.time === 'string' ? card.content.time.trim() : ''
  };
  const { report, created } = await createCardReport({
    groupId: gid,
    cardIndex: idx,
    reporterAccount: reporter,
    reporterUserId: Number.isInteger(userId) ? userId : null,
    reason,
    detail: extra,
    snapshot
  });
  return {
    report: { id: report.id, status: report.status },
    created,
    message: created
      ? '举报已提交，我们会尽快处理'
      : '你已举报过该卡片，请耐心等待处理'
  };
}

// ---------- 管理台（/api/reports，仅本机可访问） ----------

// 举报目标实时状态：卡片组是否仍存在/仍公开、被举报卡是否还在（举报快照不随之更新）。
// 匿名视角查看：私人组返回 403（组还在但已转私人），已删除返回 404，二者展示语义不同
async function targetStatusOf(report) {
  try {
    const group = await getGroupView(report.groupId, '');
    const card = group.cards.find(c => c.index === report.cardIndex);
    return {
      groupExists: true,
      stillPublic: group.library === 'public',
      cardExists: card !== undefined,
      groupName: group.name,
      ownerAccount: group.owner
    };
  } catch (err) {
    if (err.status === 403) {
      return {
        groupExists: true,
        stillPublic: false,
        cardExists: false,
        groupName: report.groupName,
        ownerAccount: report.ownerAccount
      };
    }
    return {
      groupExists: false,
      stillPublic: false,
      cardExists: false,
      groupName: report.groupName,
      ownerAccount: report.ownerAccount
    };
  }
}

function adminView(report, target) {
  return {
    ...report,
    reasonLabel: REPORT_REASON_LABELS[report.reason] ?? report.reason,
    target
  };
}

// 管理台列表：全部举报（新→旧），附带目标实时状态
export async function listReportsForAdmin() {
  const reports = await listCardReports();
  const out = [];
  for (const report of reports) {
    out.push(adminView(report, await targetStatusOf(report)));
  }
  return { reports: out };
}

// 驳回：举报不成立，仅归档
export async function dismissReport(id) {
  const num = requirePositiveInt(id, 'id');
  const report = await settleCardReport(num, 'dismissed', 'dismiss');
  if (!report) {
    throw conflict('举报不存在或已处理');
  }
  return { report: adminView(report, await targetStatusOf(report)), message: `已驳回举报 #${num}` };
}

// 下架：举报成立——代创建者把整个卡片组转为私人（unpublish 语义），并致函创建者；
// 目标已不可用（卡片组被删/已转私人）时直接归档，不重复操作
export async function takedownReport(id) {
  const num = requirePositiveInt(id, 'id');
  const current = await getCardReport(num);
  if (!current) {
    throw notFound('举报不存在');
  }
  if (current.status !== 'pending') {
    throw conflict('举报已处理');
  }
  const target = await targetStatusOf(current);
  if (!target.groupExists || !target.stillPublic) {
    const report = await settleCardReport(num, 'actioned', 'takedown');
    return {
      report: adminView(report, target),
      message: `举报对象已不可用（卡片组已删除或已转为私人），举报 #${num} 已归档`
    };
  }
  // 代创建者执行 unpublish：清成员/参与人并逐一收件箱通知、清未处理申请
  await moveGroupToPrivate(current.groupId, target.ownerAccount);
  await pushMail({
    toAccount: target.ownerAccount,
    fromAccount: target.ownerAccount,
    title: `卡片组已被下架：${target.groupName}`,
    body: `你创建的卡片组「${target.groupName}」#${current.groupId} 因收到举报并经平台核实，已整体转为私人卡片组（仅你可见），相关成员与参与者已收到通知。如认为处理有误，请通过反馈渠道申诉。`
  });
  const report = await settleCardReport(num, 'actioned', 'takedown');
  return {
    report: adminView(report, await targetStatusOf(report)),
    message: `已把卡片组「${target.groupName}」#${current.groupId} 转为私人（已通知创建者），举报 #${num} 已归档`
  };
}
