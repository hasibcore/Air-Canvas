const { z } = require('zod');

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(4000),
  DATABASE_URL: z.string().url(),
  JWT_SECRET: z.string().min(32),
  JWT_EXPIRES_IN: z.string().default('15m'),
  CORS_ORIGINS: z.string().default('http://localhost:3000'),
  BCRYPT_ROUNDS: z.coerce.number().int().min(10).max(14).default(12),
  REQUIRE_HTTPS: z.enum(['true', 'false']).default('true'),
  DB_SSL_MODE: z.enum(['require', 'disable']).default('require'),
});

const parsed = envSchema.safeParse(process.env);
if (!parsed.success) {
  console.error('Invalid environment configuration:', parsed.error.flatten().fieldErrors);
  process.exit(1);
}

const env = parsed.data;

module.exports = {
  isProduction: env.NODE_ENV === 'production',
  port: env.PORT,
  databaseUrl: env.DATABASE_URL,
  jwtSecret: env.JWT_SECRET,
  jwtExpiresIn: env.JWT_EXPIRES_IN,
  corsOrigins: env.CORS_ORIGINS.split(',').map((s) => s.trim()).filter(Boolean),
  bcryptRounds: env.BCRYPT_ROUNDS,
  requireHttps: env.REQUIRE_HTTPS === 'true',
  dbSslMode: env.DB_SSL_MODE,
};
