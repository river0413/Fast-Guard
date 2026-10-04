"""Validate FastGuard detection accuracy and speed across precisions."""

from __future__ import annotations

import argparse
import csv
import json
import platform
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List

import matplotlib
import matplotlib.pyplot as plt
import numpy as np
import torch
import ultralytics
from ultralytics import YOLO


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DATA = "coco128.yaml"
DEFAULT_MODELS = (
    ("fp32", PROJECT_ROOT / "assets" / "weights" / "yolo11n.pt"),
    (
        "int8",
        PROJECT_ROOT / "assets" / "weights" / "yolo11n_int8_openvino_model",
    ),
)
CSV_FIELDS = (
    "model_label",
    "model_path",
    "imgsz",
    "map50",
    "map50_95",
    "precision",
    "recall",
    "inference_ms",
    "preprocess_ms",
    "postprocess_ms",
)


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def parse_imgsz_list(value: str) -> List[int]:
    sizes = []
    for token in value.split(","):
        token = token.strip()
        if not token:
            continue
        parsed = int(token)
        if parsed <= 0:
            raise argparse.ArgumentTypeError("imgsz values must be greater than zero")
        sizes.append(parsed)
    if not sizes:
        raise argparse.ArgumentTypeError("at least one imgsz value is required")
    return sizes


def parse_model_list(value: str) -> List[tuple[str, Path]]:
    models = []
    for token in value.split(","):
        token = token.strip()
        if not token:
            continue
        if "=" not in token:
            raise argparse.ArgumentTypeError(
                "models must use LABEL=PATH, for example fp32=assets/weights/yolo11n.pt"
            )
        label, path = token.split("=", 1)
        models.append((label.strip(), Path(path.strip())))
    if not models:
        raise argparse.ArgumentTypeError("at least one model is required")
    return models


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate FP32 vs INT8 accuracy and speed on a labeled dataset."
    )
    parser.add_argument(
        "--data",
        default=DEFAULT_DATA,
        help=f"Dataset YAML for validation (default: {DEFAULT_DATA}).",
    )
    parser.add_argument(
        "--imgsz",
        type=parse_imgsz_list,
        default=[320, 640],
        help="Comma-separated inference sizes to evaluate (default: 320,640).",
    )
    parser.add_argument(
        "--models",
        type=parse_model_list,
        default=list(DEFAULT_MODELS),
        help="Comma-separated LABEL=PATH model list (default: fp32 + int8).",
    )
    parser.add_argument(
        "--device",
        default="cpu",
        help="Inference device: 'cpu', '0', 'cuda' (default: cpu).",
    )
    parser.add_argument(
        "--threads",
        type=positive_int,
        default=0,
        help="torch CPU threads; 0 keeps the default physical core count.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "benchmark_results",
        help="Directory for the CSV, JSON summary, and plot.",
    )
    return parser.parse_args()


def _physical_core_count() -> int:
    try:
        import psutil

        return psutil.cpu_count(logical=False) or 1
    except Exception:
        logical = torch.get_num_threads()
        return max(1, logical // 2) if logical >= 8 else logical


def _configure_plot_fonts() -> None:
    matplotlib.rcParams["font.sans-serif"] = [
        "Microsoft YaHei",
        "SimHei",
        "DejaVu Sans",
    ]
    matplotlib.rcParams["axes.unicode_minus"] = False


def _cpu_name() -> str:
    if platform.system() == "Windows":
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
    return platform.processor() or platform.machine() or "Unknown CPU"


def _scalar(value: Any) -> float:
    if value is None:
        return float("nan")
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(np.asarray(value).reshape(-1)[0])
    except Exception:
        return float("nan")


def _family(label: str) -> str:
    """Group per-size model labels (int8_320, int8_640) into one curve family."""
    if label.startswith("int8"):
        return "int8"
    return label


def _save_plot(rows: List[Dict[str, Any]], output_path: Path) -> None:
    _configure_plot_fonts()
    families = sorted({_family(row["model_label"]) for row in rows})
    palette = ["#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e"]
    colors = {family: palette[i % len(palette)] for i, family in enumerate(families)}
    figure, (map_axis, speed_axis, pareto_axis) = plt.subplots(
        1, 3, figsize=(19, 6), constrained_layout=True
    )

    for family in families:
        series = sorted(
            (row for row in rows if _family(row["model_label"]) == family),
            key=lambda row: row["imgsz"],
        )
        sizes = [row["imgsz"] for row in series]
        color = colors[family]
        map_axis.plot(
            sizes,
            [row["map50_95"] for row in series],
            marker="o",
            linewidth=1.6,
            color=color,
            label=f"{family} mAP50-95",
        )
        map_axis.plot(
            sizes,
            [row["map50"] for row in series],
            marker="s",
            linestyle="--",
            linewidth=1.2,
            alpha=0.7,
            color=color,
            label=f"{family} mAP50",
        )
        speed_axis.plot(
            sizes,
            [row["inference_ms"] for row in series],
            marker="o",
            linewidth=1.6,
            color=color,
            label=family,
        )
        pareto_axis.scatter(
            [row["inference_ms"] for row in series],
            [row["map50_95"] for row in series],
            s=70,
            color=color,
            label=family,
        )
        for row in series:
            pareto_axis.annotate(
                f"{row['imgsz']}",
                (row["inference_ms"], row["map50_95"]),
                textcoords="offset points",
                xytext=(6, 4),
                fontsize=9,
            )

    map_axis.set_xlabel("imgsz")
    map_axis.set_ylabel("mAP")
    map_axis.set_title("Detection accuracy vs inference size")
    map_axis.grid(True, alpha=0.25)
    map_axis.legend(fontsize=9)

    speed_axis.set_xlabel("imgsz")
    speed_axis.set_ylabel("Inference latency (ms/image)")
    speed_axis.set_title("Inference speed vs size")
    speed_axis.grid(True, alpha=0.25)
    speed_axis.legend(fontsize=9)

    pareto_axis.set_xlabel("Inference latency (ms/image)")
    pareto_axis.set_ylabel("mAP50-95")
    pareto_axis.set_title("Accuracy vs speed trade-off")
    pareto_axis.grid(True, alpha=0.25)
    pareto_axis.legend(fontsize=9)

    figure.savefig(output_path, dpi=160)
    plt.close(figure)


def run_validation(args: argparse.Namespace) -> Dict[str, Any]:
    torch.set_num_threads(args.threads)
    rows: List[Dict[str, Any]] = []

    for label, model_path in args.models:
        model_path = model_path.expanduser().resolve()
        if not (model_path.is_file() or model_path.is_dir()):
            raise FileNotFoundError(f"Model not found: {model_path}")
        print(f"Loading {label}: {model_path}")
        model = YOLO(str(model_path), task="detect")
        for imgsz in args.imgsz:
            print(f"  validating {label} @ imgsz={imgsz} ...")
            try:
                metrics = model.val(
                    data=args.data,
                    imgsz=imgsz,
                    conf=0.001,
                    iou=0.5,
                    device=args.device,
                    verbose=False,
                    plots=False,
                )
            except RuntimeError as exc:
                if "input tensor size" in str(exc) or "get_shape" in str(exc):
                    print(
                        f"    SKIP {label} @ imgsz={imgsz}: exported model has a "
                        f"fixed input size ({exc}). Re-export with --imgsz {imgsz}."
                    )
                    continue
                raise
            box = metrics.box
            speed = metrics.speed or {}
            row = {
                "model_label": label,
                "model_path": str(model_path),
                "imgsz": imgsz,
                "map50": _scalar(getattr(box, "map50", None)),
                "map50_95": _scalar(getattr(box, "map", None)),
                "precision": _scalar(getattr(box, "mp", None)),
                "recall": _scalar(getattr(box, "mr", None)),
                "inference_ms": _scalar(speed.get("inference")),
                "preprocess_ms": _scalar(speed.get("preprocess")),
                "postprocess_ms": _scalar(speed.get("postprocess")),
            }
            print(
                f"    mAP50-95={row['map50_95']:.4f} mAP50={row['map50']:.4f} "
                f"P={row['precision']:.4f} R={row['recall']:.4f} "
                f"inference={row['inference_ms']:.2f}ms"
            )
            rows.append(row)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = args.output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    stem = f"fastguard_quantization_validation_{timestamp}"
    csv_path = output_dir / f"{stem}.csv"
    summary_path = output_dir / f"{stem}.json"
    plot_path = output_dir / f"{stem}.png"

    with csv_path.open("w", newline="", encoding="utf-8-sig") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    deltas: Dict[str, Any] = {}
    by_size: Dict[int, Dict[str, Any]] = {}
    for row in rows:
        by_size.setdefault(row["imgsz"], {})[_family(row["model_label"])] = row
    for imgsz, entries in sorted(by_size.items()):
        baseline = entries.get("fp32")
        quantized = entries.get("int8")
        if not baseline or not quantized:
            continue
        map_drop = baseline["map50_95"] - quantized["map50_95"]
        speedup = (
            baseline["inference_ms"] / quantized["inference_ms"]
            if quantized["inference_ms"]
            else float("nan")
        )
        deltas[str(imgsz)] = {
            "map50_95_drop": map_drop,
            "map50_95_drop_percent": (
                map_drop / baseline["map50_95"] * 100
                if baseline["map50_95"]
                else None
            ),
            "fp32_map50_95": baseline["map50_95"],
            "int8_map50_95": quantized["map50_95"],
            "fp32_inference_ms": baseline["inference_ms"],
            "int8_inference_ms": quantized["inference_ms"],
            "inference_speedup": speedup,
        }

    summary = {
        "timestamp": datetime.now().astimezone().isoformat(timespec="seconds"),
        "cpu": _cpu_name(),
        "device": args.device,
        "threads": args.threads,
        "data": args.data,
        "python_version": platform.python_version(),
        "torch_version": torch.__version__,
        "ultralytics_version": ultralytics.__version__,
        "measured_models": [
            {"label": label, "path": str(path)} for label, path in args.models
        ],
        "results": rows,
        "int8_vs_fp32": deltas,
        "artifacts": {
            "csv": str(csv_path),
            "summary": str(summary_path),
            "plot": str(plot_path),
        },
    }
    with summary_path.open("w", encoding="utf-8") as summary_file:
        json.dump(summary, summary_file, ensure_ascii=False, indent=2)

    _save_plot(rows, plot_path)

    print(f"CPU: {_cpu_name()}")
    print(f"Results: {output_dir}")
    for imgsz, delta in deltas.items():
        print(
            f"  imgsz={imgsz}: mAP50-95 drop {delta['map50_95_drop']:.4f} "
            f"({delta['map50_95_drop_percent']:.2f}%), "
            f"inference speedup {delta['inference_speedup']:.2f}x"
        )
    return summary


def main() -> int:
    args = parse_args()
    if args.threads <= 0:
        args.threads = _physical_core_count()
    run_validation(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
