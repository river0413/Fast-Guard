"""推理服务端：把既有的 ``core.video_thread.VideoThread`` 包装为可远程控制的引擎。

**推理架构保持不变**：本模块只负责
1. 创建 / 停止既有的 ``VideoThread``（视频读取、预处理、YOLO 推理、风险分析全部沿用原实现）；
2. 订阅它已经存在的 Qt 信号，产出精简的状态快照与图像；
3. 暴露移动端需要的少量运行时开关（摄像头序号、阈值、推理图片大小、BEV 开关）。

``VideoThread`` 的 ``frame_signal`` 会给出四路画面
``(原始, 预处理, 推理, BEV)``；移动端按设计要求**省略预处理画面**，
因此这里直接丢弃第二个参数，绝不把它转发出去。
"""

from __future__ import annotations

import os
import threading
import time
from typing import Any, Callable, Dict, Optional

# 导入顺序很重要：先加载推理引擎（内部会先 import ultralytics / torch），
# 再导入 PyQt5。与桌面端 main.py 的顺序一致 —— PyQt5 若先于 torch 加载，
# 部分环境下 torch 的 c10.dll 会初始化失败（WinError 1114）。
from core.video_thread import VideoThread

from PyQt5 import QtCore  # noqa: E402

from mobile.backend.model_info import detect_fixed_inference_size, validate_inference_size

#: 默认权重（与桌面端 main.py 使用的相对路径一致）。
DEFAULT_MODEL_PATH = os.path.join("assets", "weights", "yolo11n.pt")

#: 引擎状态取值。
STATE_IDLE = "idle"
STATE_SCANNING = "scanning"
STATE_RUNNING = "running"
STATE_STOPPED = "stopped"

#: 超过该秒数仍无新帧，则认为推理服务卡住 / 视频源不可用。
STALL_TIMEOUT_SECONDS = 6.0


def normalize_source(value: Any) -> Any:
    """把视频源规整为摄像头序号（int）或视频文件路径（str）。"""
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    text = str(value).strip()
    return int(text) if text.lstrip("-").isdigit() else text


def make_thread(source: int, model_path: str, weak_conf: float, edge_strength: float, inference_size: int):
    """默认的引擎工厂（测试中可替换为轻量假引擎）。"""
    return GuardedVideoThread(
        source,
        model_path,
        weak_conf_threshold=weak_conf,
        edge_strength_threshold=edge_strength,
        inference_size=inference_size,
    )


class GuardedVideoThread(VideoThread):
    """引擎异常哨兵。

    PyQt5 中线程 ``run()`` 抛出的未捕获异常会直接中止整个进程；这里把它转成
    信号上报，保证推理服务本身不会因为一次推理异常而消失。
    仅用于移动端推理服务，桌面端 `main.py` 中的同名实现不受影响。
    """

    engine_failed = QtCore.pyqtSignal(str)

    def run(self) -> None:  # noqa: D102 - QThread 入口
        try:
            super().run()
        except Exception as exc:  # pragma: no cover - 依赖具体推理异常
            self.engine_failed.emit(f"{type(exc).__name__}: {exc}")


class EngineBridge:
    """持有推理引擎，并提供线程安全的状态快照与控制入口。"""

    def __init__(
        self,
        model_path: str = DEFAULT_MODEL_PATH,
        source: int = 0,
        weak_conf: float = 0.38,
        edge_strength: float = 28.0,
        inference_size: int = 320,
        thread_factory: Optional[Callable[..., Any]] = None,
        on_frame: Optional[Callable[[Any, Optional[Any], Dict[str, Any]], None]] = None,
        on_status: Optional[Callable[[Dict[str, Any]], None]] = None,
    ) -> None:
        self.model_path = model_path
        self.source = normalize_source(source)
        self.weak_conf = float(weak_conf)
        self.edge_strength = float(edge_strength)
        # 固定输入模型（如 Ultralytics INT8/OpenVINO 导出）不能改 imgsz：
        # 强行修改会中断推理，因此启动时就对齐到模型的原生尺寸。
        self.fixed_inference_size = detect_fixed_inference_size(model_path)
        requested_size = int(inference_size)
        if self.fixed_inference_size is not None and requested_size != self.fixed_inference_size:
            self.inference_size = self.fixed_inference_size
            size_notice = (
                f"当前权重使用固定输入的 INT8 模型（{self.fixed_inference_size}），"
                f"已忽略启动参数 {requested_size}"
            )
        else:
            self.inference_size = requested_size
            size_notice = None
        self._thread_factory = thread_factory or make_thread
        self._on_frame = on_frame
        self._on_status = on_status

        self._lock = threading.RLock()
        self._thread = None
        self._bev_enabled = False
        self._frame_count = 0
        self._last_frame_ts = 0.0
        self._started_at = 0.0
        self._state = STATE_IDLE
        self._control_revision = 0
        self._status: Dict[str, Any] = {
            "model": os.path.basename(model_path),
            "perspective": "",
            "risk": "",
            "ttc": None,
            "tracked": 0,
            "latency_ms": None,
            "message": "",
            "error": size_notice,
            "fixed_inference_size": self.fixed_inference_size,
        }

    # ------------------------------------------------------------------ 生命周期
    def start(self) -> None:
        """创建并启动推理引擎（沿用既有 ``VideoThread``）。"""
        with self._lock:
            if self._thread is not None:
                return
            self._state = STATE_SCANNING
            self._started_at = time.time()
            self._last_frame_ts = 0.0
            thread = self._thread_factory(
                self.source, self.model_path, self.weak_conf, self.edge_strength, self.inference_size
            )
            thread.frame_signal.connect(self._handle_frames, QtCore.Qt.DirectConnection)
            thread.status_signal.connect(self._handle_message, QtCore.Qt.DirectConnection)
            thread.model_signal.connect(self._handle_model, QtCore.Qt.DirectConnection)
            thread.latency_signal.connect(self._handle_latency, QtCore.Qt.DirectConnection)
            thread.perspective_signal.connect(self._handle_perspective, QtCore.Qt.DirectConnection)
            thread.hud_signal.connect(self._handle_hud, QtCore.Qt.DirectConnection)
            thread.ttc_signal.connect(self._handle_ttc, QtCore.Qt.DirectConnection)
            thread.side_warning_signal.connect(self._handle_side_warning, QtCore.Qt.DirectConnection)
            thread.finished.connect(self._handle_finished, QtCore.Qt.DirectConnection)
            failure_signal = getattr(thread, "engine_failed", None)
            if failure_signal is not None:
                failure_signal.connect(self._handle_engine_failure, QtCore.Qt.DirectConnection)
            self._thread = thread
            thread.start()
        self._notify_status()

    def stop(self) -> None:
        with self._lock:
            thread = self._thread
            self._thread = None
            self._state = STATE_STOPPED
        if thread is not None:
            try:
                thread.stop()
            except Exception:  # pragma: no cover - 引擎退出异常不应影响服务进程
                pass
        self._notify_status()

    def restart_thread(self, source: Optional[Any] = None) -> None:
        """按当前参数重建引擎（切换摄像头需要重新打开视频源）。"""
        with self._lock:
            if source is not None:
                self.source = normalize_source(source)
            self._control_revision += 1
        self.stop()
        self.start()

    def is_running(self) -> bool:
        with self._lock:
            return self._thread is not None

    # ------------------------------------------------------------------ 运行时控制
    def set_source(self, index: int) -> Any:
        """切换摄像头 / 视频源序号（重建引擎）。"""
        self.restart_thread(source=index)
        return self.source

    def set_thresholds(self, weak_conf: float, edge_strength: float) -> None:
        """下发低置信度阈值与边缘强度阈值（既有引擎 API）。"""
        with self._lock:
            self.weak_conf = float(weak_conf)
            self.edge_strength = float(edge_strength)
            thread = self._thread
        if thread is not None:
            thread.set_preprocess_thresholds(self.weak_conf, self.edge_strength)
        self._notify_status()

    def set_inference_size(self, size: int) -> int:
        """调整推理图片大小（下一帧推理生效），返回**实际生效**的尺寸。

        固定输入模型（INT8/OpenVINO 导出）只接受其原生尺寸：此时不会打断正在
        运行的推理，而是返回当前尺寸并通过 :meth:`last_error` 给出原因。
        """
        accepted, applied, reason = validate_inference_size(size, self.fixed_inference_size)
        if not accepted:
            with self._lock:
                self._status["error"] = reason
            self._notify_status()
            return self.inference_size

        with self._lock:
            thread = self._thread
        if thread is not None:
            self.inference_size = int(thread.set_inference_size(applied))
        else:
            self.inference_size = applied
            # 引擎已停止（例如上一轮推理异常）：按新参数重新启动，让设置真正生效。
            self.start()
        with self._lock:
            self._status["error"] = None
        self._notify_status()
        return self.inference_size

    def last_error(self) -> Optional[str]:
        with self._lock:
            return self._status.get("error")

    def set_bev_enabled(self, enabled: bool) -> bool:
        with self._lock:
            self._bev_enabled = bool(enabled)
        self._notify_status()
        return self._bev_enabled

    def is_bev_enabled(self) -> bool:
        with self._lock:
            return self._bev_enabled

    # ------------------------------------------------------------------ 状态
    def snapshot(self) -> Dict[str, Any]:
        with self._lock:
            now = time.time()
            last = self._last_frame_ts
            started = self._started_at
            state = self._state
            age = (now - last) if last else None
            if state == STATE_RUNNING and age is not None and age > STALL_TIMEOUT_SECONDS:
                state = STATE_SCANNING
            data = dict(self._status)
            if not data.get("error"):
                if age is None and started and (now - started) > STALL_TIMEOUT_SECONDS:
                    data["error"] = "视频源未就绪，请检查摄像头序号是否可用"
                elif age is not None and age > STALL_TIMEOUT_SECONDS and self._thread is not None:
                    data["error"] = "推理服务长时间无新帧，视频源可能已中断"
            data.update(
                {
                    "engine": "VideoThread",
                    "state": state,
                    "running": self._thread is not None,
                    "source": self.source,
                    "weak_conf": round(self.weak_conf, 3),
                    "edge_strength": round(self.edge_strength, 1),
                    "inference_size": self.inference_size,
                    "fixed_inference_size": self.fixed_inference_size,
                    "bev": self._bev_enabled,
                    "frame_count": self._frame_count,
                    "last_frame_age": round(age, 2) if age is not None else None,
                    "uptime": round(now - started, 1) if started else 0.0,
                }
            )
            return data

    def _notify_status(self) -> None:
        if self._on_status is not None:
            try:
                self._on_status(self.snapshot())
            except Exception:  # pragma: no cover - 状态回调不应中断引擎
                pass

    # ------------------------------------------------------------------ 引擎信号
    def _handle_frames(self, original, preprocessed, inference, bev) -> None:
        # ``preprocessed``（预处理画面）按设计要求丢弃，不向移动端转发。
        with self._lock:
            self._frame_count += 1
            self._last_frame_ts = time.time()
            self._state = STATE_RUNNING
            self._status["error"] = None
            want_bev = self._bev_enabled
        if self._on_frame is not None:
            self._on_frame(inference, bev if want_bev else None, self.snapshot())

    def _handle_message(self, message: str) -> None:
        with self._lock:
            self._status["message"] = str(message)
        self._notify_status()

    def _handle_model(self, name: str) -> None:
        with self._lock:
            self._status["model"] = str(name)
        self._notify_status()

    def _handle_latency(self, milliseconds: float) -> None:
        with self._lock:
            self._status["latency_ms"] = round(float(milliseconds), 1)

    def _handle_perspective(self, perspective: str) -> None:
        with self._lock:
            self._status["perspective"] = str(perspective)
        self._notify_status()

    def _handle_hud(self, payload: Dict[str, Any]) -> None:
        # 说明：既有 hud 里的 fps 字段不再向上层暴露（移动端省略帧率显示）。
        with self._lock:
            self._status["tracked"] = int(payload.get("tracked", 0) or 0)
            self._status["mode"] = str(payload.get("mode", ""))

    def _handle_ttc(self, ttc: float, track_id: int) -> None:
        with self._lock:
            self._status["ttc"] = round(float(ttc), 2) if ttc and ttc < 99.0 else None
            self._status["risk"] = "危险" if (ttc and ttc < 1.5) else ("注意" if (ttc and ttc < 3.0) else "安全")

    def _handle_side_warning(self, text: str, side: str, level: int) -> None:
        with self._lock:
            if level and int(level) > 0:
                self._status["side_warning"] = f"{side}:{text}"
            else:
                self._status.pop("side_warning", None)

    def _handle_engine_failure(self, message: str) -> None:
        """引擎线程内发生未捕获异常：只上报状态，不让服务进程跟着挂掉。"""
        with self._lock:
            self._status["error"] = f"推理引擎异常：{message}"
        self._notify_status()

    def _handle_finished(self) -> None:
        with self._lock:
            produced_frames = self._last_frame_ts > 0.0
            self._thread = None
            if self._state != STATE_STOPPED:
                self._state = STATE_IDLE
                if not produced_frames:
                    self._status["error"] = "无法打开视频源，请检查摄像头序号是否可用"
        self._notify_status()
