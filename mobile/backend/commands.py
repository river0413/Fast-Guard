"""控制指令的统一处理。

TCP 服务（``frame_server``）与 Web 服务（``web_ui``）共用这里的实现，
避免两条通道各自的校验规则发生漂移 —— 例如"INT8 固定输入模型拒绝其它 imgsz"
这一条必须在两边表现一致。

本模块**不依赖任何 Qt 绑定**，因此可以独立测试。
"""

from __future__ import annotations

from typing import Any, Dict, List

from mobile import protocol

#: 需要转发给引擎的指令（客户端可下发）。
SUPPORTED_ACTIONS = (
    protocol.CMD_SET_SOURCE,
    protocol.CMD_SET_THRESHOLDS,
    protocol.CMD_SET_INFERENCE_SIZE,
    protocol.CMD_SET_BEV,
    protocol.CMD_PING,
)

#: 指令别名 → 规范名。
#:
#: Web 端为了让 URL 简洁（``POST /api/source``）使用短名，这里统一折算到协议常量，
#: 保证 TCP 与 Web 两条通道最终落到同一套校验逻辑上。
ACTION_ALIASES = {
    "source": protocol.CMD_SET_SOURCE,
    "camera": protocol.CMD_SET_SOURCE,
    "set_camera": protocol.CMD_SET_SOURCE,
    "thresholds": protocol.CMD_SET_THRESHOLDS,
    "set_threshold": protocol.CMD_SET_THRESHOLDS,
    "inference_size": protocol.CMD_SET_INFERENCE_SIZE,
    "size": protocol.CMD_SET_INFERENCE_SIZE,
    "set_size": protocol.CMD_SET_INFERENCE_SIZE,
    "imgz": protocol.CMD_SET_INFERENCE_SIZE,
    "bev": protocol.CMD_SET_BEV,
    "set_bev_enabled": protocol.CMD_SET_BEV,
    "ping": protocol.CMD_PING,
}


class CommandError(ValueError):
    """指令本身不合法（未知指令、参数缺失或类型错误）。"""


def _require(params: Dict[str, Any], key: str) -> Any:
    if key not in params or params[key] is None or params[key] == "":
        raise CommandError(f"缺少参数 {key}")
    return params[key]


def apply_command(bridge: Any, action: str, params: Dict[str, Any]) -> Dict[str, Any]:
    """执行一条指令，返回 ``{ok, action, reason?, ...}``。

    * ``ok=True``：指令已生效，附加字段为生效后的值；
    * ``ok=False``：指令被引擎**拒绝**（例如固定输入模型不允许改 imgsz），
      ``reason`` 给出可读原因。这类情况不抛异常，因为它是合法的业务结果；
    * 参数非法/未知指令则抛 :class:`CommandError`。
    """
    params = dict(params or {})
    if not action:
        raise CommandError("缺少指令名")

    if action == protocol.CMD_SET_SOURCE:
        index = int(_require(params, "index"))
        if index < 0:
            raise CommandError("摄像头序号必须是非负整数")
        bridge.set_source(index)
        return {"ok": True, "action": action, "source": index}

    if action == protocol.CMD_SET_THRESHOLDS:
        weak_conf = float(_require(params, "weak_conf"))
        edge_strength = float(_require(params, "edge_strength"))
        if not 0.0 < weak_conf <= 1.0:
            raise CommandError("低置信度阈值需在 (0, 1] 之间")
        if not 0.0 < edge_strength <= 255.0:
            raise CommandError("边缘强度阈值需在 (0, 255] 之间")
        bridge.set_thresholds(weak_conf, edge_strength)
        return {
            "ok": True,
            "action": action,
            "weak_conf": round(weak_conf, 3),
            "edge_strength": round(edge_strength, 1),
        }

    if action == protocol.CMD_SET_INFERENCE_SIZE:
        requested = int(_require(params, "size"))
        applied = int(bridge.set_inference_size(requested))
        if applied != requested:
            reason = bridge.last_error() or f"推理图片大小仍为 {applied}"
            return {
                "ok": False,
                "action": action,
                "reason": reason,
                "inference_size": applied,
            }
        return {"ok": True, "action": action, "inference_size": applied}

    if action == protocol.CMD_SET_BEV:
        enabled = bool(params.get("enabled", False))
        bridge.set_bev_enabled(enabled)
        return {"ok": True, "action": action, "bev": enabled}

    if action == protocol.CMD_PING:
        return {"ok": True, "action": action}

    raise CommandError(f"未知指令: {action}")


def parse_action_params(payload: Any) -> Dict[str, Any]:
    """把请求体规整成 ``{action, ...params}``。

    兼容两种写法：``{"action": "...", ...}`` 或 ``{"cmd": "...", ...}``。
    """
    if not isinstance(payload, dict):
        raise CommandError("请求体必须是 JSON 对象")
    action = payload.get("action") or payload.get("cmd") or ""
    params = {key: value for key, value in payload.items() if key not in ("action", "cmd")}
    return {"action": str(action), **params}


def normalize_action(raw: Any) -> str:
    """把各种写法折算成规范的指令名。

    容忍：``/api/set_source``、``api/set-inference-size``、``PING``，以及 Web 端
    使用的短名 ``source`` / ``thresholds`` / ``inference_size`` / ``bev``。
    """
    action = str(raw or "").strip().lower()
    for prefix in ("/api/", "api/"):
        if action.startswith(prefix):
            action = action[len(prefix):]
    action = action.replace("-", "_").strip("/")
    return ACTION_ALIASES.get(action, action)


def known_actions() -> List[str]:
    return list(SUPPORTED_ACTIONS)
