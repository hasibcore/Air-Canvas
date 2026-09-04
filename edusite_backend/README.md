# Edusite Secure Backend

This service provides a secure backend foundation for website frontend + backend + database communication.

## Security baseline

- Helmet security headers
- Strict CORS allowlist (`CORS_ORIGINS`)
- HTTPS enforcement in production (`REQUIRE_HTTPS=true`)
- API and auth rate limiting
- Password hashing with bcrypt
- JWT authentication (short-lived)
- Input validation with Zod
- PostgreSQL parameterized queries (SQL injection resistant)
- PostgreSQL TLS-capable connection (`DB_SSL_MODE=require`)

## Setup

1. Copy env file:

```bash
cp .env.example .env
```

2. Install dependencies:

```bash
npm install
```

3. Create schema:

```bash
psql "$DATABASE_URL" -f sql/schema.sql
```

4. Start backend:

```bash
npm run start
```

## API

- `GET /health`
- `POST /api/v1/auth/register` `{ email, password, fullName }`
- `POST /api/v1/auth/login` `{ email, password }`
- `GET /api/v1/me` with `Authorization: ******
