"""FastGuard 云端账户后端（Flask）。

对接桌面客户端 auth/cloud.py 所需的接口：

    GET  /                              连通性探测（客户端 is_available() 请求 base_url）
    GET  /api/fastguard/health          健康检查
    POST /api/fastguard/auth/login      登录 -> {"success": true, "role": "admin|user"}
    POST /api/fastguard/auth/register   注册 -> {"success": true}

启动：python app.py（监听 FASTGUARD_HOST:FASTGUARD_PORT，默认 127.0.0.1:1444）
"""

import logging
import os
import threading
import time

from dotenv import load_dotenv
from flask import Flask, jsonify, request

from db import RESULT_DUPLICATE, RESULT_INVALID, RESULT_OK, UserStore

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(BASE_DIR, ".env"))


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        return default


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


DB_PATH = os.getenv("FASTGUARD_DB_PATH") or os.path.join(BASE_DIR, "cloud_users.db")
HOST = os.getenv("FASTGUARD_HOST", "127.0.0.1")
PORT = _env_int("FASTGUARD_PORT", 1444)
DEBUG = _env_bool("FASTGUARD_DEBUG", False)
ADMIN_USERNAME = os.getenv("FASTGUARD_ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("FASTGUARD_ADMIN_PASSWORD", "Admin123")
MAX_FAILED_ATTEMPTS = _env_int("FASTGUARD_MAX_FAILED_ATTEMPTS", 5)
LOCKOUT_SECONDS = _env_int("FASTGUARD_LOCKOUT_SECONDS", 300)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("fastguard.cloud")


class LoginThrottle:
    """按 来源IP + 用户名 统计连续失败次数，超限后短时锁定，防止口令爆破。"""

    def __init__(self, max_attempts: int, lockout_seconds: int):
        self.max_attempts = max(1, max_attempts)
        self.lockout_seconds = max(1, lockout_seconds)
        self._lock = threading.Lock()
        self._failures = {}

    def locked_for(self, key: str) -> int:
        """返回剩余锁定秒数，未锁定返回 0。"""
        with self._lock:
            entry = self._failures.get(key)
            if not entry:
                return 0
            count, first_failure = entry
            if count < self.max_attempts:
                return 0
            remaining = self.lockout_seconds - (time.time() - first_failure)
            if remaining <= 0:
                self._failures.pop(key, None)
                return 0
            return int(remaining) + 1

    def register_failure(self, key: str):
        with self._lock:
            count, first_failure = self._failures.get(key, (0, time.time()))
            if count == 0:
                first_failure = time.time()
            self._failures[key] = (count + 1, first_failure)

    def reset(self, key: str):
        with self._lock:
            self._failures.pop(key, None)


def create_app() -> Flask:
    store = UserStore(DB_PATH)
    if store.ensure_admin(ADMIN_USERNAME, ADMIN_PASSWORD):
        logger.info("已创建预置管理员账号: %s", ADMIN_USERNAME)
    throttle = LoginThrottle(MAX_FAILED_ATTEMPTS, LOCKOUT_SECONDS)

    app = Flask(__name__)
    app.json.ensure_ascii = False

    def _credentials():
        data = request.get_json(silent=True) or {}
        username = str(data.get("username") or "").strip()
        password = str(data.get("password") or "")
        return username, password

    @app.get("/")
    def root():
        return jsonify({"service": "FastGuard Cloud Auth", "status": "ok"})

    @app.get("/api/fastguard/health")
    def health():
        return jsonify({"success": True, "status": "ok", "users": store.count()})

    @app.post("/api/fastguard/auth/login")
    def login():
        username, password = _credentials()
        if not username or not password:
            return jsonify({"success": False, "message": "用户名和密码不能为空"})

        key = "%s:%s" % (request.remote_addr, username.lower())
        locked = throttle.locked_for(key)
        if locked:
            logger.warning("登录被限流: user=%s ip=%s", username, request.remote_addr)
            return jsonify({"success": False, "message": "尝试过于频繁，请 %d 秒后重试" % locked})

        role = store.verify(username, password)
        if not role:
            throttle.register_failure(key)
            logger.info("登录失败: user=%s ip=%s", username, request.remote_addr)
            return jsonify({"success": False, "message": "用户名或密码错误"})

        throttle.reset(key)
        logger.info("登录成功: user=%s role=%s ip=%s", username, role, request.remote_addr)
        return jsonify({"success": True, "role": role, "username": username})

    @app.post("/api/fastguard/auth/register")
    def register():
        username, password = _credentials()
        result, message = store.create(username, password)
        if result == RESULT_OK:
            logger.info("注册成功: user=%s ip=%s", username, request.remote_addr)
            return jsonify({"success": True, "message": message})
        status = 409 if result == RESULT_DUPLICATE else 400
        logger.info("注册失败: user=%s reason=%s ip=%s", username, message, request.remote_addr)
        return jsonify({"success": False, "message": message}), status

    @app.errorhandler(404)
    def not_found(_error):
        return jsonify({"success": False, "message": "接口不存在"}), 404

    @app.errorhandler(405)
    def method_not_allowed(_error):
        return jsonify({"success": False, "message": "请求方法不允许"}), 405

    @app.errorhandler(Exception)
    def server_error(error):
        logger.exception("服务端异常: %s", error)
        return jsonify({"success": False, "message": "服务端内部错误"}), 500

    return app


app = create_app()


if __name__ == "__main__":
    logger.info("FastGuard 云端账户后端启动: http://%s:%d", HOST, PORT)
    # debug 模式会启用重载器并占用两个进程，绑定同一端口时需保持关闭
    app.run(host=HOST, port=PORT, debug=DEBUG, threaded=True)
