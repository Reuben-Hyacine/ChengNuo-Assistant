export function errorHandler(err, req, res, next) {
  console.error(`[error] ${req.method} ${req.originalUrl}`, err);
  const status = err.status ?? 500;
  res.status(status).json({
    code: status,
    message: err.message ?? 'Internal Server Error',
    data: null
  });
}
