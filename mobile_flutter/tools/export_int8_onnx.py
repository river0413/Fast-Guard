"""导出移动端 INT8 ONNX 模型，并做**出门检验**（对比 FP32，不合格就退出码非 0）。

用法（在仓库根目录执行）::

    # 1. 默认：用 assets/calibration/images 的帧做校准，检测头保持 FP32
    python mobile_flutter/tools/export_int8_onnx.py

    # 2. 顺带把 COCO128 也加进校准集（目标更丰富，但需要联网下载一次）
    python mobile_flutter/tools/export_int8_onnx.py --extra-calib coco128

    # 3. 只检验已有模型，不重新量化
    python mobile_flutter/tools/export_int8_onnx.py --validate-only

为什么要"检测头保持 FP32"（本脚本的核心，改动前请先读）：
    检测头输出的是**后处理前的 logits**，取值范围完全取决于画面里有没有目标。
    校准集若以远景小目标为主，得到的激活量程很窄，近处大目标会被截断到量程上限，
    表现是**所有高置信度都变成 0.5**（sigmoid(0)）。实测（Ultralytics 默认导出，
    88/88 个 Conv 全量化）在 bus.jpg 上把 0.846 的公交车、0.811 的行人**全部**变成
    0.500；而本脚本的配方（量化 63/88 个 Conv，检测头整体排除）在留出图像
    zidane.jpg 上与 FP32 一致到小数点后三位。
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import onnx
from onnxruntime.quantization import (
    CalibrationDataReader,
    CalibrationMethod,
    QuantFormat,
    quantize_static,
)

REPO = Path(__file__).resolve().parents[2]
FP32_ASSET = REPO / "mobile_flutter" / "assets" / "yolo11n.onnx"
INT8_ASSET = REPO / "mobile_flutter" / "assets" / "yolo11n_int8.onnx"
CALIB_IMAGES = REPO / "assets" / "calibration" / "images"

# 期望的模型规格（与 lib/inference/yolo_detector.dart 中的张量名/形状一致）
INPUT_NAME = "images"
OUTPUT_NAME = "output0"

# 出门检验的阈值
MAX_BOX_ERROR_PX = 12.0  # 反 letterbox 前，输入像素尺度
MIN_SCORE_RATIO = 0.80  # INT8 的最高置信度不得低于 FP32 的 80%
COLLAPSE_SCORE = 0.52  # 高于该值却"卡"在这里 = logits 被截断（0.5 = sigmoid(0)）
HIGH_CONF = 0.50  # 该分数以上的检出属于"参与告警的目标"，必须逐一匹配上
MIN_DET_RATIO = 0.80  # INT8 保留的检出数不得低于 FP32 的 80%


# --------------------------------------------------------------------------- 预处理
def letterbox(path: Path, imgsz: int):
    """与 Dart 端 `_preprocess` 等价的 letterbox（RGB、0..1、114/255 填充）。"""
    import cv2

    bgr = cv2.imread(str(path))
    if bgr is None:
        raise FileNotFoundError(path)
    h, w = bgr.shape[:2]
    scale = min(imgsz / w, imgsz / h)
    nw, nh = int(round(w * scale)), int(round(h * scale))
    resized = cv2.resize(bgr, (nw, nh), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((imgsz, imgsz, 3), 114, dtype=np.uint8)
    top, left = (imgsz - nh) // 2, (imgsz - nw) // 2
    canvas[top : top + nh, left : left + nw] = resized
    rgb = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
    return np.ascontiguousarray(np.transpose(rgb, (2, 0, 1)))[None, ...], scale, (left, top)


class _Reader(CalibrationDataReader):
    def __init__(self, files: list[Path], imgsz: int):
        self.samples = [{INPUT_NAME: letterbox(f, imgsz)[0]} for f in files]
        self._iterator = iter(self.samples)

    def get_next(self):
        return next(self._iterator, None)

    def rewind(self):
        self._iterator = iter(self.samples)


# --------------------------------------------------------------------------- 量化
def quantize(source: Path, target: Path, calib: list[Path], imgsz: int, method: CalibrationMethod) -> None:
    graph = onnx.load(str(source)).graph
    # 只量化 backbone/neck 的 Conv；/model.23/ 是检测头，必须保持 FP32（见模块 docstring）
    keep = {
        n.name
        for n in graph.node
        if n.op_type in {"Conv", "Gemm", "MatMul"} and "/model.23/" not in n.name
    }
    exclude = [n.name for n in graph.node if n.name not in keep]
    quantized_convs = sum(1 for n in graph.node if n.name in keep and n.op_type == "Conv")
    total_convs = sum(1 for n in graph.node if n.op_type == "Conv")
    print(f"[quantize] 校准帧 {len(calib)} · 量化 Conv {quantized_convs}/{total_convs} · "
          f"排除 {len(exclude)}/{len(graph.node)} 个节点 · 方法 {method.name}")

    quantize_static(
        str(source),
        str(target),
        _Reader(calib, imgsz),
        quant_format=QuantFormat.QDQ,
        nodes_to_exclude=exclude,
        calibrate_method=method,
    )
    print(f"[quantize] -> {target} ({target.stat().st_size / 1024 / 1024:.2f} MB)")


# --------------------------------------------------------------------------- 检验
def _session(path: Path):
    import onnxruntime as ort

    return ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])


def _decode(y: np.ndarray, scale: float, pad: tuple[float, float], conf: float = 0.20):
    """与 Dart 端同构的解码：置信度过滤 + 逐类 NMS + 反 letterbox。

    必须做 NMS —— 直接比较"分数最高的前 N 个 anchor"没有意义：同一个目标会有多个相邻
    anchor，两个模型的 anchor 排序只要略有差别，"匹配数"就会虚假下降。
    """
    boxes, scores = y[:4, :], y[4:, :]
    best = scores.max(axis=0)
    candidates = []
    for i in np.where(best >= conf)[0]:
        cx, cy, bw, bh = (float(v) for v in boxes[:, i])
        candidates.append((
            int(scores[:, i].argmax()),
            float(best[i]),
            [(cx - bw / 2 - pad[0]) / scale, (cy - bh / 2 - pad[1]) / scale,
             (cx + bw / 2 - pad[0]) / scale, (cy + bh / 2 - pad[1]) / scale],
        ))

    kept: list = []
    for cand in sorted(candidates, key=lambda c: -c[1]):
        if all(cand[0] != k[0] or _iou(cand, k) < 0.45 for k in kept):
            kept.append(cand)
    return kept


def _iou(a, b) -> float:
    x1, y1 = max(a[2][0], b[2][0]), max(a[2][1], b[2][1])
    x2, y2 = min(a[2][2], b[2][2]), min(a[2][3], b[2][3])
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    union = (a[2][2] - a[2][0]) * (a[2][3] - a[2][1]) + (b[2][2] - b[2][0]) * (b[2][3] - b[2][1]) - inter
    return inter / union if union > 0 else 0.0


def validate(images: list[Path], sizes: list[int]) -> tuple[bool, list[dict]]:
    """FP32 vs INT8 一致性检验。

    判据分两类：
    * **硬性**：置信度水平（不得塌陷/明显偏低）、高置信度（≥[HIGH_CONF]）检出必须逐一匹配、
      检出数量不得大幅减少、框误差上限；
    * **记录**：低置信度（画面边缘的残缺目标等）差异只记录不判失败 —— 量化本来就会
      改变这类边缘结果，而它们不参与告警判定。
    """
    if not images:
        print("[validate] 没有可用的检验图片（需要带目标的真实图片）")
        return True, []

    fp, i8 = _session(FP32_ASSET), _session(INT8_ASSET)
    fp_name = fp.get_inputs()[0].name
    i8_name = i8.get_inputs()[0].name
    rows, ok = [], True

    for size in sizes:
        for img in images:
            x, scale, pad = letterbox(img, size)
            y_fp = np.squeeze(fp.run(None, {fp_name: x})[0], axis=0)
            y_i8 = np.squeeze(i8.run(None, {i8_name: x})[0], axis=0)

            d_fp, d_i8 = _decode(y_fp, scale, pad), _decode(y_i8, scale, pad)
            top_fp = max((s for _, s, _ in d_fp), default=0.0)
            top_i8 = max((s for _, s, _ in d_i8), default=0.0)

            errors, matched, unmatched = [], 0, []
            for c, s, b in d_fp:
                best = max(((_iou((c, 0, b), k), k) for k in d_i8 if k[0] == c), default=(0.0, None))
                if best[0] > 0.5:
                    matched += 1
                    errors.extend(abs(u - v) for u, v in zip(b, best[1][2]))
                else:
                    unmatched.append((c, round(s, 3)))

            row = {
                "imgsz": size,
                "image": img.name,
                "fp32_top_score": round(top_fp, 3),
                "int8_top_score": round(top_i8, 3),
                "fp32_dets": len(d_fp),
                "int8_dets": len(d_i8),
                "matched_dets": matched,
                "high_conf_missed": [u for u in unmatched if u[1] >= HIGH_CONF],
                "low_conf_unmatched": [u for u in unmatched if u[1] < HIGH_CONF],
                "mean_box_err_px": round(float(np.mean(errors)), 2) if errors else None,
                "max_box_err_px": round(float(np.max(errors)), 2) if errors else None,
            }
            rows.append(row)

            problems = []
            if top_fp > COLLAPSE_SCORE and top_i8 <= COLLAPSE_SCORE:
                problems.append(
                    f"置信度塌陷（FP32 {top_fp:.3f} -> INT8 {top_i8:.3f}）：logits 被量化截断，"
                    "通常是检测头没有排除或校准集不具代表性"
                )
            if top_fp > 0 and top_i8 < top_fp * MIN_SCORE_RATIO:
                problems.append(f"置信度偏低（{top_i8:.3f} < {top_fp:.3f}×{MIN_SCORE_RATIO}）")
            if row["mean_box_err_px"] is not None and row["mean_box_err_px"] > MAX_BOX_ERROR_PX:
                problems.append(f"框误差过大（{row['mean_box_err_px']}px）")
            if row["high_conf_missed"]:
                problems.append(f"高置信度检出丢失：{row['high_conf_missed']}")
            if d_fp and len(d_i8) < len(d_fp) * MIN_DET_RATIO:
                problems.append(f"检出数量减少（{len(d_fp)} -> {len(d_i8)}）")

            print(f"  [{'OK' if not problems else 'FAIL'}] imgsz={size} {img.name}: "
                  f"top {row['fp32_top_score']} -> {row['int8_top_score']}, "
                  f"dets {len(d_fp)} -> {len(d_i8)}, matched={matched}, "
                  f"box_err={row['mean_box_err_px']}px")
            if row["low_conf_unmatched"]:
                print(f"         (info) 低置信度差异（不判失败）：{row['low_conf_unmatched']}")
            for problem in problems:
                print(f"         - {problem}")
                ok = False

    return ok, rows


# --------------------------------------------------------------------------- main
def main() -> int:
    parser = argparse.ArgumentParser(description="导出并检验移动端 INT8 ONNX 模型")
    parser.add_argument("--imgsz", type=int, default=320, help="量化时使用的输入尺寸（默认 320）")
    parser.add_argument("--method", choices=["minmax", "entropy", "percentile"], default="minmax")
    parser.add_argument("--extra-calib", choices=["none", "coco128"], default="none",
                        help="额外校准数据；coco128 会下载约 7 MB 的小样本集")
    parser.add_argument("--limit-calib", type=int, default=0, help="限制校准帧数（调试用，0 = 全部）")
    parser.add_argument("--validate-only", action="store_true", help="只检验现有 INT8 模型")
    parser.add_argument("--sizes", type=int, nargs="+", default=[320, 416, 640],
                        help="检验用的输入尺寸（同时验证动态输入是否仍可用）")
    args = parser.parse_args()

    if not FP32_ASSET.exists():
        print(f"[error] 缺少 FP32 模型资产：{FP32_ASSET}")
        return 2

    if not args.validate_only:
        calib = sorted(CALIB_IMAGES.glob("*.jpg"))
        if not calib:
            print(f"[error] 校准集为空：{CALIB_IMAGES}（200 帧真实场景图，仓库中已 gitignore）")
            return 2
        if args.extra_calib == "coco128":
            from ultralytics.data.utils import check_det_dataset

            info = check_det_dataset("coco128.yaml")
            calib += sorted(Path(info["train"]).glob("*.jpg"))
            print(f"[calib] 加入 COCO128：{len(calib)} 帧")
        if args.limit_calib:
            calib = calib[: args.limit_calib]
        method = {
            "minmax": CalibrationMethod.MinMax,
            "entropy": CalibrationMethod.Entropy,
            "percentile": CalibrationMethod.Percentile,
        }[args.method]
        quantize(FP32_ASSET, INT8_ASSET, calib, args.imgsz, method)

    # 检验：优先用带目标的真实图片（默认样例图，缺了就跳过）
    checks = [p for p in (
        REPO / "assets" / "calibration" / "samples" / "bus.jpg",
        REPO / "assets" / "calibration" / "samples" / "zidane.jpg",
    ) if p.exists()]
    if not checks:
        print("[validate] 未找到示例图片，跳过一致性检验（建议放入 "
              "assets/calibration/samples/{bus,zidane}.jpg 后再跑）")
    ok, rows = validate(checks, args.sizes)

    report = REPO / "assets" / "calibration" / "int8_validation.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"rows": rows, "passed": ok}, indent=2, ensure_ascii=False),
                      encoding="utf-8")
    print(f"[report] {report}")

    if not ok:
        print("[FAIL] INT8 模型未通过一致性检验，请勿发布（配方见本脚本 docstring）")
        return 1
    print("[ok] INT8 模型通过一致性检验，可以拷到 mobile_flutter/assets/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
