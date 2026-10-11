/* FastGuard 移动端 Web 界面逻辑。
 *
 * 设计约束（与 Qt6 客户端一致）：
 *   - 只显示 AI 推理画面，不提供图像增强视图，也不显示刷新率；
 *   - 左上角汉堡设置栏：切换摄像头 / 阈值设置 / 推理图片大小；
 *   - 右上角"卸载推理"徽标反映与推理服务的连接状态。
 */
(function () {
  'use strict';

  var CAMERA_CHOICES = [0, 1, 2, 3];
  var SIZE_CHOICES = [320, 416, 512, 640];
  var STORAGE_KEY = 'fastguard.mobile.settings';
  var STATUS_INTERVAL_MS = 1500;
  var STALL_SECONDS = 3;

  var DEFAULTS = {
    camera_index: 0,
    weak_conf: 0.38,
    edge_strength: 28.0,
    inference_size: 320,
    show_bev: false
  };

  var $ = function (id) { return document.getElementById(id); };

  var state = {
    settings: Object.assign({}, DEFAULTS),
    status: null,
    fixedInferenceSize: null,
    lastFrameAge: null,
    reachable: false
  };

  /* ------------------------------------------------------------ 本地设置 */
  function loadSettings() {
    try {
      var raw = window.localStorage.getItem(STORAGE_KEY);
      if (raw) {
        var saved = JSON.parse(raw);
        Object.keys(DEFAULTS).forEach(function (key) {
          if (saved[key] !== undefined) { state.settings[key] = saved[key]; }
        });
      }
    } catch (err) { /* localStorage 不可用时用默认值 */ }
  }

  function saveSettings() {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(state.settings));
    } catch (err) { /* 忽略：隐私模式下可能不可写 */ }
  }

  /* ------------------------------------------------------------ 指令下发 */
  function postCommand(action, payload) {
    return fetch('/api/' + action, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload || {})
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (data) {
        data.http_status = response.status;
        return data;
      });
    }).catch(function () {
      return { ok: false, error: '无法连接推理服务' };
    });
  }

  function reportResult(result, fallbackAction) {
    if (result && result.ok) { return; }
    var message = (result && (result.error || result.reason)) || '指令执行失败';
    setServiceInfo(message);
  }

  function setServiceInfo(text) { $('service-info').textContent = text; }

  /* ------------------------------------------------------------ 分段控件 */
  function buildSegmented(container, choices, labelFor, onPick) {
    container.innerHTML = '';
    container.classList.toggle('two-col', choices.length <= 4 ? false : true);
    choices.forEach(function (choice) {
      var button = document.createElement('button');
      button.type = 'button';
      button.setAttribute('role', 'radio');
      button.textContent = labelFor(choice);
      button.addEventListener('click', function () { onPick(choice); });
      container.appendChild(button);
    });
  }

  function markSegmented(container, choices, active, disabledChoices) {
    var buttons = container.querySelectorAll('button');
    choices.forEach(function (choice, index) {
      var button = buttons[index];
      if (!button) { return; }
      button.setAttribute('aria-checked', String(choice === active));
      button.disabled = (disabledChoices || []).indexOf(choice) !== -1;
    });
  }

  /* ------------------------------------------------------------ 界面同步 */
  function cameraLabel(index) {
    if (index === 0) { return '后置主摄'; }
    if (index === 1) { return '前置'; }
    return '摄像头 ' + index;
  }

  function renderCamera() {
    var enabled = state.fixedInferenceSize === null; // 仅用于触发一致的重绘逻辑
    markSegmented($('camera-group'), CAMERA_CHOICES, Number(state.settings.camera_index), []);
    $('camera-hint').textContent = '当前：' + cameraLabel(Number(state.settings.camera_index)) +
      '（序号 ' + state.settings.camera_index + '）';
    return enabled;
  }

  function renderThresholds() {
    var weak = Number(state.settings.weak_conf);
    var edge = Number(state.settings.edge_strength);
    $('weak-conf').value = String(Math.round(weak * 100));
    $('edge-strength').value = String(Math.round(edge * 10));
    $('weak-conf-value').textContent = weak.toFixed(2);
    $('edge-strength-value').textContent = edge.toFixed(1);
  }

  function renderInferenceSize() {
    var disabled = state.fixedInferenceSize === null ? [] : SIZE_CHOICES.filter(function (size) {
      return size !== state.fixedInferenceSize;
    });
    markSegmented($('size-group'), SIZE_CHOICES, Number(state.settings.inference_size), disabled);
    if (state.fixedInferenceSize === null) {
      $('size-hint').textContent = '当前权重支持动态尺寸，可自由选择。';
    } else {
      $('size-hint').textContent = '当前为固定输入的 INT8 模型，仅支持 ' +
        state.fixedInferenceSize + ' px（改用 FP32 权重即可调整）。';
    }
  }

  function renderBev() {
    var toggle = $('bev-toggle');
    var image = $('bev');
    toggle.checked = !!state.settings.show_bev;
    image.hidden = !state.settings.show_bev;
    if (state.settings.show_bev) {
      image.src = '/bev?t=' + Date.now();
    } else {
      image.removeAttribute('src');
    }
  }

  function renderAbout() {
    var size = state.settings.inference_size;
    setServiceInfoForAbout('摄像头 ' + state.settings.camera_index +
      ' · 推理尺寸 ' + size + 'px · 阈值 ' +
      Number(state.settings.weak_conf).toFixed(2) + '/' + Number(state.settings.edge_strength).toFixed(1));
  }

  function setServiceInfoForAbout(text) { $('about-opts').textContent = text; }

  /* ------------------------------------------------------------ 状态与徽标 */
  var BADGE_TEXT = {
    online: '运行中',
    stalled: '画面停滞',
    connecting: '连接中',
    offline: '已断开'
  };

  function setBadge(stateName, detail) {
    var badge = $('badge');
    badge.setAttribute('data-state', stateName);
    $('badge-state').textContent = BADGE_TEXT[stateName] || stateName;
    badge.title = detail || ('卸载推理：' + (BADGE_TEXT[stateName] || stateName));
  }

  function applyStatus(payload) {
    state.status = payload || {};
    state.reachable = true;

    if (payload && payload.fixed_inference_size !== undefined) {
      state.fixedInferenceSize = payload.fixed_inference_size === null ? null : Number(payload.fixed_inference_size);
    }

    // 服务端为准：同步界面上的设置（例如服务端由命令行启动了别的摄像头）
    if (payload) {
      if (payload.source !== undefined && payload.source !== null) { state.settings.camera_index = payload.source; }
      if (payload.inference_size) { state.settings.inference_size = payload.inference_size; }
      if (payload.weak_conf !== undefined) { state.settings.weak_conf = payload.weak_conf; }
      if (payload.edge_strength !== undefined) { state.settings.edge_strength = payload.edge_strength; }
      if (payload.bev !== undefined) { state.settings.show_bev = !!payload.bev; }
      state.lastFrameAge = (payload.last_frame_age === undefined || payload.last_frame_age === null)
        ? null : Number(payload.last_frame_age);
    }

    renderCamera();
    renderThresholds();
    renderInferenceSize();
    renderBev();
    renderAbout();
    saveSettings();

    var age = state.lastFrameAge;
    var error = payload && payload.error;
    if (age !== null && age <= STALL_SECONDS) {
      setBadge('online', '推理运算已在服务端完成');
      hidePlaceholder();
    } else if (age !== null && age > STALL_SECONDS) {
      setBadge('stalled', '推理服务无新画面');
      showPlaceholder('暂无推理画面', error || '等待服务端输出新画面');
    } else {
      setBadge('connecting', '推理服务正在启动或打开视频源');
      showPlaceholder('正在连接推理服务', error || '首次启动需加载模型，请稍候');
    }

    var parts = [];
    if (payload && payload.state) {
      parts.push('服务端 ' + ({
        running: '运行中', scanning: '等待画面', idle: '待机', stopped: '已停止'
      }[payload.state] || payload.state));
    }
    if (payload && payload.source !== undefined && payload.source !== null) {
      parts.push('摄像头 ' + payload.source);
    }
    if (payload && payload.inference_size) { parts.push(payload.inference_size + 'px'); }
    if (payload && payload.model) { parts.push(payload.model); }
    if (error) { parts.push(error); }
    setServiceInfo(parts.join(' · ') || '已连接');
  }

  function showPlaceholder(title, hint) {
    $('placeholder-title').textContent = title;
    $('placeholder-hint').textContent = hint || '';
    $('placeholder').style.display = 'flex';
  }

  function hidePlaceholder() { $('placeholder').style.display = 'none'; }

  function refreshStatus() {
    fetch('/status', { cache: 'no-store' })
      .then(function (response) {
        if (!response.ok) { throw new Error('bad status'); }
        return response.json();
      })
      .then(function (payload) {
        state.reachable = true;
        applyStatus(payload);
      })
      .catch(function () {
        state.reachable = false;
        setBadge('offline', '无法连接推理服务');
        showPlaceholder('推理服务未连接', '请确认服务端仍在运行，然后重新连接画面');
        setServiceInfo('无法连接推理服务');
      });
  }

  /* ------------------------------------------------------------ 交互绑定 */
  function bindDrawer() {
    var drawer = $('drawer');
    var scrim = $('scrim');

    function open() {
      drawer.classList.add('open');
      drawer.setAttribute('aria-hidden', 'false');
      $('hamburger').setAttribute('aria-expanded', 'true');
      scrim.hidden = false;
    }

    function close() {
      drawer.classList.remove('open');
      drawer.setAttribute('aria-hidden', 'true');
      $('hamburger').setAttribute('aria-expanded', 'false');
      scrim.hidden = true;
    }

    $('hamburger').addEventListener('click', function () {
      if (drawer.classList.contains('open')) { close(); } else { open(); }
    });
    $('drawer-close').addEventListener('click', close);
    scrim.addEventListener('click', close);
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') { close(); }
    });
  }

  function bindCamera() {
    buildSegmented($('camera-group'), CAMERA_CHOICES, function (index) { return String(index); }, function (index) {
      state.settings.camera_index = index;
      renderCamera();
      saveSettings();
      setServiceInfo('已切换到摄像头 ' + index + '，服务端正在重新打开视频源…');
      postCommand('source', { index: index }).then(function (result) {
        reportResult(result, 'source');
        if (result && result.status) { applyStatus(result.status); }
      });
    });
  }

  function bindThresholds() {
    var timer = null;
    var weak = $('weak-conf');
    var edge = $('edge-strength');

    function onInput() {
      state.settings.weak_conf = Number(weak.value) / 100;
      state.settings.edge_strength = Number(edge.value) / 10;
      $('weak-conf-value').textContent = Number(state.settings.weak_conf).toFixed(2);
      $('edge-strength-value').textContent = Number(state.settings.edge_strength).toFixed(1);
      saveSettings();
      renderAbout();
      window.clearTimeout(timer);
      timer = window.setTimeout(function () {
        postCommand('thresholds', {
          weak_conf: Number(state.settings.weak_conf),
          edge_strength: Number(state.settings.edge_strength)
        }).then(function (result) {
          reportResult(result, 'thresholds');
          setServiceInfo('阈值已下发：' + Number(state.settings.weak_conf).toFixed(2) + ' / ' +
            Number(state.settings.edge_strength).toFixed(1));
        });
      }, 220);
    }

    weak.addEventListener('input', onInput);
    edge.addEventListener('input', onInput);
  }

  function bindInferenceSize() {
    buildSegmented($('size-group'), SIZE_CHOICES, function (size) { return size + ' px'; }, function (size) {
      state.settings.inference_size = size;
      renderInferenceSize();
      saveSettings();
      renderAbout();
      setServiceInfo('推理图片大小已下发：' + size + ' px');
      postCommand('inference_size', { size: size }).then(function (result) {
        reportResult(result, 'inference_size');
        if (result && result.status) { applyStatus(result.status); }
      });
    });
  }

  function bindBev() {
    $('bev-toggle').addEventListener('change', function (event) {
      var enabled = !!event.target.checked;
      state.settings.show_bev = enabled;
      saveSettings();
      renderBev();
      setServiceInfo(enabled ? '已开启 BEV 俯视图叠加' : '已关闭 BEV 俯视图叠加');
      postCommand('bev', { enabled: enabled }).then(function (result) {
        reportResult(result, 'bev');
        if (result && result.status) { applyStatus(result.status); }
      });
    });
  }

  function bindService() {
    $('reload').addEventListener('click', function () {
      var image = $('frame');
      image.src = '/stream?t=' + Date.now();
      setServiceInfo('正在重新连接画面…');
      refreshStatus();
    });
  }

  function bindReset() {
    $('reset').addEventListener('click', function () {
      state.settings = Object.assign({}, DEFAULTS);
      saveSettings();
      renderCamera();
      renderThresholds();
      renderInferenceSize();
      renderBev();
      renderAbout();
      postCommand('thresholds', {
        weak_conf: DEFAULTS.weak_conf, edge_strength: DEFAULTS.edge_strength
      });
      postCommand('inference_size', { size: DEFAULTS.inference_size });
      postCommand('bev', { enabled: DEFAULTS.show_bev });
      setServiceInfo('已恢复默认设置');
    });
  }

  function bindFrame() {
    $('frame').addEventListener('load', function () {
      hidePlaceholder();
    });
    $('frame').addEventListener('error', function () {
      setBadge('stalled', '推理画面中断');
      showPlaceholder('推理画面中断', '请检查推理服务是否仍在运行');
    });
  }

  /* ------------------------------------------------------------ 启动 */
  function main() {
    loadSettings();
    buildSegmented($('camera-group'), CAMERA_CHOICES, function (index) { return String(index); }, function () {});
    bindCamera();
    bindThresholds();
    bindInferenceSize();
    bindBev();
    bindService();
    bindReset();
    bindDrawer();
    bindFrame();

    renderCamera();
    renderThresholds();
    renderInferenceSize();
    renderBev();
    renderAbout();
    setBadge('connecting', '正在连接推理服务');

    refreshStatus();
    window.setInterval(refreshStatus, STATUS_INTERVAL_MS);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', main);
  } else {
    main();
  }
})();
