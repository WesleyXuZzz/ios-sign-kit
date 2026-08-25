const SESSION_KEY = "iossignkit-lan-session";
const POLL_INTERVAL_MS = 5000;
const params = new URLSearchParams(window.location.search);
const pairingToken = params.get("pair");

const $ = (selector) => document.querySelector(selector);
const elements = {
  appHeader: $("#app-header"),
  viewLogin: $("#view-login"),
  viewControl: $("#view-control"),
  pairedNotice: $("#paired-notice"),
  loginForm: $("#login-form"),
  password: $("#password-input"),
  passwordField: $("#password-field"),
  loginError: $("#login-error"),
  loginErrorText: $("#login-error span"),
  togglePassword: $("#toggle-password"),
  togglePasswordUse: $("#toggle-password-use"),
  exitButton: $("#exit-button"),
  states: {
    ready: $("#state-ready"),
    checking: $("#state-checking"),
    progress: $("#state-progress"),
    success: $("#state-success"),
    failure: $("#state-failure")
  },
  readyTitle: $("#ready-title"),
  readyLede: $("#ready-lede"),
  targetApp: $("#target-app span"),
  targetDevice: $("#target-device span"),
  deviceStatusContainer: $("#device-status"),
  deviceStatus: $("#device-status span:last-child"),
  expiryValue: $("#expiry-value"),
  renewButton: $("#renew-button"),
  recheckButton: $("#recheck-button"),
  lastChecked: $("#last-checked"),
  progressLede: $("#progress-lede"),
  stageList: $("#stage-list"),
  stageCount: $("#stage-count"),
  elapsed: $("#elapsed"),
  successLede: $("#success-lede"),
  successExpiry: $("#success-expiry"),
  successElapsed: $("#success-elapsed"),
  successDone: $("#success-done"),
  failureLede: $("#failure-lede"),
  failureReason: $("#failure-reason"),
  failureStage: $("#failure-stage"),
  failureElapsed: $("#failure-elapsed"),
  retryButton: $("#retry-button"),
  failureRecheck: $("#failure-recheck"),
  profileChoice: $("#profile-choice"),
  profileChoiceSheet: $("#profile-choice-sheet"),
  profileChoiceMessage: $("#profile-choice-message"),
  profileForce: $("#profile-force"),
  profileAutomatic: $("#profile-automatic"),
  profileCancel: $("#profile-cancel"),
  footerAddress: $("#footer-address"),
  liveRegion: $("#live-region")
};

let pollTimer = null;
let latestSnapshot = null;
let enteredByPairing = false;
let profileChoiceSubmitting = false;
let profileChoiceReturnFocus = null;

function sessionToken() {
  return sessionStorage.getItem(SESSION_KEY);
}

function announce(message) {
  elements.liveRegion.textContent = message;
}

function formatElapsed(totalSeconds) {
  const safeSeconds = Math.max(0, Number(totalSeconds) || 0);
  const minutes = String(Math.floor(safeSeconds / 60)).padStart(2, "0");
  const seconds = String(safeSeconds % 60).padStart(2, "0");
  return `${minutes}:${seconds}`;
}

function formatDate(value, includesTime = false) {
  if (!value) return "尚未确认";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "尚未确认";
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "long",
    day: "numeric",
    ...(includesTime ? { hour: "2-digit", minute: "2-digit" } : {})
  }).format(date);
}

async function api(path, options = {}) {
  const headers = {
    "Content-Type": "application/json",
    ...(options.headers || {})
  };
  const token = sessionToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(path, {
    method: options.method || "GET",
    headers,
    body: options.body ? JSON.stringify(options.body) : undefined,
    cache: "no-store"
  });
  const contentType = response.headers.get("content-type") || "";
  const payload = contentType.includes("application/json")
    ? await response.json()
    : { message: await response.text() };
  if (!response.ok) {
    const error = new Error(payload.message || "请求未完成。");
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

function stopPolling() {
  if (pollTimer) window.clearInterval(pollTimer);
  pollTimer = null;
}

function setLoginError(message) {
  const showsError = Boolean(message);
  elements.loginError.hidden = !showsError;
  elements.loginErrorText.textContent = message;
  elements.passwordField.classList.toggle("is-invalid", showsError);
  if (showsError) {
    elements.password.setAttribute("aria-invalid", "true");
  } else {
    elements.password.removeAttribute("aria-invalid");
  }
}

function showLogin(message = "") {
  stopPolling();
  closeProfileChoice({ restoreFocus: false });
  elements.appHeader.hidden = true;
  elements.viewControl.hidden = true;
  elements.viewLogin.hidden = false;
  elements.pairedNotice.hidden = true;
  elements.password.value = "";
  setLoginError(message);
  window.setTimeout(() => elements.password.focus(), 80);
}

function showControl() {
  elements.viewLogin.hidden = true;
  elements.viewControl.hidden = false;
  elements.appHeader.hidden = false;
  elements.pairedNotice.hidden = !enteredByPairing;
  elements.footerAddress.textContent = window.location.host;
}

function showState(name, focusSelector) {
  for (const [key, node] of Object.entries(elements.states)) {
    node.hidden = key !== name;
  }
  if (focusSelector) {
    const target = elements.states[name].querySelector(focusSelector);
    if (target) window.setTimeout(() => target.focus(), 60);
  }
}

function renderStages(snapshot) {
  const phaseIndex = Number.isInteger(snapshot.phaseIndex)
    ? snapshot.phaseIndex
    : 0;
  elements.stageList.replaceChildren();
  snapshot.phases.forEach((phase, index) => {
    const item = document.createElement("li");
    item.className = "stage-item";
    if (index < phaseIndex) item.classList.add("is-complete");
    if (index === phaseIndex) item.classList.add("is-current");
    const dot = document.createElement("span");
    dot.className = "stage-dot";
    dot.setAttribute("aria-hidden", "true");
    const label = document.createElement("span");
    label.textContent = phase;
    item.append(dot, label);
    elements.stageList.append(item);
  });
  elements.stageCount.textContent =
    `第 ${Math.min(phaseIndex + 1, snapshot.phases.length)} 阶段 · 共 ${snapshot.phases.length} 阶段`;
}

function renderSnapshot(snapshot) {
  latestSnapshot = snapshot;
  elements.targetApp.textContent = snapshot.appName;
  elements.targetDevice.textContent = snapshot.deviceName;
  elements.deviceStatus.textContent = snapshot.deviceStatus;
  const statusTones = ["good", "warning", "critical", "info", "neutral"];
  const statusTone = statusTones.includes(snapshot.deviceStatusTone)
    ? snapshot.deviceStatusTone
    : "neutral";
  for (const tone of statusTones) {
    elements.deviceStatusContainer.classList.remove(`status-${tone}`);
  }
  elements.deviceStatusContainer.classList.add(`status-${statusTone}`);
  elements.expiryValue.textContent = snapshot.signatureStatus;
  elements.lastChecked.textContent = formatDate(snapshot.checkedAt, true);
  elements.renewButton.disabled = !snapshot.canRenew;
  elements.recheckButton.disabled = !snapshot.canRecheck;
  elements.retryButton.disabled = !snapshot.canRenew;
  elements.failureRecheck.disabled = !snapshot.canRecheck;

  switch (snapshot.pageState) {
    case "checking":
      showState("checking", "#checking-title");
      break;
    case "progress":
      elements.progressLede.textContent =
        `正在为 ${snapshot.appName} 续签并安装到 ${snapshot.deviceName}。${snapshot.message}`;
      elements.elapsed.textContent = formatElapsed(snapshot.elapsedSeconds);
      renderStages(snapshot);
      showState("progress", "#progress-title");
      break;
    case "success":
      elements.successLede.textContent =
        `${snapshot.appName} 已重新签名并安装到 ${snapshot.deviceName}。`;
      elements.successExpiry.textContent = formatDate(snapshot.expectedExpiryAt);
      elements.successElapsed.textContent = formatElapsed(snapshot.elapsedSeconds);
      showState("success", "#success-title");
      break;
    case "failure":
      elements.failureLede.textContent = "本次续签未能完成。";
      elements.failureReason.textContent = snapshot.message;
      elements.failureStage.textContent = "请在 Mac 上查看详情";
      elements.failureElapsed.textContent = formatElapsed(snapshot.elapsedSeconds);
      showState("failure", "#failure-title");
      break;
    case "unavailable":
      elements.readyTitle.textContent = "暂不可用";
      elements.readyLede.textContent = snapshot.message;
      showState("ready", "#ready-title");
      break;
    case "ready":
    default:
      elements.readyTitle.textContent = snapshot.signatureStatus.startsWith("已过期")
        ? "签名已过期"
        : "签名状态";
      elements.readyLede.textContent =
        `${snapshot.appName} 在 ${snapshot.deviceName} 上：${snapshot.message}`;
      showState("ready", "#ready-title");
      break;
  }
}

async function refreshStatus({ announceFailure = false } = {}) {
  try {
    const snapshot = await api("/api/status");
    showControl();
    renderSnapshot(snapshot);
  } catch (error) {
    if (error.status === 401) {
      sessionStorage.removeItem(SESSION_KEY);
      showLogin("会话已失效，请重新登录。");
      return;
    }
    if (announceFailure) announce("状态更新失败，请稍后重试。");
  }
}

function startPolling() {
  stopPolling();
  pollTimer = window.setInterval(() => refreshStatus(), POLL_INTERVAL_MS);
}

async function handleLogin(event) {
  event.preventDefault();
  setLoginError("");
  try {
    const session = await api("/api/login", {
      method: "POST",
      body: { password: elements.password.value }
    });
    sessionStorage.setItem(SESSION_KEY, session.token);
    await refreshStatus({ announceFailure: true });
    startPolling();
  } catch (error) {
    setLoginError(error.message || "密码不正确，请检查后重试。");
    elements.password.focus();
  }
}

async function consumePairingToken(token) {
  try {
    const session = await api("/api/pair", {
      method: "POST",
      body: { token }
    });
    sessionStorage.setItem(SESSION_KEY, session.token);
    enteredByPairing = true;
    window.history.replaceState(
      {},
      "",
      `${window.location.pathname}${window.location.hash}`
    );
    await refreshStatus({ announceFailure: true });
    startPolling();
  } catch (error) {
    window.history.replaceState(
      {},
      "",
      `${window.location.pathname}${window.location.hash}`
    );
    showLogin(error.message || "二维码已失效，请重新生成。");
  }
}

async function performAction(path) {
  try {
    const outcome = await api(path, { method: "POST" });
    announce(outcome.message);
    await refreshStatus({ announceFailure: true });
  } catch (error) {
    if (error.status === 401) {
      sessionStorage.removeItem(SESSION_KEY);
      showLogin("会话已失效，请重新登录。");
      return;
    }
    announce(error.message || "操作未完成。");
    if (latestSnapshot?.pageState === "failure") {
      elements.failureReason.textContent = error.message;
    } else {
      elements.readyLede.textContent = error.message;
    }
  }
}

function setProfileChoiceSubmitting(isSubmitting) {
  profileChoiceSubmitting = isSubmitting;
  elements.profileChoiceSheet.setAttribute("aria-busy", String(isSubmitting));
  elements.profileForce.disabled = isSubmitting;
  elements.profileAutomatic.disabled = isSubmitting;
  elements.profileCancel.disabled = isSubmitting;
}

function openProfileChoice(message) {
  profileChoiceReturnFocus = document.activeElement;
  elements.profileChoiceMessage.textContent = message;
  elements.profileChoice.hidden = false;
  document.body.classList.add("modal-open");
  setProfileChoiceSubmitting(false);
  announce("请选择本次签名策略。");
  window.setTimeout(() => elements.profileForce.focus(), 60);
}

function closeProfileChoice({ restoreFocus = true } = {}) {
  if (elements.profileChoice.hidden) return;
  elements.profileChoice.hidden = true;
  document.body.classList.remove("modal-open");
  setProfileChoiceSubmitting(false);
  if (restoreFocus && profileChoiceReturnFocus?.isConnected) {
    profileChoiceReturnFocus.focus();
  }
  profileChoiceReturnFocus = null;
}

function showActionError(error) {
  announce(error.message || "操作未完成。");
  if (latestSnapshot?.pageState === "failure") {
    elements.failureReason.textContent = error.message;
  } else {
    elements.readyLede.textContent = error.message;
  }
}

async function performRenew(profileRefreshMode = null) {
  if (profileRefreshMode) setProfileChoiceSubmitting(true);
  try {
    const outcome = await api("/api/renew", {
      method: "POST",
      body: profileRefreshMode ? { profileRefreshMode } : undefined
    });
    closeProfileChoice({ restoreFocus: false });
    announce(outcome.message);
    await refreshStatus({ announceFailure: true });
  } catch (error) {
    if (error.status === 401) {
      sessionStorage.removeItem(SESSION_KEY);
      showLogin("会话已失效，请重新登录。");
      return;
    }
    if (error.payload?.requiresProfileChoice && !profileRefreshMode) {
      openProfileChoice(error.message);
      return;
    }
    closeProfileChoice();
    showActionError(error);
  } finally {
    if (!elements.profileChoice.hidden) {
      setProfileChoiceSubmitting(false);
    }
  }
}

function handleProfileChoiceKeydown(event) {
  if (event.key === "Escape" && !profileChoiceSubmitting) {
    event.preventDefault();
    closeProfileChoice();
    return;
  }
  if (event.key !== "Tab") return;
  const focusable = [
    elements.profileForce,
    elements.profileAutomatic,
    elements.profileCancel
  ].filter((element) => !element.disabled);
  if (focusable.length === 0) {
    event.preventDefault();
    return;
  }
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first.focus();
  }
}

function togglePasswordVisibility() {
  const reveals = elements.password.type === "password";
  elements.password.type = reveals ? "text" : "password";
  elements.togglePassword.setAttribute(
    "aria-label",
    reveals ? "隐藏密码" : "显示密码"
  );
  elements.togglePassword.setAttribute("aria-pressed", String(reveals));
  elements.togglePasswordUse.setAttribute(
    "href",
    reveals ? "#i-eye-off" : "#i-eye"
  );
}

async function logout() {
  try {
    await api("/api/logout", { method: "POST" });
  } catch (_) {
    // 本地会话仍需立即清除。
  }
  sessionStorage.removeItem(SESSION_KEY);
  enteredByPairing = false;
  showLogin();
}

elements.loginForm.addEventListener("submit", handleLogin);
elements.password.addEventListener("input", () => setLoginError(""));
elements.togglePassword.addEventListener("click", togglePasswordVisibility);
elements.exitButton.addEventListener("click", logout);
elements.renewButton.addEventListener("click", () => performRenew());
elements.recheckButton.addEventListener("click", () => performAction("/api/recheck"));
elements.successDone.addEventListener("click", () => performAction("/api/dismiss-result"));
elements.retryButton.addEventListener("click", () => performRenew());
elements.failureRecheck.addEventListener("click", () => performAction("/api/recheck"));
elements.profileForce.addEventListener("click", () => performRenew("force"));
elements.profileAutomatic.addEventListener("click", () => performRenew("auto"));
elements.profileCancel.addEventListener("click", () => closeProfileChoice());
elements.profileChoice.addEventListener("click", (event) => {
  if (event.target === elements.profileChoice && !profileChoiceSubmitting) {
    closeProfileChoice();
  }
});
elements.profileChoiceSheet.addEventListener("keydown", handleProfileChoiceKeydown);

if (pairingToken) {
  consumePairingToken(pairingToken);
} else if (sessionToken()) {
  refreshStatus({ announceFailure: true }).then(startPolling);
} else {
  showLogin();
}
