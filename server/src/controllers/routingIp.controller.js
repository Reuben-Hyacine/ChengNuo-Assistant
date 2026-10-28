import { ok, fail } from '../utils/response.js';
import { isValidIPv4, isValidPort } from '../utils/validate.js';
import { listIps, addIp, removeIp } from '../services/routingIpStore.js';

export async function listRoutingIps(req, res) {
  ok(res, await listIps());
}

export async function addRoutingIp(req, res) {
  const { ip, port = null, name = null, userId = null } = req.body ?? {};
  if (!isValidIPv4(ip)) {
    return fail(res, 40001, 'valid IPv4 address is required');
  }
  if (port !== null && !isValidPort(port)) {
    return fail(res, 40002, 'port must be an integer between 1 and 65535');
  }
  const safeName = typeof name === 'string' && name.trim() !== '' ? name.trim() : null;
  const safeUserId = Number.isInteger(userId) && userId >= 1 ? userId : null;
  try {
    const item = await addIp({ ip, port, name: safeName, userId: safeUserId });
    res.status(201);
    ok(res, item);
  } catch (err) {
    if (err.status === 409) {
      return fail(res, 40901, err.message, 409);
    }
    throw err;
  }
}

export async function removeRoutingIp(req, res) {
  const removed = await removeIp(Number(req.params.id));
  if (!removed) {
    return fail(res, 40402, 'routing ip not found', 404);
  }
  ok(res, removed);
}
