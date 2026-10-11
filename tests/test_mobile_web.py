"""控制指令层与 Web 服务的回归测试。

覆盖：

* ``mobile/backend/commands.py``：TCP 与 Web 两条通道共用的指令校验/执行逻辑，
  特别是"固定输入模型拒绝改 imgsz"必须在两边表现一致；
* ``mobile/backend/web_ui.py``：手机浏览器直连的 HTTP 接口
  （``/status`` 不含帧率、``POST /api/<cmd>`` 转发到同一引擎、静态资源可访问）。

本文件**不导入 Qt**（用假 bridge 代替引擎），因此可以在任意环境快速运行。

运行方式：
    pytest tests/test_mobile_web.py -v
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from mobile import protocol  # noqa: E402
from mobile.backend import commands  # noqa: E402
from mobile.backend.commands import CommandError  # noqa: E402
from mobile.backend.web_ui import WebService, free_port  # noqa: E402


# ====================================================================== 假引擎
class FakeBridge:
    """最小的引擎替身：记录调用，并模拟"固定输入模型"。"""

    def __init__(self, fixed_inference_size: Optional[int] = None) -> None:
        self.model = "yolo11n.pt"
        self.source = 0
        self.weak_conf = 0.38
        self.edge_strength = 28.0
        self.fixed_inference_size = fixed_inference_size
        self.inference_size = fixed_inference_size or protocol.DEFAULT_INFERENCE_SIZE
        self.bev = False
        self.calls: list = []

    def set_source(self, index: int) -> Any:
        self.calls.append(("set_source", index))
        self.source = index
        return index

    def set_thresholds(self, weak_conf: float, edge_strength: float) -> None:
        self.calls.append(("set_thresholds", weak_conf, edge_strength))
        self.weak_conf = weak_conf
        self.edge_strength = edge_strength

    def set_inference_size(self, size: int) -> int:
        self.calls.append(("set_inference_size", size))
        if self.fixed_inference_size is not None and int(size) != self.fixed_inference_size:
            self._error = (
                f"当前 INT8 模型输入固定为 {self.fixed_inference_size}，无法改为 {size}；"
                f"请选择 {self.fixed_inference_size}，或改用 FP32 权重"
            )
            return self.inference_size
        self._error = None
        self.inference_size = int(size)
        return self.inference_size

    def last_error(self) -> Optional[str]:
        return getattr(self, "_error", None)

    def set_bev_enabled(self, enabled: bool) -> bool:
        self.calls.append(("set_bev_enabled", enabled))
        self.bev = bool(enabled)
        return self.bev

    def snapshot(self) -> Dict[str, Any]:
        return {
            "engine": "VideoThread",
            "state": "running",
            "running": True,
            "source": self.source,
            "inference_size": self.inference_size,
            "fixed_inference_size": self.fixed_inference_size,
            "weak_conf": self.weak_conf,
            "edge_strength": self.edge_strength,
            "bev": self.bev,
            "model": self.model,
            # 引擎原始快照里带 fps；移动端状态必须把它剔除
            "fps": 21.8,
            "last_frame_age": 0.03,
            "error": None,
        }


class FakeHub:
    """最小的 FrameHub 替身（Web 测试不需要真实 JPEG）。"""

    def __init__(self) -> None:
        self.status_calls = 0

    def latest_jpeg(self):
        return 7, b"\xff\xd8fake-jpeg", None

    def status(self) -> Dict[str, Any]:
        self.status_calls += 1
        return {"state": "running"}

    def wait_for_jpeg(self, after_seq: int, timeout: float = 5.0):
        return 7, b"\xff\xd8fake-jpeg", None

    def close(self) -> None:
        pass


# ====================================================================== 指令层
def test_apply_command_set_source():
    bridge = FakeBridge()
    result = commands.apply_command(bridge, protocol.CMD_SET_SOURCE, {"index": 2})
    assert result["ok"] is True and result["source"] == 2
    assert bridge.source == 2


def test_apply_command_rejects_negative_camera_index():
    with pytest.raises(CommandError):
        commands.apply_command(FakeBridge(), protocol.CMD_SET_SOURCE, {"index": -1})


def test_apply_command_thresholds_validates_range():
    bridge = FakeBridge()
    result = commands.apply_command(
        bridge, protocol.CMD_SET_THRESHOLDS, {"weak_conf": 0.5, "edge_strength": 30.0}
    )
    assert result["ok"] is True
    assert bridge.weak_conf == 0.5 and bridge.edge_strength == 30.0

    for bad in ({"weak_conf": 0.0, "edge_strength": 30.0}, {"weak_conf": 1.5, "edge_strength": 30.0},
                {"weak_conf": 0.5, "edge_strength": 0.0}, {"weak_conf": 0.5, "edge_strength": 999.0}):
        with pytest.raises(CommandError):
            commands.apply_command(FakeBridge(), protocol.CMD_SET_THRESHOLDS, bad)


def test_apply_command_inference_size_rejection_is_consistent():
    """固定输入模型拒绝其它 imgsz：返回 ok=False 且带可读原因（不抛异常）。"""
    bridge = FakeBridge(fixed_inference_size=320)
    result = commands.apply_command(bridge, protocol.CMD_SET_INFERENCE_SIZE, {"size": 640})
    assert result["ok"] is False
    assert result["inference_size"] == 320
    assert "固定" in result["reason"]

    ok = commands.apply_command(bridge, protocol.CMD_SET_INFERENCE_SIZE, {"size": 320})
    assert ok["ok"] is True and ok["inference_size"] == 320


def test_apply_command_missing_params_raise():
    for action, params in (
        (protocol.CMD_SET_SOURCE, {}),
        (protocol.CMD_SET_THRESHOLDS, {"weak_conf": 0.5}),
        (protocol.CMD_SET_INFERENCE_SIZE, {}),
    ):
        with pytest.raises(CommandError):
            commands.apply_command(FakeBridge(), action, params)


def test_apply_command_unknown_action_raises():
    with pytest.raises(CommandError):
        commands.apply_command(FakeBridge(), "do_something_else", {})


def test_apply_command_ping_and_bev():
    bridge = FakeBridge()
    assert commands.apply_command(bridge, protocol.CMD_PING, {})["ok"] is True
    assert commands.apply_command(bridge, protocol.CMD_SET_BEV, {"enabled": True})["bev"] is True
    assert bridge.bev is True


def test_normalize_action_accepts_path_and_dash_forms():
    assert commands.normalize_action("/api/set_source") == "set_source"
    assert commands.normalize_action("api/set-inference-size") == "set_inference_size"
    assert commands.normalize_action("PING") == "ping"


def test_normalize_action_maps_web_short_names():
    """Web 端为了 URL 简洁使用短名，必须折算到协议常量（否则两条通道行为不一致）。"""
    assert commands.normalize_action("/api/source") == protocol.CMD_SET_SOURCE
    assert commands.normalize_action("source") == protocol.CMD_SET_SOURCE
    assert commands.normalize_action("thresholds") == protocol.CMD_SET_THRESHOLDS
    assert commands.normalize_action("inference_size") == protocol.CMD_SET_INFERENCE_SIZE
    assert commands.normalize_action("size") == protocol.CMD_SET_INFERENCE_SIZE
    assert commands.normalize_action("bev") == protocol.CMD_SET_BEV
    # 未知名字保持原样，交由 apply_command 报"未知指令"
    assert commands.normalize_action("nope") == "nope"


# ====================================================================== Web 服务
@pytest.fixture
def web():
    bridge = FakeBridge()
    hub = FakeHub()
    service = WebService("127.0.0.1", 0, hub, bridge)
    bound = service.start()
    yield service, bridge, hub, f"http://127.0.0.1:{bound}"
    service.stop()


def _get_json(url: str, timeout: float = 5.0):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.status, json.loads(response.read().decode("utf-8"))


def _post_json(url: str, payload: Dict[str, Any], timeout: float = 5.0):
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        return exc.code, json.loads(body) if body else {}


def test_web_index_serves_mobile_ui(web):
    service, _bridge, _hub, base = web
    with urllib.request.urlopen(f"{base}/", timeout=5) as response:
        html = response.read().decode("utf-8")
    assert response.status == 200
    # 设计要求：右上角"卸载推理"、左上角汉堡设置栏
    assert "卸载推理" in html
    assert 'id="hamburger"' in html
    assert 'id="drawer"' in html
    # 只显示 AI 推理画面；不得出现预处理画面，也不得出现帧率
    assert "预处理" not in html
    assert "帧率" not in html
    assert "/stream" in html


def test_web_static_assets(web):
    _service, _bridge, _hub, base = web
    for path, expect in (("/style.css", "text/css"), ("/app.js", "javascript")):
        with urllib.request.urlopen(f"{base}{path}", timeout=5) as response:
            body = response.read().decode("utf-8")
            assert response.status == 200
            assert expect in response.headers.get("Content-Type", "")
            assert body.strip()


def test_web_app_js_implements_required_controls(web):
    _service, _bridge, _hub, base = web
    with urllib.request.urlopen(f"{base}/app.js", timeout=5) as response:
        script = response.read().decode("utf-8")
    # 切换摄像头 / 阈值设置 / 推理图片大小 / BEV（postCommand 会在运行时拼成 /api/<cmd>）
    assert "postCommand(" in script
    for action in ("'source'", "'thresholds'", "'inference_size'", "'bev'"):
        assert action in script, f"缺少 {action} 指令调用"
    assert "CAMERA_CHOICES" in script and "SIZE_CHOICES" in script
    assert "fixed_inference_size" in script  # 固定输入模型时禁用其它尺寸


def test_web_status_excludes_fps(web):
    _service, _bridge, _hub, base = web
    status, payload = _get_json(f"{base}/status")
    assert status == 200
    assert payload["inference_size"] == protocol.DEFAULT_INFERENCE_SIZE
    # 移动端不展示帧率：状态里必须剔除
    assert "fps" not in payload
    assert "frame_rate" not in payload


def test_web_post_commands_reach_engine(web):
    service, bridge, _hub, base = web

    status, payload = _post_json(f"{base}/api/source", {"index": 1})
    assert status == 200 and payload["ok"] is True
    assert bridge.source == 1
    assert payload["status"]["source"] == 1

    status, payload = _post_json(f"{base}/api/thresholds", {"weak_conf": 0.6, "edge_strength": 40.0})
    assert status == 200 and payload["ok"] is True
    assert bridge.weak_conf == 0.6 and bridge.edge_strength == 40.0

    status, payload = _post_json(f"{base}/api/inference_size", {"size": 640})
    assert status == 200 and payload["ok"] is True
    assert bridge.inference_size == 640

    status, payload = _post_json(f"{base}/api/bev", {"enabled": True})
    assert status == 200 and payload["ok"] is True
    assert bridge.bev is True


def test_web_post_rejection_returns_409_with_reason(web):
    """固定输入模型下 Web 端也要返回可读原因（HTTP 409）。"""
    service, bridge, _hub, base = web
    bridge.fixed_inference_size = 320
    bridge.inference_size = 320

    status, payload = _post_json(f"{base}/api/inference_size", {"size": 512})
    assert status == 409
    assert payload["ok"] is False
    assert "固定" in payload["reason"]
    assert payload["inference_size"] == 320


def test_web_post_bad_request(web):
    _service, _bridge, _hub, base = web

    status, payload = _post_json(f"{base}/api/thresholds", {"weak_conf": 0.5})
    assert status == 400
    assert payload["ok"] is False

    status, payload = _post_json(f"{base}/api/unknown_cmd", {"x": 1})
    assert status == 400
    assert payload["ok"] is False


def test_web_unknown_path_returns_404(web):
    _service, _bridge, _hub, base = web
    try:
        urllib.request.urlopen(f"{base}/nope", timeout=5)
        raise AssertionError("应当返回 404")
    except urllib.error.HTTPError as exc:
        assert exc.code == 404


def test_web_bev_endpoint_reports_missing(web):
    _service, _bridge, _hub, base = web
    try:
        urllib.request.urlopen(f"{base}/bev", timeout=5)
        raise AssertionError("BEV 未开启时应返回 404")
    except urllib.error.HTTPError as exc:
        assert exc.code == 404


def test_web_action_can_come_from_body(web):
    """也支持 POST /api 用 {"action": ...} 的形式。"""
    _service, bridge, _hub, base = web
    status, payload = _post_json(f"{base}/api", {"action": "set_source", "index": 3})
    assert status == 200 and payload["ok"] is True
    assert bridge.source == 3


def test_private_ipv4_validation():
    """局域网地址只认 RFC1918：实测遇到过 28.0.0.1 这种不可用地址。"""
    from mobile.backend.web_ui import _is_private_ipv4

    assert _is_private_ipv4("192.168.1.20") is True
    assert _is_private_ipv4("10.0.0.5") is True
    assert _is_private_ipv4("172.16.3.9") is True
    assert _is_private_ipv4("172.31.255.254") is True

    assert _is_private_ipv4("127.0.0.1") is False
    assert _is_private_ipv4("28.0.0.1") is False      # 实测踩到的假地址
    assert _is_private_ipv4("169.254.1.1") is False   # link-local
    assert _is_private_ipv4("172.32.0.1") is False    # 172.32 不在 16-31 段
    assert _is_private_ipv4("8.8.8.8") is False
    assert _is_private_ipv4("") is False
    assert _is_private_ipv4("not-an-ip") is False


def test_local_ip_is_usable_or_loopback():
    from mobile.backend.web_ui import _is_private_ipv4, local_ip

    address = local_ip()
    assert address == "127.0.0.1" or _is_private_ipv4(address), address


def test_describe_url_reports_both_addresses():
    from mobile.backend.web_ui import describe_url

    local, lan = describe_url(8080)
    assert local == "http://127.0.0.1:8080/"
    assert lan.startswith("http://") and lan.endswith(":8080/")
