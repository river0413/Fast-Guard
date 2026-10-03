"""云端账户后端的 SQLite 用户存储。"""

import os
import re
import sqlite3
import time

from werkzeug.security import check_password_hash, generate_password_hash

RESULT_OK = "ok"
RESULT_DUPLICATE = "duplicate"
RESULT_INVALID = "invalid"

USERNAME_RE = re.compile(r"^[A-Za-z0-9_\u4e00-\u9fff]{3,32}$")
MIN_PASSWORD_LENGTH = 6


def _now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


class UserStore:
    def __init__(self, db_path: str):
        self.db_path = db_path
        os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
        self._init_db()

    def _connect(self):
        conn = sqlite3.connect(self.db_path, timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self):
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    username TEXT PRIMARY KEY,
                    password_hash TEXT NOT NULL,
                    role TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """
            )

    def ensure_admin(self, username: str, password: str) -> bool:
        """首次启动时创建预置管理员账号，已存在则不动。"""
        if not username or not password:
            return False
        with self._connect() as conn:
            row = conn.execute(
                "SELECT role FROM users WHERE username=?", (username,)
            ).fetchone()
            if row is not None:
                return False
            conn.execute(
                "INSERT INTO users (username, password_hash, role, created_at) VALUES (?, ?, ?, ?)",
                (username, generate_password_hash(password), "admin", _now()),
            )
        return True

    def verify(self, username: str, password: str):
        """校验账号，成功返回角色，失败返回 None。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT password_hash, role FROM users WHERE username=?", (username,)
            ).fetchone()
        if row is None:
            return None
        if not check_password_hash(row["password_hash"], password):
            return None
        return row["role"]

    def create(self, username: str, password: str, role: str = "user"):
        """注册新账号，返回 (结果常量, 说明文案)。"""
        if not username or not USERNAME_RE.match(username):
            return RESULT_INVALID, "用户名需为 3-32 位字母、数字、下划线或中文"
        if not password or len(password) < MIN_PASSWORD_LENGTH:
            return RESULT_INVALID, "密码长度至少 %d 位" % MIN_PASSWORD_LENGTH
        with self._connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM users WHERE username=?", (username,)
            ).fetchone()
            if row is not None:
                return RESULT_DUPLICATE, "用户名已存在"
            conn.execute(
                "INSERT INTO users (username, password_hash, role, created_at) VALUES (?, ?, ?, ?)",
                (username, generate_password_hash(password), role, _now()),
            )
        return RESULT_OK, "注册成功"

    def list_users(self):
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT username, role, created_at FROM users ORDER BY created_at DESC"
            ).fetchall()
        return [dict(row) for row in rows]

    def count(self) -> int:
        with self._connect() as conn:
            return conn.execute("SELECT COUNT(*) FROM users").fetchone()[0]
