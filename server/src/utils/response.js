export function ok(res, data = null, meta = null) {
  return res.json({ code: 0, message: 'ok', data, meta });
}

export function fail(res, code, message, status = 400) {
  return res.status(status).json({ code, message, data: null });
}
