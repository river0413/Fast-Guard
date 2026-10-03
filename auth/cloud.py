"""云端账户系统对接。

登录与注册均通过配置文件中的“云端特定路径”请求后端账户系统完成。
当云端后端不可连接（未配置、网络异常、超时等）时，调用方应跳过登录，
直接以本地管理员身份进入系统。
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

# 云端请求结果状态
STATUS_OK = "ok"                    # 验证通过 / 注册成功
STATUS_INVALID = "invalid"          # 用户名或密码错误 / 注册被拒绝
STATUS_UNAVAILABLE = "unavailable"  # 无法连接云端后端

# 云端不可连接时使用的本地身份
OFFLINE_USERNAME = "本地用户"
OFFLINE_ROLE = "admin"

DEFAULT_CONFIG = {
    "base_url": "",
    "login_path": "/api/fastguard/auth/login",
    "register_path": "/api/fastguard/auth/register",
    "timeout": 5,
}


def _default_config_path() -> str:
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base_dir, "data", "cloud_auth.json")


class CloudAuthClient:
    """访问云端账户系统的客户端。

    配置读取顺序：环境变量 FASTGUARD_CLOUD_AUTH_CONFIG 指定的文件，
    否则为 data/cloud_auth.json（不存在时自动生成模板）。
    """

    def __init__(self, config_path: str = None):
        self.config_path = config_path or os.environ.get(
            "FASTGUARD_CLOUD_AUTH_CONFIG"
        ) or _default_config_path()
        self.base_url = ""
        self.login_path = DEFAULT_CONFIG["login_path"]
        self.register_path = DEFAULT_CONFIG["register_path"]
        self.timeout = DEFAULT_CONFIG["timeout"]
        self._load_config()

    def _load_config(self):
        if not os.path.exists(self.config_path):
            self._write_default_config()
        try:
            with open(self.config_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            return
        if not isinstance(data, dict):
            return
        self.base_url = str(data.get("base_url") or "").strip()
        self.login_path = str(data.get("login_path") or DEFAULT_CONFIG["login_path"])
        self.register_path = str(data.get("register_path") or DEFAULT_CONFIG["register_path"])
        try:
            self.timeout = max(1.0, float(data.get("timeout") or DEFAULT_CONFIG["timeout"]))
        except (TypeError, ValueError):
            self.timeout = DEFAULT_CONFIG["timeout"]

    def _write_default_config(self):
        try:
            os.makedirs(os.path.dirname(self.config_path), exist_ok=True)
            with open(self.config_path, "w", encoding="utf-8") as f:
                json.dump(DEFAULT_CONFIG, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    @property
    def configured(self) -> bool:
        return bool(self.base_url)

    def _url(self, path: str) -> str:
        return urllib.parse.urljoin(self.base_url.rstrip("/") + "/", path.lstrip("/"))

    def _post_json(self, url: str, payload: dict) -> str:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Content-Type", "application/json; charset=utf-8")
        req.add_header("Accept", "application/json")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")

    @staticmethod
    def _parse_json(text: str):
        try:
            return json.loads(text)
        except Exception:
            return None

    def is_available(self) -> bool:
        """探测云端后端是否可连接。未配置或网络异常时返回 False。"""
        if not self.configured:
            return False
        req = urllib.request.Request(self.base_url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=min(self.timeout, 3.0)) as resp:
                resp.read(1)
            return True
        except urllib.error.HTTPError:
            # 服务器返回了 HTTP 响应，说明后端可连接
            return True
        except Exception:
            return False

    def login(self, username: str, password: str):
        """向云端校验账号，返回 (status, role)。"""
        if not self.configured:
            return STATUS_UNAVAILABLE, None
        try:
            text = self._post_json(
                self._url(self.login_path),
                {"username": username, "password": password},
            )
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                return STATUS_INVALID, None
            return STATUS_UNAVAILABLE, None
        except Exception:
            return STATUS_UNAVAILABLE, None

        data = self._parse_json(text)
        if not isinstance(data, dict):
            return STATUS_UNAVAILABLE, None
        if data.get("success") is True:
            return STATUS_OK, str(data.get("role") or "user")
        if data.get("success") is False:
            return STATUS_INVALID, None
        # 缺少 success 字段视为无效凭据（兼容仅返回 role 的后端）
        role = data.get("role")
        if role:
            return STATUS_OK, str(role)
        return STATUS_INVALID, None

    def register(self, username: str, password: str) -> str:
        """向云端注册账号，返回状态码。"""
        if not self.configured:
            return STATUS_UNAVAILABLE
        try:
            text = self._post_json(
                self._url(self.register_path),
                {"username": username, "password": password},
            )
        except urllib.error.HTTPError as exc:
            if exc.code in (400, 409, 422):
                return STATUS_INVALID
            return STATUS_UNAVAILABLE
        except Exception:
            return STATUS_UNAVAILABLE

        data = self._parse_json(text)
        if not isinstance(data, dict):
            return STATUS_UNAVAILABLE
        if data.get("success") is True:
            return STATUS_OK
        return STATUS_INVALID
