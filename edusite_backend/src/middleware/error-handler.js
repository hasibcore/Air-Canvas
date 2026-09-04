const config = require('../config');

function notFound(_req, res) {
  res.status(404).json({ error: 'Not found' });
}

function errorHandler(err, _req, res, _next) {
  const status = err.statusCode || 500;
  if (!config.isProduction) {
    console.error(err);
  }

  res.status(status).json({
    error: status === 500 ? 'Internal server error' : err.message,
  });
}

module.exports = { notFound, errorHandler };
