"""
停止哨兵 (Stopped Sentinel)

当本车静止时，监控安全区 ROI 内的像素运动，分级输出：
- safe : 无显著运动
- hint : 轻微运动（日志 + UI 提示）
- alarm: 显著运动（声音 + 日志 + 风险卡）
运动检测使用帧间差分（放弃光流思路），仅回答「有没有变」。
"""

import cv2
import numpy as np


class StoppedSentinel:
    def __init__(self, hint_ratio=0.005, alarm_ratio=0.02,
                 confirm_frames=3, diff_thresh=15):
        self.hint_ratio = float(hint_ratio)
        self.alarm_ratio = float(alarm_ratio)
        self.confirm_frames = max(1, int(confirm_frames))
        self.diff_thresh = float(diff_thresh)
        self.prev_roi = None
        self._hint_counter = 0
        self._alarm_counter = 0
        self.last_level = "safe"

    def reset(self):
        self.prev_roi = None
        self._hint_counter = 0
        self._alarm_counter = 0
        self.last_level = "safe"

    def _get_roi(self, gray, perspective, h, w, warning_line_y, warning_line_x, camera_side):
        """按视角返回安全区 ROI 灰度图"""
        if perspective == "前向视角":
            y0 = max(0, min(int(warning_line_y), h - 1))
            return gray[y0:h, :]
        # 侧向：靠车身一侧竖条（与 side_alarm 红色渐变区域一致）
        if warning_line_x is None:
            return None
        x0 = max(0, min(int(warning_line_x), w - 1))
        if camera_side == "left":
            return gray[:, 0:x0]
        return gray[:, x0:w]

    def update(self, gray, perspective, h, w, warning_line_y,
               warning_line_x=None, camera_side="left"):
        """返回 (level, motion_ratio)"""
        roi = self._get_roi(gray, perspective, h, w, warning_line_y, warning_line_x, camera_side)
        if roi is None or roi.size == 0:
            return "safe", 0.0

        if self.prev_roi is None or self.prev_roi.shape != roi.shape:
            self.prev_roi = roi.copy()
            return "safe", 0.0

        diff = cv2.absdiff(roi, self.prev_roi)
        self.prev_roi = roi.copy()
        _, thresh = cv2.threshold(diff, self.diff_thresh, 255, cv2.THRESH_BINARY)
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        thresh = cv2.morphologyEx(thresh, cv2.MORPH_OPEN, kernel)
        motion_ratio = float(np.count_nonzero(thresh)) / max(1, thresh.size)

        if motion_ratio >= self.alarm_ratio:
            raw_level = "alarm"
        elif motion_ratio >= self.hint_ratio:
            raw_level = "hint"
        else:
            raw_level = "safe"

        # 连续帧确认
        self._hint_counter = self._hint_counter + 1 if raw_level == "hint" else 0
        self._alarm_counter = self._alarm_counter + 1 if raw_level == "alarm" else 0

        if self._alarm_counter >= self.confirm_frames:
            self.last_level = "alarm"
        elif self._hint_counter >= self.confirm_frames:
            self.last_level = "hint"
        else:
            self.last_level = "safe"

        return self.last_level, motion_ratio
