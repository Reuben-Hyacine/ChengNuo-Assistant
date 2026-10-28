export function notFound(req, res) {
  res.status(404).json({
    code: 404,
    message: `Not Found: ${req.method} ${req.originalUrl}`,
    data: null
  });
}