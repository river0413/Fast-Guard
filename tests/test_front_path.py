"""FastGuard 前向（正面）链路功能回归测试。

覆盖范围：TTC 计算、正面碰撞检测器、正面报警去抖动、IPM 前向投影。
侧向/盲区检测（side_detector、side_alarm、side_ipm、lateral_logic）按需求**不在此测试范围内**。

运行方式：
    pytest tests/test_front_path.py -v
    python tests/test_front_path.py
"""

from __future__ import annotations

import math
import sys
from pathlib import Path
from typing import Any, List, Sequence, Tuple

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from core.calculator import TTCCalculator
from core.front_alarm import FrontAlarm
from core.front_detector import FrontCollisionDetector
from core.ipm import IPM_Transformer

FPS = 30.0
FRAME_W = 640
FRAME_H = 480
WARNING_LINE_Y = 400
SAFE_TTC = 99.0

Frame = Tuple[float, float, float, float, float]  # width, cx, cy, bottom_y, area_ratio


def approach_sequence(
    start: float = 100.0,
    growth: float = 4.0,
    count: int = 20,
    cx: float = 320.0,
    cy: float = 300.0,
    bottom_y: float = 380.0,
    area_ratio: float = 0.05,
) -> List[Frame]:
    """A target inside the safety corridor whose box grows every frame."""
    return [
        (start + growth * i, cx, cy, bottom_y, area_ratio) for i in range(count)
    ]


def static_sequence(count: int = 12, width: float = 120.0) -> List[Frame]:
    return [(width, 320.0, 300.0, 380.0, 0.05) for _ in range(count)]


def _feed_detector(
    detector: FrontCollisionDetector,
    frames: Sequence[Frame],
    track_id: int = 1,
    **kwargs: Any,
) -> Tuple[Any, ...]:
    """Feed all frames as a single continuous track and return the last result."""
    result = None
    for width, cx, cy, bottom_y, area_ratio in frames:
        result = detector.update(
            track_id,
            width,
            cx,
            cy,
            bottom_y,
            FRAME_W,
            FRAME_H,
            WARNING_LINE_Y,
            area_ratio,
            **kwargs,
        )
    assert result is not None, "sequence must not be empty"
    return result


# --------------------------------------------------------------------------- #
# TTC 计算器（core/video_thread.py 前向分支使用）
# --------------------------------------------------------------------------- #


def test_ttc_calculator_static_target_is_safe() -> None:
    calc = TTCCalculator(FPS)
    result = None
    for _ in range(12):
        result = calc.update(
            1, 120.0, 320.0, 300.0, 380.0, FRAME_W, FRAME_H, WARNING_LINE_Y, 0.05
        )
    ttc, _vx, _vy, _dw, red_allowed, _vw, is_static, risk, in_path = result
    assert red_allowed and in_path
    assert is_static, "a motionless box must be classified as static"
    assert risk == 0, "static targets must never raise an alarm"
    assert ttc >= SAFE_TTC - 1e-9


def test_ttc_calculator_approaching_target_warns() -> None:
    calc = TTCCalculator(FPS)
    result = None
    for i in range(20):
        result = calc.update(
            1,
            100.0 + 4.0 * i,
            320.0,
            300.0,
            380.0,
            FRAME_W,
            FRAME_H,
            WARNING_LINE_Y,
            0.05,
        )
    ttc, _vx, _vy, _dw, red_allowed, _vw, is_static, risk, in_path = result
    assert red_allowed and in_path
    assert not is_static
    assert ttc < 2.0, f"closing target should yield a small TTC, got {ttc}"
    assert risk == 1, f"closing target should warn, got risk={risk}"


def test_ttc_calculator_distance_inside_sdt_is_danger() -> None:
    calc = TTCCalculator(FPS)
    result = None
    for i in range(20):
        result = calc.update(
            1,
            100.0 + 4.0 * i,
            320.0,
            300.0,
            380.0,
            FRAME_W,
            FRAME_H,
            WARNING_LINE_Y,
            0.05,
            distance=1.0,
            v_self_mps=0.0,
        )
    assert result[7] == 2, "distance below the dynamic safety distance must be danger"


def test_ttc_calculator_off_path_lateral_target_is_safe() -> None:
    calc = TTCCalculator(FPS)
    result = None
    for i in range(12):
        # Stays to the right of the 0.35–0.65 corridor (x > 416) while moving fast.
        result = calc.update(
            1,
            100.0 + 4.0 * i,
            500.0 + 10.0 * i,
            300.0,
            380.0,
            FRAME_W,
            FRAME_H,
            WARNING_LINE_Y,
            0.05,
        )
    _ttc, _vx, _vy, _dw, _red, _vw, _static, risk, in_path = result
    assert not in_path
    assert risk == 0, "fast lateral motion outside the corridor must be suppressed"


def test_ttc_calculator_cleans_stale_tracks() -> None:
    calc = TTCCalculator(FPS)
    for _ in range(10):
        for track_id in (1, 2):
            calc.update(
                track_id,
                120.0,
                320.0,
                300.0,
                380.0,
                FRAME_W,
                FRAME_H,
                WARNING_LINE_Y,
                0.05,
            )
    calc.clean_stale_tracks({1})
    assert 1 in calc.width_history
    assert 2 not in calc.width_history
    assert 2 not in calc.ttc_history


# --------------------------------------------------------------------------- #
# 正面碰撞检测器（main.py 前向分支使用）
# --------------------------------------------------------------------------- #


def test_front_detector_static_target_is_safe() -> None:
    detector = FrontCollisionDetector(FPS)
    ttc, _vx, _vy, _dw, red_allowed, _vw, is_static, risk, in_path = _feed_detector(
        detector, static_sequence()
    )
    assert red_allowed and in_path
    assert is_static
    assert risk == 0
    assert ttc >= SAFE_TTC - 1e-9


def test_front_detector_approaching_target_warns() -> None:
    detector = FrontCollisionDetector(FPS)
    ttc, _vx, _vy, _dw, red_allowed, _vw, is_static, risk, in_path = _feed_detector(
        detector, approach_sequence()
    )
    assert red_allowed and in_path
    assert not is_static
    assert ttc < SAFE_TTC, f"approaching target must produce a finite TTC, got {ttc}"
    assert risk >= 1, f"approaching target should warn, got risk={risk}"


def test_front_detector_near_distance_forces_danger() -> None:
    detector = FrontCollisionDetector(FPS)
    _ttc, _vx, _vy, _dw, _red, _vw, _static, risk, _in_path = _feed_detector(
        detector, approach_sequence(), distance=2.5
    )
    assert risk == 2, "target closer than 3 m must hard-trigger danger"


def test_front_detector_off_path_lateral_target_is_safe() -> None:
    detector = FrontCollisionDetector(FPS)
    # Stays right of the 0.40–0.60 corridor (x > 384) while moving fast.
    frames: List[Frame] = [
        (120.0, 500.0 + 10.0 * i, 300.0, 380.0, 0.05) for i in range(12)
    ]
    _ttc, _vx, _vy, _dw, _red, _vw, _static, risk, in_path = _feed_detector(
        detector, frames
    )
    assert not in_path
    assert risk == 0


def test_front_detector_static_target_inside_hard_trigger_distance_is_safe() -> None:
    """A motionless object closer than 3 m must not be reported as danger.

    Regression: the near-distance hard trigger used to run after the static check and
    override it, so a parked object ~1.8 m ahead raised a permanent danger alarm.
    """
    detector = FrontCollisionDetector(FPS)
    result = _feed_detector(detector, static_sequence(count=15), distance=2.0)
    _ttc, _vx, _vy, _dw, _red, _vw, is_static, risk, _in_path = result
    assert is_static
    assert risk == 0, f"static object inside 3 m must stay safe, got risk={risk}"


def test_front_detector_sdt_ignores_pixel_space_speed() -> None:
    """The SDT must be computed in metric units only.

    Regression: ``sdt_dyn`` used to add ``max(0, -vy)`` where vy is pixels/second to
    ``v_self_mps`` in metres/second. A fast upward-moving box centre inflated the SDT to
    hundreds of metres, so any provided distance satisfied ``distance < SDT`` and the
    risk escalated to danger (2).
    """
    detector = FrontCollisionDetector(FPS)
    result = None
    for i in range(14):
        center_y = 320.0 - 12.0 * i  # vy = -360 px/s
        result = detector.update(
            1,
            100.0 + 4.0 * i,
            320.0,
            center_y,
            center_y + 100.0,
            FRAME_W,
            FRAME_H,
            WARNING_LINE_Y,
            0.06,
            distance=100.0,  # far beyond the real SDT of 2 m
            v_self_mps=0.0,
            t_reaction=1.2,
            d_safe=2.0,
        )
    _ttc, _vx, _vy, _dw, _red, _vw, _static, risk, _in_path = result
    assert risk <= 1, f"a 100 m gap must not be danger, got risk={risk}"


def test_front_detector_cleanup_stale_tracks() -> None:
    detector = FrontCollisionDetector(FPS, auto_cleanup_interval=10000)
    detector.update(1, 120.0, 320.0, 300.0, 380.0, FRAME_W, FRAME_H, WARNING_LINE_Y, 0.05)
    detector.update(2, 120.0, 320.0, 300.0, 380.0, FRAME_W, FRAME_H, WARNING_LINE_Y, 0.05)
    removed = detector.cleanup_stale_tracks(max_age=0)
    assert 1 in removed and 2 not in removed
    assert 1 not in detector.width_history
    assert 2 in detector.width_history


# --------------------------------------------------------------------------- #
# 正面报警去抖动（FrontAlarm）
# --------------------------------------------------------------------------- #


def test_front_alarm_danger_passes_immediately() -> None:
    alarm = FrontAlarm(confirm_frames=3)
    assert alarm.check_debounce(1, 2) == 2


def test_front_alarm_warning_requires_confirmation() -> None:
    alarm = FrontAlarm(confirm_frames=3)
    assert alarm.check_debounce(2, 1) == 0
    assert alarm.check_debounce(2, 1) == 0
    assert alarm.check_debounce(2, 1) == 1


def test_front_alarm_warning_counter_resets_on_safe_frame() -> None:
    alarm = FrontAlarm(confirm_frames=3)
    assert alarm.check_debounce(2, 1) == 0
    assert alarm.check_debounce(2, 0) == 0
    assert alarm.check_debounce(2, 1) == 0
    assert alarm.check_debounce(2, 1) == 0


def test_front_alarm_quality_shortens_confirmation() -> None:
    alarm = FrontAlarm(confirm_frames=4)
    # quality 1.5 -> effective confirm frames = round(4 / 1.5) = 3
    assert alarm.check_debounce(5, 1, quality=1.5) == 0
    assert alarm.check_debounce(5, 1, quality=1.5) == 0
    assert alarm.check_debounce(5, 1, quality=1.5) == 1


def test_front_alarm_cleanup_debounce() -> None:
    alarm = FrontAlarm(confirm_frames=2)
    for _ in range(5):
        alarm.check_debounce(9, 1)
    # Advance the debounce frame counter past max_age without touching track 9.
    for _ in range(5):
        alarm.check_debounce(100, 0)
    alarm.cleanup_debounce(max_age=1)
    assert 9 not in alarm._alarm_counters
    assert 9 not in alarm._debounce_last_seen


# --------------------------------------------------------------------------- #
# IPM 前向投影
# --------------------------------------------------------------------------- #


def test_ipm_ground_mapping_documented_behavior() -> None:
    """Ground appears below the modelled horizon and grows nearer toward the bottom."""
    ipm = IPM_Transformer()
    ipm.set_frame(FRAME_W, FRAME_H)
    horizon_v = ipm.cy - ipm.fy * math.tan(ipm.pitch)
    assert 0 < horizon_v < ipm.cy, "horizon must sit above the image centre"

    far = ipm.pixel_to_ground(320, 240, (FRAME_H, FRAME_W))
    near = ipm.pixel_to_ground(320, 460, (FRAME_H, FRAME_W))
    assert far is not None and near is not None
    assert near[1] < far[1], "distance must shrink toward the bottom of the frame"
    # Above the horizon is sky and must not intersect the ground plane.
    assert ipm.pixel_to_ground(320, 100, (FRAME_H, FRAME_W)) is None


def test_ipm_forward_ground_mapping_maps_box_bottom() -> None:
    """Regression: a detection box bottom must map to a plausible forward distance.

    Before the fix, pixel_to_ground mirrored the vertical axis, so every production
    call with a real box bottom returned None and the IPM / model-B TTC never ran.
    """
    ipm = IPM_Transformer()
    ipm.set_frame(FRAME_W, FRAME_H)
    for v in (300, 340, 380, 420, 460):
        ground = ipm.pixel_to_ground(320, v, (FRAME_H, FRAME_W))
        assert ground is not None, f"box bottom v={v} must map to the ground plane"
        _gx, forward_distance = ground
        assert 0.5 < forward_distance < 20.0, forward_distance

    # Monotonic: the lower the box bottom, the closer the target.
    distances = [
        ipm.pixel_to_ground(320, v, (FRAME_H, FRAME_W))[1] for v in (300, 380, 460)
    ]
    assert distances[0] > distances[1] > distances[2]


def test_ipm_round_trip_is_consistent() -> None:
    ipm = IPM_Transformer()
    ipm.set_frame(FRAME_W, FRAME_H)
    pixel = ipm.ground_to_pixel(0.0, 10.0, (FRAME_H, FRAME_W))
    assert pixel is not None
    back = ipm.pixel_to_ground(pixel[0], pixel[1], (FRAME_H, FRAME_W))
    assert back is not None
    assert abs(back[0] - 0.0) < 1e-6
    assert abs(back[1] - 10.0) < 1e-6


def test_ipm_distance_enables_danger_escalation() -> None:
    """Regression: with the IPM working, a sub-threshold TTC escalates 1 → 2.

    Before the fix, pixel_to_ground always returned None for real box bottoms, so
    ``phys_distance`` was never available and the risk could not escalate past 1.
    """
    ipm = IPM_Transformer()
    ipm.set_frame(FRAME_W, FRAME_H)

    def run(with_ipm: bool) -> Tuple[Any, ...]:
        detector = FrontCollisionDetector(FPS)
        result = None
        for i in range(16):
            width = 100.0 + 8.0 * i
            bottom_y = 300.0 + 2.0 * i
            center_y = bottom_y - 0.75 * width / 2.0
            result = detector.update(
                1,
                width,
                320.0,
                center_y,
                bottom_y,
                FRAME_W,
                FRAME_H,
                WARNING_LINE_Y,
                0.06,
                **({"ipm": ipm} if with_ipm else {}),
            )
        return result

    plain = run(with_ipm=False)
    with_distance = run(with_ipm=True)
    assert plain[0] < SAFE_TTC, "the width model alone must already yield a finite TTC"
    assert with_distance[0] < SAFE_TTC
    assert plain[7] == 1, f"without a physical distance the risk stays a warning, got {plain[7]}"
    assert with_distance[7] == 2, (
        f"with IPM distance the risk must escalate to danger, got {with_distance[7]}"
    )


# --------------------------------------------------------------------------- #
# 集成：接近目标触发报警升级
# --------------------------------------------------------------------------- #


def test_forward_pipeline_escalates_on_approach() -> None:
    detector = FrontCollisionDetector(FPS)
    alarm = FrontAlarm(confirm_frames=2)
    risks: List[int] = []
    for width, cx, cy, bottom_y, area_ratio in approach_sequence(count=20):
        output = detector.update(
            7, width, cx, cy, bottom_y, FRAME_W, FRAME_H, WARNING_LINE_Y, area_ratio
        )
        risks.append(alarm.check_debounce(7, output[7]))
    assert risks[0] == 0, "no alarm while track history is still empty"
    assert max(risks) >= 1, "an approaching target must eventually raise an alarm"


def test_forward_pipeline_reaches_danger_with_distance() -> None:
    detector = FrontCollisionDetector(FPS)
    alarm = FrontAlarm(confirm_frames=2)
    risks: List[int] = []
    for width, cx, cy, bottom_y, area_ratio in approach_sequence(count=20):
        output = detector.update(
            7,
            width,
            cx,
            cy,
            bottom_y,
            FRAME_W,
            FRAME_H,
            WARNING_LINE_Y,
            area_ratio,
            distance=2.5,
        )
        risks.append(alarm.check_debounce(7, output[7]))
    assert risks[-1] == 2, "a target inside the safety distance must end in danger"


def _run_standalone() -> int:
    tests: List[Tuple[str, Any]] = [
        (name, obj)
        for name, obj in sorted(globals().items())
        if name.startswith("test_") and callable(obj)
    ]
    failures: List[str] = []
    for name, func in tests:
        try:
            func()
            print(f"PASS  {name}")
        except AssertionError as exc:
            failures.append(name)
            print(f"FAIL  {name}: {exc}")
        except Exception as exc:  # noqa: BLE001 - report unexpected errors too
            failures.append(name)
            print(f"ERROR {name}: {type(exc).__name__}: {exc}")
    print(f"\n{len(tests) - len(failures)}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(_run_standalone())
