"""权重信息探测（不依赖 Qt 绑定，移动端界面测试也能直接导入）。

Ultralytics 导出的 ``*_int8_openvino_model`` 是**固定输入尺寸**模型
（导出时的 ``imgsz`` 被固化），运行时再修改 ``imgsz`` 会让推理中断。
因此移动端在允许用户调整"推理图片大小"之前，需要知道模型是否固定输入。
"""

from __future__ import annotations

import os
import re
from typing import Any, Optional

#: Ultralytics INT8/OpenVINO 导出目录的后缀。
INT8_MODEL_SUFFIX = "_int8_openvino_model"

#: 读取不到元数据时的兜底尺寸（Ultralytics INT8 导出默认 320）。
FALLBACK_FIXED_SIZE = 320

_IMGSZ_RE = re.compile(r"imgsz:\s*(?:\n\s*-\s*)?\[?\s*(\d+)", re.MULTILINE)


def int8_model_dir(model_path: str) -> Optional[str]:
    """返回与权重同名的 INT8 导出目录（不存在则返回 ``None``）。"""
    if not model_path:
        return None
    candidate = os.path.splitext(str(model_path))[0] + INT8_MODEL_SUFFIX
    return candidate if os.path.isdir(candidate) else None


def _size_from_metadata(metadata_path: str) -> Optional[int]:
    try:
        with open(metadata_path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return None

    try:  # PyYAML 随 ultralytics 一起安装，优先用结构化解析
        import yaml

        data = yaml.safe_load(text) or {}
        value = data.get("imgsz")
        if isinstance(value, (list, tuple)) and value:
            return int(value[0])
        if isinstance(value, int):
            return int(value)
    except Exception:  # pragma: no cover - 缺 yaml 或格式异常时退回正则
        pass

    match = _IMGSZ_RE.search(text)
    if not match:
        return None
    try:
        return int(match.group(1))
    except (TypeError, ValueError):  # pragma: no cover - 防御性
        return None


def detect_fixed_inference_size(model_path: str) -> Optional[int]:
    """若权重使用固定输入模型，返回其输入边长；否则返回 ``None``。

    判定依据：权重旁存在 ``<name>_int8_openvino_model`` 目录即视为固定输入，
    尺寸取自该目录的 ``metadata.yaml``，读不到时回退 ``320``。
    """
    directory = int8_model_dir(model_path)
    if directory is None:
        return None
    size = _size_from_metadata(os.path.join(directory, "metadata.yaml"))
    return size if size else FALLBACK_FIXED_SIZE


def describe_model(model_path: str) -> dict:
    """便于日志/状态展示的模型信息摘要。"""
    directory = int8_model_dir(model_path)
    info: dict = {"path": str(model_path), "int8": directory is not None}
    fixed = detect_fixed_inference_size(model_path)
    info["fixed_inference_size"] = fixed
    info["mutable_inference_size"] = fixed is None
    return info


def coerce_size(requested: Any, fixed_size: Optional[int]) -> int:
    """把期望尺寸规整到实际可用的尺寸：固定输入模型只能使用其原生尺寸。"""
    if fixed_size is not None:
        return int(fixed_size)
    try:
        return int(requested)
    except (TypeError, ValueError):
        return FALLBACK_FIXED_SIZE


def validate_inference_size(requested: Any, fixed_size: Optional[int]) -> tuple:
    """校验一次"推理图片大小"修改请求。

    返回 ``(是否接受, 实际生效尺寸, 拒绝原因或 None)``。固定输入模型（如
    Ultralytics INT8/OpenVINO 导出）只接受其原生尺寸——运行时强行改成别的
    尺寸会直接中断推理，因此这里显式拒绝并给出可操作的原因。
    """
    try:
        size = int(requested)
    except (TypeError, ValueError):
        return False, coerce_size(requested, fixed_size), f"推理图片大小非法：{requested!r}"

    if fixed_size is not None and size != int(fixed_size):
        reason = (
            f"当前 INT8 模型输入固定为 {int(fixed_size)}，无法改为 {size}；"
            f"请选择 {int(fixed_size)}，或改用 FP32 权重（--model yolo11n.pt）"
        )
        return False, int(fixed_size), reason
    return True, size, None
