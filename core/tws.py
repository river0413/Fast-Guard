"""
TWS 目标记忆系统 (Track-While-Scan)

在 ByteTrack 之上增加一层稳定 ID 管理 + 航迹状态机 + 卡尔曼预测外推 + 跨 ID 关联：
- 生命周期：tentative -> confirmed -> coasting -> dropped
- 失跟期间用卡尔曼预测外推伪检测框（coasting），保证下游 TTC 不中断
- 新 raw_id 与 coasting 航迹预测框 IoU 匹配 -> 跨 ID 合并，继承 stable_id 与历史
- 输出航迹质量评分 quality 与平滑速度 (vx, vy)（像素/秒）
"""

import cv2
import numpy as np
from typing import Dict


class TrackState:
    TENTATIVE = "tentative"
    CONFIRMED = "confirmed"
    COASTING = "coasting"
    DROPPED = "dropped"


class TrackOutput:
    """TWSManager.update 输出的单条航迹结果（供主循环构建 infos）"""

    __slots__ = ("stable_id", "x1", "y1", "x2", "y2", "cx", "cy",
                 "class_name", "state", "is_coasting", "quality", "vx", "vy", "conf")

    def __init__(self, stable_id, x1, y1, x2, y2, cx, cy, class_name,
                 state, is_coasting, quality, vx, vy, conf):
        self.stable_id = int(stable_id)
        self.x1 = int(x1)
        self.y1 = int(y1)
        self.x2 = int(x2)
        self.y2 = int(y2)
        self.cx = int(cx)
        self.cy = int(cy)
        self.class_name = class_name
        self.state = state
        self.is_coasting = bool(is_coasting)
        self.quality = float(quality)
        self.vx = float(vx)
        self.vy = float(vy)
        self.conf = float(conf)


class _TargetTrack:
    """单个航迹内部状态"""

    __slots__ = ("stable_id", "raw_id", "class_name", "state", "conf",
                 "last_seen_frame", "missed_count", "update_count",
                 "kf", "filtered_box", "quality", "vx", "vy")

    def __init__(self, stable_id, raw_id, class_name, x1, y1, x2, y2, conf, frame_idx):
        self.stable_id = stable_id
        self.raw_id = raw_id
        self.class_name = class_name
        self.state = TrackState.TENTATIVE
        self.conf = conf
        self.last_seen_frame = frame_idx
        self.missed_count = 0
        self.update_count = 0

        cx = (x1 + x2) * 0.5
        cy = (y1 + y2) * 0.5
        w = float(x2 - x1)
        h = float(y2 - y1)

        # 卡尔曼：状态 [cx, cy, w, h, vx, vy](6维)，测量 [cx, cy, w, h](4维)
        self.kf = cv2.KalmanFilter(6, 4)
        self.kf.transitionMatrix = np.array([
            [1, 0, 0, 0, 1, 0],
            [0, 1, 0, 0, 0, 1],
            [0, 0, 1, 0, 0, 0],
            [0, 0, 0, 1, 0, 0],
            [0, 0, 0, 0, 1, 0],
            [0, 0, 0, 0, 0, 1],
        ], np.float32)
        self.kf.measurementMatrix = np.array([
            [1, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0],
            [0, 0, 1, 0, 0, 0],
            [0, 0, 0, 1, 0, 0],
        ], np.float32)
        self.kf.processNoiseCov = np.eye(6, dtype=np.float32) * 1e-2
        self.kf.processNoiseCov[4, 4] = 1e-1
        self.kf.processNoiseCov[5, 5] = 1e-1
        self.kf.measurementNoiseCov = np.eye(4, dtype=np.float32) * 1e1
        self.kf.errorCovPost = np.eye(6, dtype=np.float32)
        self.kf.statePost = np.array([[cx], [cy], [w], [h], [0.0], [0.0]], np.float32)

        self.filtered_box = (int(x1), int(y1), int(x2), int(y2))
        self.quality = float(conf)
        self.vx = 0.0
        self.vy = 0.0


class TWSManager:
    """统一航迹管理器：稳定 ID + 状态机 + 卡尔曼外推 + 跨 ID 关联"""

    def __init__(self, fps=30.0, tentative_frames=5, coasting_frames=8,
                 iou_match_thresh=0.3, max_tracked=200):
        self.fps = fps if fps and fps > 0 else 30.0
        self.tentative_frames = max(1, int(tentative_frames))
        self.coasting_frames = max(1, int(coasting_frames))
        self.iou_match_thresh = float(iou_match_thresh)
        self.max_tracked = max(1, int(max_tracked))
        self._tracks: Dict[int, _TargetTrack] = {}
        self._next_id = 1

    # ---- 对外查询接口 ----
    def get_quality(self, stable_id):
        t = self._tracks.get(stable_id)
        return t.quality if t else 1.0

    def get_velocity(self, stable_id):
        t = self._tracks.get(stable_id)
        return (t.vx, t.vy) if t else (0.0, 0.0)

    def is_coasting(self, stable_id):
        t = self._tracks.get(stable_id)
        return (t.state == TrackState.COASTING) if t else False

    @staticmethod
    def _iou(box_a, box_b):
        ax1, ay1, ax2, ay2 = box_a
        bx1, by1, bx2, by2 = box_b
        ix1 = max(ax1, bx1)
        iy1 = max(ay1, by1)
        ix2 = min(ax2, bx2)
        iy2 = min(ay2, by2)
        if ix2 <= ix1 or iy2 <= iy1:
            return 0.0
        inter = (ix2 - ix1) * (iy2 - iy1)
        area_a = (ax2 - ax1) * (ay2 - ay1)
        area_b = (bx2 - bx1) * (by2 - by1)
        return inter / max(area_a + area_b - inter, 1e-6)

    def _predict_all(self):
        for t in self._tracks.values():
            st = t.kf.predict()
            cx, cy = st[0, 0], st[1, 0]
            w, h = st[2, 0], st[3, 0]
            t.vx = float(st[4, 0]) * self.fps
            t.vy = float(st[5, 0]) * self.fps
            t.filtered_box = (cx - w * 0.5, cy - h * 0.5, cx + w * 0.5, cy + h * 0.5)

    def _correct(self, t, raw_id, class_name, x1, y1, x2, y2, conf, frame_idx):
        cx = (x1 + x2) * 0.5
        cy = (y1 + y2) * 0.5
        meas = np.array([[cx], [cy], [float(x2 - x1)], [float(y2 - y1)]], np.float32)
        st = t.kf.correct(meas)
        t.vx = float(st[4, 0]) * self.fps
        t.vy = float(st[5, 0]) * self.fps
        t.filtered_box = (st[0, 0] - st[2, 0] * 0.5, st[1, 0] - st[3, 0] * 0.5,
                          st[0, 0] + st[2, 0] * 0.5, st[1, 0] + st[3, 0] * 0.5)
        t.raw_id = raw_id
        t.class_name = class_name
        t.conf = conf
        t.last_seen_frame = frame_idx
        t.missed_count = 0
        t.update_count += 1
        # 质量评分：向当前检测置信度平滑收敛
        t.quality = 0.7 * t.quality + 0.3 * float(conf)
        if t.state == TrackState.TENTATIVE:
            if t.update_count >= self.tentative_frames:
                t.state = TrackState.CONFIRMED
        elif t.state == TrackState.COASTING:
            t.state = TrackState.CONFIRMED  # 重新关联恢复

    def _mark_missed(self, t, frame_idx):
        t.missed_count += 1
        t.quality = max(0.2, t.quality * 0.9)
        if t.state == TrackState.TENTATIVE:
            t.state = TrackState.DROPPED
        elif t.state == TrackState.CONFIRMED:
            t.state = TrackState.COASTING
        elif t.state == TrackState.COASTING:
            if t.missed_count > self.coasting_frames:
                t.state = TrackState.DROPPED

    def _create_track(self, det, frame_idx):
        raw_id, cls, x1, y1, x2, y2, conf, _cx, _cy = det
        sid = self._next_id
        self._next_id += 1
        self._tracks[sid] = _TargetTrack(sid, raw_id, cls, x1, y1, x2, y2, conf, frame_idx)
        return sid

    def update(self, raw_dets, frame_idx):
        """
        raw_dets: list of (raw_id, class_name, x1, y1, x2, y2, conf, cx, cy)
                  或 None / 空列表（跳帧间隙，执行纯预测/外推）
        返回: list[TrackOutput]
        """
        self._predict_all()

        raw_list = [d for d in (raw_dets or [])]
        assigned_raw = set()
        matched_ids = set()

        # 1. 贪心匹配 active 航迹（confirmed/tentative）与 raw detections
        active = [t for t in self._tracks.values()
                  if t.state in (TrackState.CONFIRMED, TrackState.TENTATIVE)]
        for t in active:
            best_i = -1
            best_iou = self.iou_match_thresh
            for i, det in enumerate(raw_list):
                if i in assigned_raw:
                    continue
                iou = self._iou(t.filtered_box, (det[2], det[3], det[4], det[5]))
                if iou > best_iou:
                    best_iou = iou
                    best_i = i
            if best_i >= 0:
                det = raw_list[best_i]
                assigned_raw.add(best_i)
                matched_ids.add(t.stable_id)
                self._correct(t, det[0], det[1], det[2], det[3], det[4], det[5], det[6], frame_idx)

        # 2. 未匹配 raw detections：先尝试跨 ID 合并 coasting 航迹（L3），否则新建
        coasting = [t for t in self._tracks.values() if t.state == TrackState.COASTING]
        for i, det in enumerate(raw_list):
            if i in assigned_raw:
                continue
            best_t = None
            best_iou = self.iou_match_thresh
            for t in coasting:
                if t.state != TrackState.COASTING or t.stable_id in matched_ids:
                    continue
                iou = self._iou(t.filtered_box, (det[2], det[3], det[4], det[5]))
                if iou > best_iou:
                    best_iou = iou
                    best_t = t
            if best_t is not None:
                assigned_raw.add(i)
                matched_ids.add(best_t.stable_id)
                self._correct(best_t, det[0], det[1], det[2], det[3], det[4], det[5], det[6], frame_idx)
            else:
                sid = self._create_track(det, frame_idx)
                matched_ids.add(sid)

        # 3. 未匹配航迹 -> missed（tentative 直接丢，confirmed 转 coasting）
        for t in list(self._tracks.values()):
            if t.stable_id not in matched_ids and t.state != TrackState.DROPPED:
                self._mark_missed(t, frame_idx)

        # 4. 清理 dropped，控制航迹数量
        for sid in [s for s, t in self._tracks.items() if t.state == TrackState.DROPPED]:
            del self._tracks[sid]
        while len(self._tracks) > self.max_tracked:
            oldest = min(self._tracks, key=lambda s: self._tracks[s].last_seen_frame)
            del self._tracks[oldest]

        # 5. 输出
        out = []
        for t in self._tracks.values():
            x1, y1, x2, y2 = t.filtered_box
            cx = (x1 + x2) * 0.5
            cy = (y1 + y2) * 0.5
            out.append(TrackOutput(
                t.stable_id, x1, y1, x2, y2, cx, cy, t.class_name,
                t.state, t.state == TrackState.COASTING, t.quality, t.vx, t.vy, t.conf,
            ))
        return out
