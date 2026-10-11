"""移动端本地配置：摄像头、阈值、推理图片大小等，持久化到 JSON 文件。"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from typing import Any, Dict, Optional

from mobile import protocol

#: 默认配置文件位置（已在 .gitignore 中忽略）。
DEFAULT_SETTINGS_FILE = Path(__file__).resolve().parent.parent / "mobile_settings.json"

#: 可通过环境变量覆盖，便于测试与多套配置切换。
SETTINGS_ENV_VAR = "FASTGUARD_MOBILE_SETTINGS"

WEAK_CONF_RANGE = (0.10, 0.95)
EDGE_STRENGTH_RANGE = (1.0, 255.0)


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def _coerce_inference_size(value: Any) -> int:
    """把任意输入规整到最接近的合法推理尺寸。"""
    try:
        size = int(value)
    except (TypeError, ValueError):
        return protocol.DEFAULT_INFERENCE_SIZE
    if size in protocol.INFERENCE_SIZE_CHOICES:
        return size
    return min(protocol.INFERENCE_SIZE_CHOICES, key=lambda candidate: abs(candidate - size))


@dataclass
class MobileSettings:
    """移动端可调参数（与桌面端参数设置窗口保持一致的两项阈值 + 推理图片大小）。"""

    host: str = protocol.DEFAULT_HOST
    port: int = protocol.DEFAULT_PORT
    camera_index: int = 0
    weak_conf: float = 0.38
    edge_strength: float = 28.0
    inference_size: int = protocol.DEFAULT_INFERENCE_SIZE
    show_bev: bool = False
    autostart_backend: bool = True

    # ------------------------------------------------------------------ 校验
    def normalize(self) -> "MobileSettings":
        self.host = str(self.host).strip() or protocol.DEFAULT_HOST
        try:
            self.port = int(_clamp(int(self.port), 1, 65535))
        except (TypeError, ValueError):
            self.port = protocol.DEFAULT_PORT
        try:
            self.camera_index = int(self.camera_index)
        except (TypeError, ValueError):
            self.camera_index = 0
        if self.camera_index < 0:
            self.camera_index = 0
        self.weak_conf = round(_clamp(float(self.weak_conf), *WEAK_CONF_RANGE), 2)
        self.edge_strength = round(_clamp(float(self.edge_strength), *EDGE_STRENGTH_RANGE), 1)
        self.inference_size = _coerce_inference_size(self.inference_size)
        self.show_bev = bool(self.show_bev)
        self.autostart_backend = bool(self.autostart_backend)
        return self

    # ------------------------------------------------------------------ 序列化
    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Optional[Dict[str, Any]]) -> "MobileSettings":
        known = {field.name for field in fields(cls)}
        payload = {key: value for key, value in (data or {}).items() if key in known}
        return cls(**payload).normalize()

    # ------------------------------------------------------------------ 读写
    @classmethod
    def default_path(cls) -> Path:
        override = os.environ.get(SETTINGS_ENV_VAR)
        return Path(override) if override else DEFAULT_SETTINGS_FILE

    @classmethod
    def load(cls, path: Optional[Path] = None) -> "MobileSettings":
        target = Path(path) if path else cls.default_path()
        try:
            with open(target, "r", encoding="utf-8") as handle:
                return cls.from_dict(json.load(handle))
        except (OSError, json.JSONDecodeError, TypeError):
            return cls().normalize()

    def save(self, path: Optional[Path] = None) -> Path:
        target = Path(path) if path else self.default_path()
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(self.to_dict(), handle, ensure_ascii=False, indent=2)
        return target
