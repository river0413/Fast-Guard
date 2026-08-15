"""
本车运动检测器 (Ego Motion Detector)

纯图像全局帧间差分判定相机/本车是否静止，无硬件依赖。
思路复用 view_classifier 的 global_mse_history 百分位自适应阈值，
并加入滞回（连续 N 帧静止确认 / M 帧运动恢复），抑制停车瞬间抖动。
"""

import cv2
import numpy as np
from collections import deque


class EgoMotionDetector:
    def __init__(self, stop_confirm_frames=5, move_confirm_frames=3,
                 percentile=75, base_thresh=15.0):
        self.stop_confirm_frames = max(1, int(stop_confirm_frames))
        self.move_confirm_frames = max(1, int(move_confirm_frames))
        self.percentile = int(percentile)
        self.base_thresh = float(base_thresh)
        self.prev_gray = None
        self.global_mse_history = deque(maxlen=30)
        self._stop_counter = 0
        self._move_counter = 0
        self.is_stopped = False

    def reset(self):
        self.prev_gray = None
        self.global_mse_history.clear()
        self._stop_counter = 0
        self._move_counter = 0
        self.is_stopped = False

    def update(self, gray):
        """输入原始灰度图，返回 is_stopped 布尔"""
        if gray is None:
            return self.is_stopped
        if self.prev_gray is None:
            self.prev_gray = gray.copy()
            return self.is_stopped

        diff = cv2.absdiff(gray, self.prev_gray)
        mse = float(np.mean(diff.astype(np.float32) ** 2))
        self.prev_gray = gray.copy()
        self.global_mse_history.append(mse)

        if len(self.global_mse_history) >= 5:
            p = float(np.percentile(list(self.global_mse_history), self.percentile))
        else:
            p = float(np.mean(self.global_mse_history)) * 1.5
        thresh = self.base_thresh + 0.4 * p

        moving = mse > thresh
        if moving:
            self._move_counter += 1
            self._stop_counter = 0
            if self._move_counter >= self.move_confirm_frames:
                self.is_stopped = False
        else:
            self._stop_counter += 1
            self._move_counter = 0
            if self._stop_counter >= self.stop_confirm_frames:
                self.is_stopped = True
        return self.is_stopped
