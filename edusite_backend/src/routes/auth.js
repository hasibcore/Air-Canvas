const { Router } = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { z } = require('zod');
const config = require('../config');
const db = require('../db');

const router = Router();

const registerSchema = z.object({
  email: z.string().email().max(254),
  password: z.string().min(12).max(128),
  fullName: z.string().trim().min(2).max(100),
});

const loginSchema = z.object({
  email: z.string().email().max(254),
  password: z.string().min(12).max(128),
});

router.post('/register', async (req, res, next) => {
  try {
    const input = registerSchema.parse(req.body);
    const passwordHash = await bcrypt.hash(input.password, config.bcryptRounds);

    const result = await db.query(
      'INSERT INTO app_users (email, full_name, password_hash) VALUES ($1, $2, $3) RETURNING id, email, full_name, created_at',
      [input.email.toLowerCase(), input.fullName, passwordHash],
    );

    res.status(201).json({ user: result.rows[0] });
  } catch (err) {
    if (err?.code === '23505') {
      return res.status(409).json({ error: 'Email already exists' });
    }
    return next(err);
  }
});

router.post('/login', async (req, res, next) => {
  try {
    const input = loginSchema.parse(req.body);
    const result = await db.query(
      'SELECT id, email, password_hash FROM app_users WHERE email = $1 LIMIT 1',
      [input.email.toLowerCase()],
    );

    if (result.rowCount === 0) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const user = result.rows[0];
    const isMatch = await bcrypt.compare(input.password, user.password_hash);
    if (!isMatch) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const token = jwt.sign(
      { email: user.email },
      config.jwtSecret,
      { subject: String(user.id), expiresIn: config.jwtExpiresIn, algorithm: 'HS256' },
    );

    return res.status(200).json({ token });
  } catch (err) {
    return next(err);
  }
});

module.exports = router;
