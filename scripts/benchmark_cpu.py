"""Benchmark FastGuard CPU inference from an OpenCV camera source."""

from __future__ import annotations

import argparse
import csv
from collections import deque
from datetime import datetime
import json
import math
import os
from pathlib import Path
import platform
import statistics
import sys
import time
from typing import Any, Deque, Dict, List, Optional

import cv2
import matplotlib
import matplotlib.pyplot as plt
import numpy as np
import torch
import ultralytics
from ultralytics import YOLO


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WEIGHTS = PROJECT_ROOT / "assets" / "weights" / "yolo11n.pt"
TRACKER_CONFIG = PROJECT_ROOT / "bytetrack.yaml"
CSV_FIELDS = (
    "frame_index",
    "elapsed_seconds",
    "capture_ms",
    "preprocess_ms",
    "inference_ms",
    "frame_cycle_ms",
    "instant_fps",
    "rolling_fps",
    "inference_calls",
    "mode",
    "frame_width",
    "frame_height",
)


def non_negative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must not be negative")
    return parsed


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def _physical_core_count() -> int:
    try:
        import psutil

        return psutil.cpu_count(logical=False) or 1
    except Exception:
        logical = os.cpu_count() or 1
        return max(1, logical // 2) if logical >= 8 else logical


def positive_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Measure CPU-only FastGuard inference performance."
    )
    parser.add_argument(
        "--source",
        type=non_negative_int,
        default=0,
        help="OpenCV camera index for OBS Virtual Camera (default: 0).",
    )
    parser.add_argument(
        "--weights",
        type=Path,
        default=DEFAULT_WEIGHTS,
        help=f"Model weights path (default: {DEFAULT_WEIGHTS}).",
    )
    parser.add_argument(
        "--duration",
        type=positive_float,
        default=60.0,
        help="Measurement duration in seconds, excluding warm-up (default: 60).",
    )
    parser.add_argument(
        "--warmup-frames",
        type=int,
        default=20,
        help="Frames used to warm up the model before measurement (default: 20).",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="cpu",
        help="Inference device for Ultralytics: 'cpu', '0', 'cuda', 'cuda:0' (default: cpu).",
    )
    parser.add_argument(
        "--imgsz",
        type=positive_int,
        default=640,
        help="Inference resolution for YOLO (default: 640).",
    )
    parser.add_argument(
        "--threads",
        type=positive_int,
        default=_physical_core_count(),
        help="CPU worker threads for torch (default: physical core count).",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "benchmark_results",
        help="Directory for the CSV, JSON summary, and plot.",
    )
    args = parser.parse_args()
    if args.warmup_frames < 0:
        parser.error("--warmup-frames must not be negative")
    return args


def _rolling_fps(
    elapsed_seconds: float,
    frame_times: Deque[float],
    window_seconds: float = 1.0,
) -> float:
    frame_times.append(elapsed_seconds)
    while len(frame_times) > 1 and elapsed_seconds - frame_times[0] > window_seconds:
        frame_times.popleft()
    span = frame_times[-1] - frame_times[0]
    if span <= 0:
        return 0.0
    return (len(frame_times) - 1) / span


def _percentile_summary(values: List[float]) -> Dict[str, float]:
    if not values:
        return {}
    return {
        "mean": sum(values) / len(values),
        "median": statistics.median(values),
        "p95": float(np.percentile(values, 95)),
        "min": min(values),
        "max": max(values),
    }


def _configure_plot_fonts() -> None:
    matplotlib.rcParams["font.sans-serif"] = [
        "Microsoft YaHei",
        "SimHei",
        "DejaVu Sans",
    ]
    matplotlib.rcParams["axes.unicode_minus"] = False


def _cpu_name() -> str:
    if sys.platform == "win32":
        try:
            import winreg

            with winreg.OpenKey(
                winreg.HKEY_LOCAL_MACHINE,
                r"HARDWARE\DESCRIPTION\System\CentralProcessor\0",
            ) as key:
                name, _ = winreg.QueryValueEx(key, "ProcessorNameString")
            if name.strip():
                return name.strip()
        except OSError:
            pass
    return (
        os.environ.get("PROCESSOR_IDENTIFIER")
        or platform.processor()
        or platform.machine()
        or "Unknown CPU"
    )


class FastGuardInferenceRunner:
    def __init__(self, model: YOLO, device: str, imgsz: int) -> None:
        self.model = model
        self.device = device
        self.imgsz = imgsz
        self.clahe = None
        self.upper_enhanced = None
        self.lower_enhanced = None
        self.upper_results = None
        self.lower_results = None
        self.stereo_matcher = None

    def _enhance_region(self, region: np.ndarray) -> np.ndarray:
        denoised = cv2.medianBlur(region, 3)
        lab = cv2.cvtColor(denoised, cv2.COLOR_BGR2LAB)
        luminance, channel_a, channel_b = cv2.split(lab)
        if self.clahe is None:
            self.clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        enhanced_luminance = self.clahe.apply(luminance)
        enhanced = cv2.cvtColor(
            cv2.merge((enhanced_luminance, channel_a, channel_b)),
            cv2.COLOR_LAB2BGR,
        )
        gradient_x = cv2.Sobel(enhanced_luminance, cv2.CV_64F, 1, 0, ksize=3)
        gradient_y = cv2.Sobel(enhanced_luminance, cv2.CV_64F, 0, 1, ksize=3)
        cv2.magnitude(gradient_x, gradient_y)
        return enhanced

    def process(
        self, frame: np.ndarray, frame_index: int
    ) -> tuple[float, Optional[float], int, str]:
        height, width = frame.shape[:2]
        upper_end = int(height * 2 / 3)
        lower_start = int(height * 1 / 3)
        preprocessing_start = time.perf_counter()

        if frame_index % 3 == 0 or self.upper_enhanced is None:
            self.upper_enhanced = self._enhance_region(frame[0:upper_end])
        if frame_index % 3 != 2 or self.lower_enhanced is None:
            self.lower_enhanced = self._enhance_region(frame[lower_start:height])
        keep_height = upper_end - lower_start
        enhanced_frame = np.vstack(
            (self.upper_enhanced[0:keep_height], self.lower_enhanced)
        )

        detected_mode = "stereo" if width >= height * 2.4 else "mono"
        inference_mode = detected_mode
        inference_frame = enhanced_frame
        if inference_mode == "stereo":
            half_width = width // 2
            inference_frame = enhanced_frame[:, :half_width]
            if self.stereo_matcher is None:
                self.stereo_matcher = cv2.StereoSGBM_create(
                    minDisparity=0,
                    numDisparities=64,
                    blockSize=5,
                    P1=8 * 3 * 5**2,
                    P2=32 * 3 * 5**2,
                    disp12MaxDiff=1,
                    uniquenessRatio=10,
                    speckleWindowSize=100,
                    speckleRange=32,
                    preFilterCap=63,
                )
            gray_left = cv2.cvtColor(frame[:, :half_width], cv2.COLOR_BGR2GRAY)
            gray_right = cv2.cvtColor(frame[:, half_width:], cv2.COLOR_BGR2GRAY)
            self.stereo_matcher.compute(gray_left, gray_right)

        preprocessing_ms = (time.perf_counter() - preprocessing_start) * 1000
        inference_start = time.perf_counter()
        inference_calls = 0

        if inference_mode == "stereo":
            if frame_index % 2 == 0:
                self.model.track(
                    inference_frame,
                    persist=True,
                    verbose=False,
                    imgsz=self.imgsz,
                    conf=0.10,
                    iou=0.5,
                    tracker=str(TRACKER_CONFIG),
                    device=self.device,
                )
                inference_calls = 1
        else:
            if frame_index % 3 == 0 or self.upper_results is None:
                self.upper_results = self.model.predict(
                    self.upper_enhanced,
                    verbose=False,
                    imgsz=self.imgsz,
                    conf=0.10,
                    iou=0.5,
                    device=self.device,
                )
                inference_calls += 1
            if frame_index % 3 != 2 or self.lower_results is None:
                self.lower_results = self.model.predict(
                    self.lower_enhanced,
                    verbose=False,
                    imgsz=self.imgsz,
                    conf=0.10,
                    iou=0.5,
                    device=self.device,
                )
                inference_calls += 1

        inference_ms = (
            (time.perf_counter() - inference_start) * 1000
            if inference_calls
            else None
        )
        return preprocessing_ms, inference_ms, inference_calls, inference_mode


def _save_plot(
    rows: List[Dict[str, Any]],
    output_path: Path,
    cpu_name: str,
    model_name: str,
    average_fps: float,
) -> None:
    _configure_plot_fonts()
    elapsed = [row["elapsed_seconds"] for row in rows]
    rolling_fps = [row["rolling_fps"] for row in rows]
    frame_cycle_ms = [row["frame_cycle_ms"] for row in rows]
    inference_elapsed = [
        row["elapsed_seconds"] for row in rows if row["inference_ms"] is not None
    ]
    inference_ms = [
        row["inference_ms"] for row in rows if row["inference_ms"] is not None
    ]

    figure, (fps_axis, latency_axis) = plt.subplots(
        2, 1, figsize=(14, 9), sharex=True, constrained_layout=True
    )
    fps_axis.plot(elapsed, rolling_fps, color="#147d64", linewidth=1.2)
    fps_axis.set_title(
        f"FastGuard CPU performance | {cpu_name} | {model_name}\n"
        f"Average processed-frame FPS: {average_fps:.2f}"
    )
    fps_axis.set_ylabel("Rolling FPS (1 s)")
    fps_axis.grid(True, alpha=0.25)

    latency_axis.plot(
        elapsed,
        frame_cycle_ms,
        color="#7b8a8b",
        linewidth=0.8,
        alpha=0.75,
        label="Frame cycle (capture + preprocessing + inference)",
    )
    if inference_ms:
        latency_axis.scatter(
            inference_elapsed,
            inference_ms,
            color="#d35400",
            s=10,
            alpha=0.7,
            label="YOLO inference (per-frame total)",
        )
    latency_axis.set_xlabel("Elapsed time (s)")
    latency_axis.set_ylabel("Latency (ms)")
    latency_axis.grid(True, alpha=0.25)
    latency_axis.legend(loc="upper right")
    figure.savefig(output_path, dpi=160)
    plt.close(figure)


def run_benchmark(args: argparse.Namespace) -> Dict[str, Any]:
    weights = args.weights.expanduser().resolve()
    if not (weights.is_file() or weights.is_dir()):
        raise FileNotFoundError(
            f"Model weights not found: {weights}. "
            "Place yolo11n.pt in assets/weights or pass --weights "
            "(accepts a .pt file or an OpenVINO model directory)."
        )
    if not TRACKER_CONFIG.is_file():
        raise FileNotFoundError(f"ByteTrack config not found: {TRACKER_CONFIG}")

    backend = cv2.CAP_DSHOW if sys.platform == "win32" else cv2.CAP_ANY
    capture = cv2.VideoCapture(args.source, backend)
    if not capture.isOpened():
        capture.release()
        raise RuntimeError(
            f"Could not open camera index {args.source}. "
            "Start OBS Virtual Camera and check the --source index."
        )

    try:
        torch.set_num_threads(args.threads)
        model = YOLO(str(weights))
        runner = FastGuardInferenceRunner(model, args.device, args.imgsz)
        print(f"Model: {weights}")
        print(f"Device: {args.device}")
        print(f"imgsz: {args.imgsz}")
        print(f"torch threads: {args.threads}")
        print(f"Warm-up: {args.warmup_frames} frames")

        for warmup_index in range(args.warmup_frames):
            ok, frame = capture.read()
            if not ok:
                raise RuntimeError(
                    "Camera stopped returning frames during warm-up. "
                    "Check OBS Virtual Camera."
                )
            runner.process(frame, warmup_index)

        print(f"Measurement started: {args.duration:g}s.")
        rows: List[Dict[str, Any]] = []
        preprocessing_latencies: List[float] = []
        inference_latencies: List[float] = []
        frame_times: Deque[float] = deque()
        start_time = time.perf_counter()
        frame_index = args.warmup_frames
        frame_width = 0
        frame_height = 0

        while time.perf_counter() - start_time < args.duration:
            cycle_start = time.perf_counter()
            ok, frame = capture.read()
            capture_done = time.perf_counter()
            if not ok:
                raise RuntimeError(
                    "Camera stopped returning frames during measurement. "
                    "Check OBS Virtual Camera."
                )

            frame_height, frame_width = frame.shape[:2]
            preprocess_ms, inference_ms, inference_calls, inference_mode = (
                runner.process(frame, frame_index)
            )
            preprocessing_latencies.append(preprocess_ms)
            if inference_ms is not None:
                inference_latencies.append(inference_ms)

            cycle_done = time.perf_counter()
            elapsed_seconds = cycle_done - start_time
            frame_cycle_ms = (cycle_done - cycle_start) * 1000
            row: Dict[str, Any] = {
                "frame_index": frame_index,
                "elapsed_seconds": elapsed_seconds,
                "capture_ms": (capture_done - cycle_start) * 1000,
                "preprocess_ms": preprocess_ms,
                "inference_ms": inference_ms,
                "frame_cycle_ms": frame_cycle_ms,
                "instant_fps": 1000 / frame_cycle_ms if frame_cycle_ms else 0.0,
                "rolling_fps": _rolling_fps(elapsed_seconds, frame_times),
                "inference_calls": inference_calls,
                "mode": inference_mode,
                "frame_width": frame_width,
                "frame_height": frame_height,
            }
            rows.append(row)
            frame_index += 1

    finally:
        capture.release()

    if not rows:
        raise RuntimeError("No frames were measured; no benchmark report was created.")
    if not inference_latencies:
        raise RuntimeError(
            "No model inference calls were measured. Increase --duration and retry."
        )

    elapsed_seconds = rows[-1]["elapsed_seconds"]
    frame_cycles = [row["frame_cycle_ms"] for row in rows]
    average_fps = len(rows) / elapsed_seconds
    inference_count = sum(row["inference_calls"] for row in rows)
    modes_observed = sorted({row["mode"] for row in rows})
    cpu_name = _cpu_name()
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = args.output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    stem = f"fastguard_cpu_benchmark_{timestamp}"
    csv_path = output_dir / f"{stem}.csv"
    summary_path = output_dir / f"{stem}.json"
    plot_path = output_dir / f"{stem}.png"

    with csv_path.open("w", newline="", encoding="utf-8-sig") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    summary = {
        "timestamp": datetime.now().astimezone().isoformat(timespec="seconds"),
        "cpu": cpu_name,
        "device": args.device,
        "imgsz": args.imgsz,
        "threads": args.threads,
        "python_version": platform.python_version(),
        "torch_version": torch.__version__,
        "ultralytics_version": ultralytics.__version__,
        "opencv_version": cv2.__version__,
        "model": str(weights),
        "camera_index": args.source,
        "frame_size": [frame_width, frame_height],
        "inference_modes_observed": modes_observed,
        "requested_duration_seconds": args.duration,
        "measured_duration_seconds": elapsed_seconds,
        "warmup_frames": args.warmup_frames,
        "frames_processed": len(rows),
        "inference_calls": inference_count,
        "processed_frame_fps": average_fps,
        "inference_calls_per_second": inference_count / elapsed_seconds,
        "preprocessing_latency_ms": _percentile_summary(preprocessing_latencies),
        "frame_cycle_latency_ms": _percentile_summary(frame_cycles),
        "inference_latency_ms": _percentile_summary(inference_latencies),
        "artifacts": {
            "csv": str(csv_path),
            "summary": str(summary_path),
            "plot": str(plot_path),
        },
    }
    with summary_path.open("w", encoding="utf-8") as summary_file:
        json.dump(summary, summary_file, ensure_ascii=False, indent=2)

    _save_plot(rows, plot_path, cpu_name, weights.name, average_fps)

    print(f"CPU: {cpu_name}")
    print(f"Processed frames: {len(rows)} in {elapsed_seconds:.2f}s")
    print(f"Average processed-frame FPS: {average_fps:.2f}")
    print(f"Inference calls/s: {inference_count / elapsed_seconds:.2f}")
    if inference_latencies:
        print(
            f"Mean per-frame inference latency: "
            f"{sum(inference_latencies) / len(inference_latencies):.2f} ms"
        )
    print(f"Frame latency p95: {np.percentile(frame_cycles, 95):.2f} ms")
    print(f"Results: {output_dir}")
    return summary


def main() -> int:
    args = parse_args()
    run_benchmark(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
