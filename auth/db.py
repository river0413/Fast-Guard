"""本地存储：运行日志库。

本地账号体系已移除，登录与注册统一由云端账户系统处理（见 auth/cloud.py），
本模块只负责本地运行日志的读写。
"""

import os
import sqlite3
import time

DB_NAME = "fastguard.db"
LEGACY_DB_NAME = "users.db"


def _checkpoint_wal(db_path: str):
    """把 WAL 中未落盘的内容合并回主库文件，避免迁移时丢日志。"""
    try:
        with sqlite3.connect(db_path) as conn:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except sqlite3.Error:
        pass


def _migrate_legacy_db(db_path: str):
    """旧版本把本地账号与日志放在同一个 users.db，这里迁移为新的日志库文件名。"""
    legacy_path = os.path.join(os.path.dirname(db_path), LEGACY_DB_NAME)
    if os.path.exists(legacy_path) and not os.path.exists(db_path):
        _checkpoint_wal(legacy_path)
        try:
            os.replace(legacy_path, db_path)
        except OSError:
            return
    for suffix in ("-wal", "-shm"):
        sidecar = legacy_path + suffix
        if os.path.exists(sidecar):
            try:
                os.remove(sidecar)
            except OSError:
                pass


def default_db_path() -> str:
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    data_dir = os.path.join(base_dir, "data")
    os.makedirs(data_dir, exist_ok=True)
    db_path = os.path.join(data_dir, DB_NAME)
    _migrate_legacy_db(db_path)
    return db_path


class LogDB:
    def __init__(self, db_path=None):
        self.db_path = db_path or default_db_path()
        self._init_db()

    def _init_db(self):
        with sqlite3.connect(self.db_path) as conn:
            cur = conn.cursor()
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS logs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT NOT NULL,
                    level TEXT NOT NULL,
                    message TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    category TEXT NOT NULL
                )
                """
            )
            # 本地账号表已废弃，随迁移一并清理
            cur.execute("DROP TABLE IF EXISTS users")
            conn.commit()

    def add_log(self, username: str, level: str, message: str, category: str = "system"):
        with sqlite3.connect(self.db_path) as conn:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO logs (username, level, message, created_at, category) VALUES (?, ?, ?, ?, ?)",
                (username, level, message, time.strftime("%Y-%m-%d %H:%M:%S"), category)
            )
            conn.commit()

    def list_logs(self, username: str = None, limit: int = 500):
        with sqlite3.connect(self.db_path) as conn:
            cur = conn.cursor()
            if username:
                cur.execute(
                    "SELECT id, username, level, message, created_at, category FROM logs WHERE username=? ORDER BY id DESC LIMIT ?",
                    (username, limit)
                )
            else:
                cur.execute(
                    "SELECT id, username, level, message, created_at, category FROM logs ORDER BY id DESC LIMIT ?",
                    (limit,)
                )
            return cur.fetchall()

    def clear_logs(self, username: str = None):
        with sqlite3.connect(self.db_path) as conn:
            cur = conn.cursor()
            if username:
                cur.execute("DELETE FROM logs WHERE username=?", (username,))
            else:
                cur.execute("DELETE FROM logs")
            conn.commit()
