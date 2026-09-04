const { Router } = require('express');
const { requireAuth } = require('../middleware/auth');
const db = require('../db');

const router = Router();

router.get('/', requireAuth, async (req, res, next) => {
  try {
    const result = await db.query(
      'SELECT id, email, full_name, created_at FROM app_users WHERE id = $1 LIMIT 1',
      [req.user.id],
    );

    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    return res.status(200).json({ user: result.rows[0] });
  } catch (err) {
    return next(err);
  }
});

module.exports = router;
