require('dotenv').config();

const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
const { z } = require('zod');
const config = require('./config');
const healthRoute = require('./routes/health');
const authRoute = require('./routes/auth');
const meRoute = require('./routes/me');
const { notFound, errorHandler } = require('./middleware/error-handler');

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', 1);

app.use(helmet({
  crossOriginResourcePolicy: { policy: 'same-site' },
}));

app.use((req, res, next) => {
  if (!config.requireHttps || !config.isProduction) return next();
  const proto = req.header('x-forwarded-proto');
  if (proto === 'https') return next();
  return res.status(403).json({ error: 'HTTPS required' });
});

app.use(cors({
  origin(origin, callback) {
    if (!origin) return callback(null, true);
    if (config.corsOrigins.includes(origin)) return callback(null, true);
    return callback(new Error('Origin not allowed by CORS'));
  },
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: false,
  maxAge: 86400,
}));

app.use(express.json({ limit: '10kb', strict: true }));

app.use((req, _res, next) => {
  const parseResult = z.string().safeParse(req.header('content-type') || '');
  if (!parseResult.success) return next(new Error('Invalid content-type'));
  return next();
});

const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 200,
  standardHeaders: true,
  legacyHeaders: false,
});

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
});

app.use('/health', healthRoute);
app.use('/api', apiLimiter);
app.use('/api/v1/auth', authLimiter, authRoute);
app.use('/api/v1/me', meRoute);

app.use(notFound);
app.use(errorHandler);

app.listen(config.port, () => {
  console.log(`Secure backend running on port ${config.port}`);
});
