// Framework-independent browser SDK for a Waymote streaming gateway.
const headerSize = 40;
const automaticResizeAlignment = 16;
const minimumOutputWidth = 320;
const maximumOutputWidth = 6000;
const minimumOutputHeight = 180;
const maximumOutputHeight = 6000;
const maximumOutputPixels = maximumOutputWidth * maximumOutputHeight;
const defaultAutomaticOutputPixels = 3840 * 2160;

function fitObservedResize(rawWidth, rawHeight, policy = {}) {
  const minWidth = Math.min(maximumOutputWidth, policy.minWidth ?? minimumOutputWidth);
  const minHeight = Math.min(maximumOutputHeight, policy.minHeight ?? minimumOutputHeight);
  const maxWidth = Math.max(minWidth, Math.min(maximumOutputWidth,
    policy.maxWidth ?? maximumOutputWidth));
  const maxHeight = Math.max(minHeight, Math.min(maximumOutputHeight,
    policy.maxHeight ?? maximumOutputHeight));
  const maxPixels = Math.min(maximumOutputPixels,
    policy.maxPixels ?? defaultAutomaticOutputPixels);
  if (minWidth * minHeight > maxPixels) {
    throw new RangeError("Remote display minimum size exceeds maxPixels");
  }
  const downscale = Math.min(
    1,
    maxWidth / rawWidth,
    maxHeight / rawHeight,
    Math.sqrt(maxPixels / (rawWidth * rawHeight)),
  );
  // Keep automatic video sizes on macroblock boundaries. Besides being broadly
  // decoder-friendly, this prevents one- or two-pixel scrollbar/layout changes
  // caused by presenting a resized frame from triggering an endless resize and
  // encoder-restart loop.
  const width = Math.max(minWidth, Math.min(maxWidth,
    Math.floor(rawWidth * downscale / automaticResizeAlignment) * automaticResizeAlignment));
  const height = Math.max(minHeight, Math.min(maxHeight,
    Math.floor(rawHeight * downscale / automaticResizeAlignment) * automaticResizeAlignment));
  return Object.freeze({ width, height, downscale });
}

function normalizeResizeDimensions(width, height) {
  return Object.freeze({
    width: Math.max(minimumOutputWidth,
      Math.min(maximumOutputWidth, Math.round(width / 2) * 2)),
    height: Math.max(minimumOutputHeight,
      Math.min(maximumOutputHeight, Math.round(height / 2) * 2)),
  });
}

function createRuntime(owner, options) {
let display = null;
let inputElement = null;
let imeProxy = null;
let context = null;
let surfaceCleanup = [];
let resizeObserver = null;
let feedbackTimer = null;
let clipboardAutoSync = false;
let sessionConnected = false;
let sessionDisposed = false;
let connectionGeneration = 0;
let surfaceDisposer = null;
let disposePromise = null;

let decoder = null;
let videoSocket = null;
const pendingFrames = [];
let animationPending = false;
let animationFrame = null;
let presentationTimer = null;
let renderedFrames = 0;
let reconnectDelay = 250;
let videoReconnectTimer = null;
let videoConnectAttempt = null;
let decoderConfiguration = null;
let waitingForKeyframe = true;
let decoderGeneration = 0;
let receivedChunks = 0;
let receivedKeyframes = 0;
const renderedFrameTimes = [];

const audioHeaderSize = 24;
let audioSocket = null;
let audioReconnectDelay = 250;
let audioReconnectTimer = null;
let audioConnectAttempt = null;
let audioConfiguration = null;
let audioDecoder = null;
let audioDecoderSetupGeneration = 0;
let audioContext = null;
let audioPlayer = null;
let audioGain = null;
let audioWanted = false;
let audioStarting = false;
let audioMuted = false;
let audioVolume = 1;
let audioGeneration = 0;
let audioUnderflows = 0;
let audioQueuedFrames = 0;
let audioScheduled = false;
let audioVideoSkew = null;
let audioScheduledEndFrame = null;

const clockMaximumAgeMilliseconds = 5000;
let targetLatencyMilliseconds = Number(options.latency ?? 60);
let clockOffsetMicros = null;
let clockBestRTT = Number.POSITIVE_INFINITY;
let clockSampleCount = 0;
let clockLastSample = 0;
let videoLateness = 0;
let lastVideoCaptureMicros = null;
let lastVideoPresentation = 0;
if (!Number.isFinite(targetLatencyMilliseconds) || targetLatencyMilliseconds < 0) {
  throw new RangeError("Latency must be a non-negative number");
}

const controlRecordSize = 16;
const pointerExtent = 65_535;
const controlPointerMotion = 1;
const controlPointerButton = 2;
const controlPointerScroll = 3;
const controlKeyboardKey = 4;
const controlReleaseAll = 5;
const controlResize = 6;
const controlPointerRelative = 8;
const maximumClipboardBytes = 1024 * 1024;
const clipboardCopyTimeoutMilliseconds = 2000;
const keyReleased = 0;
const keyPressed = 1;
const keyRepeated = 2;
const linuxPointerButtons = [0x110, 0x112, 0x111, 0x113, 0x114];
const linuxKeyCodes = new Map([
  ["Escape", 1],
  ["Digit1", 2], ["Digit2", 3], ["Digit3", 4], ["Digit4", 5],
  ["Digit5", 6], ["Digit6", 7], ["Digit7", 8], ["Digit8", 9],
  ["Digit9", 10], ["Digit0", 11], ["Minus", 12], ["Equal", 13],
  ["Backspace", 14], ["Tab", 15],
  ["KeyQ", 16], ["KeyW", 17], ["KeyE", 18], ["KeyR", 19],
  ["KeyT", 20], ["KeyY", 21], ["KeyU", 22], ["KeyI", 23],
  ["KeyO", 24], ["KeyP", 25], ["BracketLeft", 26], ["BracketRight", 27],
  ["Enter", 28], ["ControlLeft", 29],
  ["KeyA", 30], ["KeyS", 31], ["KeyD", 32], ["KeyF", 33],
  ["KeyG", 34], ["KeyH", 35], ["KeyJ", 36], ["KeyK", 37],
  ["KeyL", 38], ["Semicolon", 39], ["Quote", 40], ["Backquote", 41],
  ["ShiftLeft", 42], ["Backslash", 43],
  ["KeyZ", 44], ["KeyX", 45], ["KeyC", 46], ["KeyV", 47],
  ["KeyB", 48], ["KeyN", 49], ["KeyM", 50], ["Comma", 51],
  ["Period", 52], ["Slash", 53], ["ShiftRight", 54], ["NumpadMultiply", 55],
  ["AltLeft", 56], ["Space", 57], ["CapsLock", 58],
  ["F1", 59], ["F2", 60], ["F3", 61], ["F4", 62], ["F5", 63],
  ["F6", 64], ["F7", 65], ["F8", 66], ["F9", 67], ["F10", 68],
  ["NumLock", 69], ["ScrollLock", 70],
  ["Numpad7", 71], ["Numpad8", 72], ["Numpad9", 73], ["NumpadSubtract", 74],
  ["Numpad4", 75], ["Numpad5", 76], ["Numpad6", 77], ["NumpadAdd", 78],
  ["Numpad1", 79], ["Numpad2", 80], ["Numpad3", 81], ["Numpad0", 82],
  ["NumpadDecimal", 83], ["IntlBackslash", 86], ["F11", 87], ["F12", 88],
  ["NumpadEnter", 96], ["ControlRight", 97], ["NumpadDivide", 98],
  ["PrintScreen", 99], ["AltRight", 100], ["Home", 102], ["ArrowUp", 103],
  ["PageUp", 104], ["ArrowLeft", 105], ["ArrowRight", 106], ["End", 107],
  ["ArrowDown", 108], ["PageDown", 109], ["Insert", 110], ["Delete", 111],
  ["AudioVolumeMute", 113], ["AudioVolumeDown", 114], ["AudioVolumeUp", 115],
  ["Power", 116], ["NumpadEqual", 117], ["Pause", 119],
  ["MetaLeft", 125], ["MetaRight", 126], ["ContextMenu", 127],
  ["BrowserStop", 128], ["Again", 129], ["Props", 130], ["Undo", 131],
  ["Copy", 133], ["Open", 134], ["Paste", 135], ["Find", 136], ["Cut", 137],
  ["Help", 138], ["Menu", 139], ["Sleep", 142], ["WakeUp", 143],
  ["BrowserFavorites", 156], ["BrowserBack", 158], ["BrowserForward", 159],
  ["Eject", 161], ["MediaTrackNext", 163], ["MediaPlayPause", 164],
  ["MediaTrackPrevious", 165], ["MediaStop", 166], ["BrowserRefresh", 173],
  ["BrowserHome", 172], ["F13", 183], ["F14", 184], ["F15", 185],
  ["F16", 186], ["F17", 187], ["F18", 188], ["F19", 189],
  ["F20", 190], ["F21", 191], ["F22", 192], ["F23", 193], ["F24", 194],
]);

let controlSocket = null;
let controlReconnectDelay = 250;
let controlReconnectTimer = null;
let controlStableTimer = null;
let controlConnectAttempt = null;
let controlAcquireDelay = 250;
let controlAcquireTimer = null;
let controlActive = false;
let controlWanted = false;
let pendingPointerPosition = null;
let pointerAnimationPending = false;
let pointerAnimationFrame = null;
let pendingControlRecords = [];
let resizeTimer = null;
let resizePending = false;
let lastResizeRequest = null;
let resizeRequestID = 0;
let qualityBitrate = 0;
let qualityScale = 100;
let remoteClipboard = null;
let clipboardPastePending = false;
let pendingClipboardCopy = null;
let shortcutClipboardCopy = null;
let inputSequence = 0;
let currentGeneration = 0;
let latestAppliedInput = 0;
let droppedFrames = 0;
let intervalChunks = 0;
let rtt = 0;
let pingID = 0;
const pings = new Map();
const resizeRequests = new Map();
let resizeState = "idle";
const pressedKeys = new Set();
const pressedButtons = new Set();
let physicalTextPending = false;
let suppressCompositionText = null;
let compositionTimer = null;
function emit(type, value) {
  owner.emit(type, value);
}

function websocketURL(path) {
  const url = new URL(path, options.endpoint ?? location.origin);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url;
}

async function createWebSocket(path) {
  const url = websocketURL(path);
  const socket = options.createWebSocket
    ? await options.createWebSocket(path, url)
    : new WebSocket(url);
  if (!socket || typeof socket.addEventListener !== "function" || typeof socket.close !== "function") {
    throw new TypeError("createWebSocket must return a WebSocket-compatible object");
  }
  return socket;
}

function setStatus(text, connected = false) {
  const state = connected ? "connected" : text.startsWith("Reconnecting")
    ? "reconnecting" : text.includes("connecting") || text === "Connecting"
      ? "connecting" : text.includes("error") || text.includes("unavailable")
        ? "error" : "disconnected";
  owner.updateState("video", { state, message: text });
}

function setControlStatus(text, connected = false) {
  const state = text === "Input active" ? "active" : text.includes("requesting")
    ? "requesting" : text.includes("use") ? "busy" : text.includes("ready")
      ? "ready" : text.includes("connecting") || text.includes("reconnecting")
        ? "connecting" : "disconnected";
  owner.updateState("input", { state, message: text, connected });
}

function setClipboardStatus(text) {
  emit("clipboard", Object.freeze({ text: remoteClipboard, status: text }));
}

function setAudioStatus(text) {
  const state = text === "Audio active" ? "active" : text === "Audio ready"
    ? "ready" : text.includes("unavailable") || text.includes("disabled") ? "unavailable"
      : text.includes("error") || text.includes("denied") ? "error"
        : text.includes("muted") ? "muted" : text.includes("disconnected")
          ? "disconnected" : "connecting";
  owner.updateState("audio", {
    state,
    message: text,
    available: Boolean(audioConfiguration?.enabled),
    muted: audioMuted,
  });
}

function clockSynchronized() {
  return clockOffsetMicros !== null && clockSampleCount >= 2 &&
    performance.now() - clockLastSample <= clockMaximumAgeMilliseconds;
}

function updateClock(sent, received, serverNanos) {
  const serverMicros = Number(serverNanos) / 1000;
  const sampleRTT = received - sent;
  if (!Number.isFinite(serverMicros) || serverMicros < 0 ||
      !Number.isFinite(sampleRTT) || sampleRTT < 0 || sampleRTT > 60_000) {
    return;
  }
  const candidateOffset = (sent + received) * 500 - serverMicros;
  if (clockOffsetMicros === null || received - clockLastSample > 30_000) {
    clockOffsetMicros = candidateOffset;
    clockBestRTT = sampleRTT;
    clockSampleCount = 1;
    clockLastSample = received;
  } else if (sampleRTT <= clockBestRTT + Math.max(2, clockBestRTT * 0.25)) {
    const correction = candidateOffset - clockOffsetMicros;
    clockOffsetMicros += Math.abs(correction) > 100_000 ? correction : correction * 0.1;
    clockBestRTT = Math.min(clockBestRTT, sampleRTT);
    clockSampleCount += 1;
    clockLastSample = received;
  }
}

function expectedPresentationTime(captureMicros) {
  if (!clockSynchronized() || !Number.isFinite(captureMicros)) {
    return null;
  }
  return (captureMicros + clockOffsetMicros) / 1000 + targetLatencyMilliseconds;
}

function resetAudioPlayer() {
  audioScheduledEndFrame = null;
  audioPlayer?.port.postMessage({ type: "reset" });
}

function audioStartFrame(captureMicros, frameCount) {
  const presentation = expectedPresentationTime(captureMicros);
  const outputTimestamp = audioContext?.getOutputTimestamp?.();
  if (presentation === null || !outputTimestamp ||
      !Number.isFinite(outputTimestamp.contextTime) ||
      !Number.isFinite(outputTimestamp.performanceTime) ||
      outputTimestamp.contextTime === 0 && outputTimestamp.performanceTime === 0) {
    audioScheduledEndFrame = null;
    return null;
  }
  const contextTime = outputTimestamp.contextTime +
    (presentation - outputTimestamp.performanceTime) / 1000;
  const scheduledFrame = Math.round(contextTime * audioConfiguration.sampleRate);
  const earliestFrame = Math.ceil((audioContext.currentTime + 0.01) * audioConfiguration.sampleRate);
  if (audioScheduledEndFrame !== null &&
      audioScheduledEndFrame - earliestFrame > audioConfiguration.sampleRate * 0.2) {
    audioScheduledEndFrame = null;
  }
  const startFrame = Math.max(scheduledFrame, earliestFrame, audioScheduledEndFrame ?? 0);
  if (startFrame > earliestFrame + audioConfiguration.sampleRate) {
    audioScheduledEndFrame = null;
    return null;
  }
  audioScheduledEndFrame = startFrame + frameCount;
  return startFrame;
}

function closeAudioDecoder() {
  if (audioDecoder) {
    audioDecoder.close();
    audioDecoder = null;
  }
}

async function configureAudioDecoder() {
  if (!audioWanted || !audioPlayer || !audioConfiguration?.enabled || !("AudioDecoder" in window)) {
    return;
  }
  const setupGeneration = ++audioDecoderSetupGeneration;
  const sourceConfiguration = audioConfiguration;
  const configuration = {
    codec: sourceConfiguration.codec,
    sampleRate: sourceConfiguration.sampleRate,
    numberOfChannels: sourceConfiguration.channels,
  };
  let support;
  try {
    support = await AudioDecoder.isConfigSupported(configuration);
  } catch (error) {
    if (setupGeneration !== audioDecoderSetupGeneration || sessionDisposed || !sessionConnected) return;
    throw error;
  }
  if (setupGeneration !== audioDecoderSetupGeneration || sessionDisposed || !sessionConnected ||
      audioConfiguration !== sourceConfiguration) return;
  if (!support.supported || !audioWanted) {
    setAudioStatus("Opus decoding unavailable");
    return;
  }
  closeAudioDecoder();
  const configuredDecoder = new AudioDecoder({
    output(frame) {
      const channels = [];
      try {
        for (let index = 0; index < frame.numberOfChannels; index += 1) {
          const samples = new Float32Array(frame.numberOfFrames);
          frame.copyTo(samples, { planeIndex: index, format: "f32-planar" });
          channels.push(samples);
        }
        if (channels.length === 1) {
          channels.push(channels[0].slice());
        }
        const captureTimestamp = frame.timestamp;
        const startFrame = audioStartFrame(captureTimestamp, frame.numberOfFrames);
        const transfers = channels.map((channel) => channel.buffer);
        audioPlayer.port.postMessage({
          type: "samples",
          channels,
          captureTimestamp,
          startFrame,
        }, transfers);
      } finally {
        frame.close();
      }
    },
    error(error) {
      console.warn("audio decoder error", error);
      if (audioDecoder === configuredDecoder) {
        audioDecoder = null;
      }
      resetAudioPlayer();
      setAudioStatus("Audio decoder error");
    },
  });
  configuredDecoder.configure(configuration);
  audioDecoder = configuredDecoder;
  setAudioStatus("Audio active");
}

async function enableAudio() {
  if (sessionDisposed) {
    throw new Error("The session has been disposed");
  }
  if (options.audio === false) {
    setAudioStatus("Audio disabled");
    return;
  }
  if (audioStarting) {
    return;
  }
  if (!audioConfiguration?.enabled) {
    setAudioStatus("Session audio unavailable");
    return;
  }
  audioStarting = true;
  setAudioStatus("Audio starting");
  try {
    if (!audioContext) {
      const context = new AudioContext({ latencyHint: "interactive", sampleRate: audioConfiguration.sampleRate });
      audioContext = context;
      const audioWorkletURL = options.audioWorkletURL ??
        new URL("./audio-player.js", import.meta.url);
      await context.audioWorklet.addModule(audioWorkletURL);
      if (sessionDisposed || audioContext !== context) return;
      audioPlayer = new AudioWorkletNode(context, "waymote-audio-player", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2],
      });
      audioGain = context.createGain();
      audioPlayer.connect(audioGain).connect(context.destination);
      audioPlayer.port.onmessage = (event) => {
        if (event.data?.type === "underflow") {
          audioUnderflows = event.data.underflows;
        }
        if (event.data?.type === "status" || event.data?.type === "resync") {
          audioQueuedFrames = event.data.queuedFrames;
        }
        if (event.data?.type === "status") {
          audioScheduled = event.data.scheduled;
          const outputTimestamp = audioContext?.getOutputTimestamp?.();
          if (Number.isFinite(event.data.captureTimestamp) &&
              Number.isFinite(event.data.captureFrame) && outputTimestamp &&
              Number.isFinite(outputTimestamp.contextTime) &&
              Number.isFinite(outputTimestamp.performanceTime) &&
              lastVideoCaptureMicros !== null &&
              performance.now() - lastVideoPresentation < 500) {
            const audioPresentation = outputTimestamp.performanceTime +
              (event.data.captureFrame / audioConfiguration.sampleRate -
                outputTimestamp.contextTime) * 1000;
            const audioAtVideoPresentation = event.data.captureTimestamp +
              (lastVideoPresentation - audioPresentation) * 1000;
            audioVideoSkew = (audioAtVideoPresentation - lastVideoCaptureMicros) / 1000;
          } else {
            audioVideoSkew = null;
          }
        }
      };
    }
    audioWanted = true;
    audioMuted = false;
    audioGain.gain.value = audioVolume;
    await audioContext.resume();
    if (sessionDisposed) return;
    await configureAudioDecoder();
  } catch (error) {
    if (!sessionDisposed) throw error;
  } finally {
    audioStarting = false;
    if (!sessionDisposed && !audioConfiguration?.enabled) setAudioStatus("Session audio unavailable");
  }
}

function sendClipboardText(text) {
  if (new TextEncoder().encode(text).byteLength > maximumClipboardBytes) {
    setClipboardStatus("Clipboard is too large");
    return false;
  }
  if (!controlActive || !controlSocket || controlSocket.readyState !== WebSocket.OPEN) {
    setClipboardStatus("Clipboard needs input control");
    return false;
  }
  controlSocket.send(JSON.stringify({ type: "clipboard-write", text }));
  setClipboardStatus("Local clipboard sent");
  return true;
}

async function sendLocalClipboard() {
  if (!navigator.clipboard?.readText) {
    throw new Error("Clipboard read is unavailable");
  }
  const text = await navigator.clipboard.readText();
  if (sessionDisposed) return false;
  if (!sendClipboardText(text)) {
    throw new Error("Clipboard control is inactive");
  }
  return true;
}

function copyTextFallback(text) {
  let handled = false;
  const handleCopy = (event) => {
    if (!event.clipboardData) {
      return;
    }
    event.clipboardData.setData("text/plain", text);
    event.preventDefault();
    handled = true;
  };
  document.addEventListener("copy", handleCopy);
  const copied = document.execCommand("copy");
  document.removeEventListener("copy", handleCopy);
  return copied && handled;
}

function reserveRemoteClipboardCopy() {
  if (!navigator.clipboard?.write || typeof ClipboardItem === "undefined" || pendingClipboardCopy) {
    return false;
  }

  let resolveText;
  let rejectText;
  const text = new Promise((resolve, reject) => {
    resolveText = resolve;
    rejectText = reject;
  });
  const transaction = {
    resolve: resolveText,
    reject: rejectText,
    timeout: null,
  };
  pendingClipboardCopy = transaction;
  transaction.timeout = setTimeout(() => {
    if (pendingClipboardCopy !== transaction) {
      return;
    }
    pendingClipboardCopy = null;
    transaction.reject(new Error("Remote copy timed out"));
  }, clipboardCopyTimeoutMilliseconds);

  let write;
  try {
    write = navigator.clipboard.write([
      new ClipboardItem({
        "text/plain": text.then((value) => new Blob([value], { type: "text/plain" })),
      }),
    ]);
  } catch (error) {
    clearTimeout(transaction.timeout);
    pendingClipboardCopy = null;
    transaction.reject(error);
    return false;
  }
  write.then(
    () => {
      if (!sessionDisposed) setClipboardStatus("Remote clipboard copied");
    },
    (error) => {
      if (sessionDisposed) return;
      if (pendingClipboardCopy === transaction) {
        clearTimeout(transaction.timeout);
        pendingClipboardCopy = null;
        transaction.reject(error);
      }
      console.warn("remote shortcut copy failed", error);
      setClipboardStatus("Remote clipboard ready");
    },
  );
  return true;
}

function armShortcutClipboardCopy() {
  if (shortcutClipboardCopy) {
    clearTimeout(shortcutClipboardCopy.timeout);
  }
  const transaction = {
    available: false,
    text: "",
    timeout: null,
  };
  transaction.timeout = setTimeout(() => {
    if (shortcutClipboardCopy === transaction) {
      shortcutClipboardCopy = null;
    }
  }, clipboardCopyTimeoutMilliseconds);
  shortcutClipboardCopy = transaction;
}

function completeShortcutClipboardCopy() {
  const transaction = shortcutClipboardCopy;
  if (!transaction?.available || !copyTextFallback(transaction.text)) {
    return;
  }
  clearTimeout(transaction.timeout);
  shortcutClipboardCopy = null;
  setClipboardStatus("Remote clipboard copied");
}

function receiveRemoteClipboard(text) {
  remoteClipboard = text;
  setClipboardStatus(text.length === 0 ? "Remote clipboard empty" : "Remote clipboard ready");
  if (shortcutClipboardCopy) {
    shortcutClipboardCopy.text = text;
    shortcutClipboardCopy.available = true;
  }
  if (pendingClipboardCopy) {
    const transaction = pendingClipboardCopy;
    pendingClipboardCopy = null;
    clearTimeout(transaction.timeout);
    transaction.resolve(text);
    return;
  }
  if (text.length === 0) {
    return;
  }
  if (clipboardAutoSync && !document.hidden && document.hasFocus() && navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).then(
      () => setClipboardStatus("Clipboard synced"),
      () => setClipboardStatus("Remote clipboard ready"),
    );
  }
}

function shortcutModifiers(event) {
  const modifiers = [...pressedKeys].filter((key) =>
    key === 29 || key === 42 || key === 54 || key === 97 || key === 100 ||
    key === 125 || key === 126);
  if (event.ctrlKey && !modifiers.some((key) => key === 29 || key === 97)) {
    modifiers.push(29);
  }
  if (event.shiftKey && !modifiers.some((key) => key === 42 || key === 54)) {
    modifiers.push(42);
  }
  if (event.altKey && !modifiers.includes(56) && !modifiers.includes(100)) {
    modifiers.push(56);
  }
  if (event.metaKey && !modifiers.includes(125) && !modifiers.includes(126)) {
    modifiers.push(125);
  }
  return modifiers;
}

function tapRemoteKey(key, modifiers) {
  for (const modifier of modifiers) {
    sendControl(keyboardRecord(modifier, keyPressed));
  }
  sendControl(keyboardRecord(key, keyPressed));
  sendControl(keyboardRecord(key, keyReleased));
  for (const modifier of modifiers) {
    if (!pressedKeys.has(modifier)) {
      sendControl(keyboardRecord(modifier, keyReleased));
    }
  }
}

function updateControlStatus() {
  if (!controlSocket || controlSocket.readyState !== WebSocket.OPEN) {
    return;
  }
  if (controlActive) {
    setControlStatus("Input active", true);
  } else if (controlWanted) {
    setControlStatus("Input requesting");
  } else {
    setControlStatus("Input ready · click stream", true);
  }
}

function controlRecord(type, pressed = false, a = 0, b = 0, c = 0) {
  const record = new ArrayBuffer(controlRecordSize);
  const view = new DataView(record);
  view.setUint8(0, 2);
  view.setUint8(1, type);
  view.setUint8(2, pressed ? 1 : 0);
  view.setUint32(4, a, true);
  view.setUint32(8, b, true);
  view.setUint32(12, c, true);
  return record;
}

function scrollRecord(dx, dy) {
  const record = controlRecord(controlPointerScroll, false, 0, 0, nextInputSequence());
  const view = new DataView(record);
  view.setFloat32(4, dx, true);
  view.setFloat32(8, dy, true);
  return record;
}

function keyboardRecord(key, state) {
  const record = controlRecord(controlKeyboardKey, state === keyPressed, key, 0, nextInputSequence());
  new DataView(record).setUint8(2, state);
  return record;
}

function nextInputSequence() {
  inputSequence = (inputSequence + 1) >>> 0;
  if (inputSequence === 0) {
    inputSequence = 1;
  }
  return inputSequence;
}

function visibleContentBounds() {
  const bounds = display.getBoundingClientRect();
  const contentAspect = renderedFrames > 0 && display.width > 0 && display.height > 0
    ? display.width / display.height
    : 16 / 9;
  let width = bounds.width;
  let height = bounds.height;
  let left = bounds.left;
  let top = bounds.top;
  if (width / height > contentAspect) {
    width = height * contentAspect;
    left += (bounds.width - width) / 2;
  } else {
    height = width / contentAspect;
    top += (bounds.height - height) / 2;
  }
  return { width, height, left, top };
}

function sendResize() {
  if (!controlActive) {
    return;
  }
  const policy = owner.remoteDisplayPolicy();
  if (policy.mode === "manual") return;
  if (policy.mode === "fixed") {
    sendResizeDimensions(policy.width, policy.height, policy.scale * 120);
    return;
  }
  const observed = policy.element ?? display;
  if (!observed) return;
  const bounds = observed.getBoundingClientRect();
  if (bounds.width <= 0 || bounds.height <= 0) return;
  const dpr = policy.devicePixelRatio ?? window.devicePixelRatio ?? 1;
  const rawWidth = bounds.width * dpr;
  const rawHeight = bounds.height * dpr;
  const { width, height, downscale } = fitObservedResize(rawWidth, rawHeight, policy);
  const scale = Math.max(120, Math.min(480, Math.round(dpr * downscale * 120)));
  const previous = lastResizeRequest?.match(/^(\d+)x(\d+)@(\d+)$/);
  if (previous && Number(previous[3]) === scale &&
      Math.abs(Number(previous[1]) - width) <= automaticResizeAlignment * 2 &&
      Math.abs(Number(previous[2]) - height) <= automaticResizeAlignment * 2) {
    return;
  }
  sendResizeDimensions(width, height, scale);
}

function sendResizeDimensions(width, height, scale) {
  ({ width, height } = normalizeResizeDimensions(width, height));
  scale = Math.max(120, Math.min(480, Math.round(scale)));
  const request = `${width}x${height}@${scale}`;
  if (request === lastResizeRequest) {
    return;
  }
  resizeRequestID = (resizeRequestID + 1) & 0xffff;
  if (resizeRequestID === 0) {
    resizeRequestID = 1;
  }
  const packed = (resizeRequestID << 16) | scale;
  const record = controlRecord(controlResize, false, width, height, packed >>> 0);
  resizeRequests.set((packed >>> 16) & 0xffff, { requested: performance.now(), generation: 0 });
  resizeState = "requested";
  emit("resize", Object.freeze({ state: resizeState, width, height, scale: scale / 120 }));
  if (sendControl(record)) {
    lastResizeRequest = request;
  }
}

function flushResize() {
  resizeTimer = null;
  if (!resizePending) {
    return;
  }
  resizePending = false;
  sendResize();
}

function scheduleResize() {
  if (owner.remoteDisplayPolicy().mode !== "observe") return;
  if (resizeTimer === null) {
    sendResize();
    resizeTimer = setTimeout(flushResize, owner.remoteDisplayPolicy().debounceMs ?? 100);
    return;
  }
  resizePending = true;
}

function sendControl(record) {
  if (!controlSocket) {
    return false;
  }
  if (controlSocket.readyState === WebSocket.CONNECTING) {
    if (pendingControlRecords.length >= 64) {
      pendingControlRecords = [];
      controlSocket.close(4001, "input queue full");
      setControlStatus("Input overloaded");
      return false;
    }
    pendingControlRecords.push(record);
    return true;
  }
  if (controlSocket.readyState !== WebSocket.OPEN) {
    return false;
  }
  controlSocket.send(record);
  return true;
}

function releaseInput() {
  pendingPointerPosition = null;
  pressedKeys.clear();
  pressedButtons.clear();
  sendControl(controlRecord(controlReleaseAll, false, 0, 0, 0));
}

function requestControl() {
  controlWanted = true;
  if (controlAcquireTimer !== null) {
    clearTimeout(controlAcquireTimer);
    controlAcquireTimer = null;
  }
  if (sessionConnected) void connectControl();
  if (controlSocket && controlSocket.readyState === WebSocket.OPEN) {
    controlSocket.send("acquire");
    setControlStatus("Input requesting");
  }
}

function releaseControl() {
  controlWanted = false;
  controlActive = false;
  lastResizeRequest = null;
  if (controlAcquireTimer !== null) {
    clearTimeout(controlAcquireTimer);
    controlAcquireTimer = null;
  }
  releaseInput();
  pendingControlRecords = [];
  if (controlSocket && controlSocket.readyState === WebSocket.OPEN) {
    controlSocket.send("release");
    if (sessionConnected) setControlStatus("Input ready · click stream", true);
  } else if (sessionConnected) {
    setControlStatus("Input connecting");
  }
}

function retryControlAcquire() {
  if (!controlWanted || !controlSocket || controlSocket.readyState !== WebSocket.OPEN) {
    return;
  }
  controlSocket.send("acquire");
  controlAcquireDelay = Math.min(controlAcquireDelay * 2, 2000);
  controlAcquireTimer = setTimeout(retryControlAcquire, controlAcquireDelay);
}

async function connectControl() {
  if (!sessionConnected || document.hidden) return;
  if (controlReconnectTimer !== null) {
    clearTimeout(controlReconnectTimer);
    controlReconnectTimer = null;
  }
  if (controlSocket &&
      (controlSocket.readyState === WebSocket.CONNECTING || controlSocket.readyState === WebSocket.OPEN)) {
    return;
  }
  if (controlConnectAttempt) return;
  setControlStatus("Input connecting");
  const attempt = { generation: connectionGeneration };
  controlConnectAttempt = attempt;
  let socket;
  try {
    socket = await createWebSocket("/control");
  } catch (error) {
    if (controlConnectAttempt !== attempt) return;
    controlConnectAttempt = null;
    if (!sessionConnected || document.hidden || attempt.generation !== connectionGeneration) return;
    const failure = error instanceof Error ? error : new Error(String(error));
    emit("error", failure);
    setControlStatus(`Input reconnecting · ${failure.message}`);
    controlReconnectTimer = setTimeout(() => {
      controlReconnectTimer = null;
      void connectControl();
    }, controlReconnectDelay);
    controlReconnectDelay = Math.min(controlReconnectDelay * 2, 5000);
    return;
  }
  if (controlConnectAttempt !== attempt || !sessionConnected || document.hidden ||
      attempt.generation !== connectionGeneration) {
    if (controlConnectAttempt === attempt) controlConnectAttempt = null;
    socket.close(1000, "stale connection attempt");
    return;
  }
  controlConnectAttempt = null;
  socket.binaryType = "arraybuffer";
  controlSocket = socket;
  socket.addEventListener("open", () => {
    if (controlSocket !== socket) {
      socket.close();
      return;
    }
    if (controlWanted) {
      socket.send("acquire");
    }
    for (const record of pendingControlRecords) {
      sendControl(record);
    }
    pendingControlRecords = [];
    updateControlStatus();
    if (controlStableTimer !== null) clearTimeout(controlStableTimer);
    controlStableTimer = setTimeout(() => {
      controlStableTimer = null;
      if (controlSocket === socket && socket.readyState === WebSocket.OPEN) {
        controlReconnectDelay = 250;
      }
    }, 5000);
  });
  socket.addEventListener("message", (event) => {
    if (controlSocket !== socket || typeof event.data !== "string") {
      return;
    }
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      socket.close(1003, "invalid control state");
      return;
    }
    if (message.type !== "control-state") {
      if (message.type === "pong" && pings.has(message.id)) {
        const received = performance.now();
        const sent = pings.get(message.id);
        rtt = received - sent;
        pings.delete(message.id);
        updateClock(sent, received, message.serverNanos);
      }
      if (message.type === "resize-applied" && resizeRequests.has(message.request)) {
        const request = resizeRequests.get(message.request);
        request.generation = message.generation;
        const latencyMs = performance.now() - request.requested;
        resizeState = "applied";
        emit("resize", Object.freeze({
          state: resizeState,
          latencyMs,
          width: message.width,
          height: message.height,
          scale: message.scale / 120,
          generation: message.generation,
        }));
      }
      if (message.type === "clipboard" && typeof message.text === "string") {
        receiveRemoteClipboard(message.text);
      }
      if (message.type === "quality" && Number.isFinite(message.bitrate) &&
          Number.isFinite(message.scale)) {
        qualityBitrate = message.bitrate;
        qualityScale = message.scale;
        emit("quality", Object.freeze({
          bitrateKbps: qualityBitrate,
          frameRate: message.fps,
          scalePercent: qualityScale,
        }));
      }
      return;
    }
    const wasControlActive = controlActive;
    controlActive = message.state === "active";
    if (controlActive) {
      controlAcquireDelay = 250;
      if (controlAcquireTimer !== null) {
        clearTimeout(controlAcquireTimer);
        controlAcquireTimer = null;
      }
      if (!controlWanted) {
        controlActive = false;
        socket.send("release");
      } else if (!wasControlActive) {
        lastResizeRequest = null;
        sendResize();
      }
    } else if (message.state === "busy" && controlWanted) {
      lastResizeRequest = null;
      pendingPointerPosition = null;
      pressedKeys.clear();
      pressedButtons.clear();
      setControlStatus("Input in use");
      if (controlAcquireTimer === null) {
        controlAcquireTimer = setTimeout(retryControlAcquire, controlAcquireDelay);
      }
      return;
    } else if (message.state === "ready" && controlWanted) {
      lastResizeRequest = null;
      requestControl();
      return;
    }
    updateControlStatus();
  });
  socket.addEventListener("close", (event) => {
    if (controlSocket !== socket) {
      return;
    }
    controlSocket = null;
    controlActive = false;
    lastResizeRequest = null;
    pendingControlRecords = [];
    pressedKeys.clear();
    pressedButtons.clear();
    if (controlAcquireTimer !== null) {
      clearTimeout(controlAcquireTimer);
      controlAcquireTimer = null;
    }
    if (sessionConnected && !document.hidden) {
      setControlStatus(`Input reconnecting · ${event.code}`);
      controlReconnectTimer = setTimeout(() => {
        controlReconnectTimer = null;
        void connectControl();
      }, controlReconnectDelay);
      controlReconnectDelay = Math.min(controlReconnectDelay * 2, 5000);
    } else {
      setControlStatus("Input disconnected");
    }
  });
  socket.addEventListener("error", () => socket.close());
}

function contentPosition(event) {
  if (display.width === 0 || display.height === 0) {
    return null;
  }
  const { width, height, left, top } = visibleContentBounds();
  const x = (event.clientX - left) / width;
  const y = (event.clientY - top) / height;
  if (x < 0 || x > 1 || y < 0 || y > 1) {
    return null;
  }
  return {
    x: Math.round(x * pointerExtent),
    y: Math.round(y * pointerExtent),
  };
}

function queuePointerPosition(event) {
  if (document.pointerLockElement === display) {
    return;
  }
  pendingPointerPosition = contentPosition(event);
  if (!pendingPointerPosition || pointerAnimationPending) {
    return;
  }
  pointerAnimationPending = true;
  pointerAnimationFrame = requestAnimationFrame(() => {
    pointerAnimationFrame = null;
    pointerAnimationPending = false;
    const position = pendingPointerPosition;
    pendingPointerPosition = null;
    if (position) {
      sendControl(controlRecord(controlPointerMotion, false, position.x, position.y, nextInputSequence()));
    }
  });
}

function handleRelativePointerMove(event) {
  if (document.pointerLockElement !== display) return;
  const dx = Math.max(-4096, Math.min(4096, event.movementX));
  const dy = Math.max(-4096, Math.min(4096, event.movementY));
  const record = controlRecord(controlPointerRelative, false, 0, 0, nextInputSequence());
  const view = new DataView(record);
  view.setFloat32(4, dx, true);
  view.setFloat32(8, dy, true);
  sendControl(record);
}

function handlePointerLockChange() {
  owner.updateState("input", { pointerLocked: document.pointerLockElement === display });
  if (document.pointerLockElement !== display) releaseInput();
}

function handlePointerDown(event) {
  const locked = document.pointerLockElement === display;
  const position = locked ? null : contentPosition(event);
  if ((!locked && !position) || event.button < 0 || event.button > 4) {
    return;
  }
  inputElement.focus({ preventScroll: true });
  if (!locked) inputElement.setPointerCapture(event.pointerId);
  if (position) {
    sendControl(controlRecord(
      controlPointerMotion,
      false,
      position.x,
      position.y,
      nextInputSequence(),
    ));
  }
  if (!pressedButtons.has(event.button)) {
    pressedButtons.add(event.button);
    sendControl(controlRecord(controlPointerButton, true, linuxPointerButtons[event.button], 0, nextInputSequence()));
  }
  event.preventDefault();
}

function handlePointerUp(event) {
  queuePointerPosition(event);
  if (pressedButtons.delete(event.button)) {
    sendControl(controlRecord(controlPointerButton, false, linuxPointerButtons[event.button], 0, nextInputSequence()));
  }
  if (inputElement.hasPointerCapture(event.pointerId)) {
    inputElement.releasePointerCapture(event.pointerId);
  }
  event.preventDefault();
}

function handleWheel(event) {
  inputElement.focus({ preventScroll: true });
  const scale = event.deltaMode === WheelEvent.DOM_DELTA_LINE
    ? 16
    : event.deltaMode === WheelEvent.DOM_DELTA_PAGE ? display.clientHeight : 1;
  const dx = Math.max(-4096, Math.min(4096, event.deltaX * scale));
  const dy = Math.max(-4096, Math.min(4096, event.deltaY * scale));
  sendControl(scrollRecord(dx, dy));
  event.preventDefault();
}

function handleKeyDown(event) {
  if (event.isComposing || event.keyCode === 229) {
    return;
  }
  const key = linuxKeyCodes.get(event.code);
  if (key === undefined) {
    return;
  }
  if ((event.ctrlKey || event.metaKey) && event.code === "KeyV") {
    if (!event.repeat && !clipboardPastePending) {
      clipboardPastePending = true;
      const modifiers = shortcutModifiers(event);
      sendLocalClipboard().catch((error) => {
        if (!sessionDisposed) {
          console.warn("local clipboard sync failed", error);
          setClipboardStatus("Local clipboard unavailable");
        }
      }).finally(() => {
        if (!sessionDisposed) tapRemoteKey(key, modifiers);
        clipboardPastePending = false;
      });
    }
    event.preventDefault();
    event.stopPropagation();
    return;
  }
  if ((event.ctrlKey || event.metaKey) && event.shiftKey && event.code === "KeyC") {
    if (!event.repeat) {
      armShortcutClipboardCopy();
      reserveRemoteClipboardCopy();
      tapRemoteKey(key, shortcutModifiers(event));
    }
    event.preventDefault();
    event.stopPropagation();
    return;
  }
  if (!pressedKeys.has(key)) {
    pressedKeys.add(key);
    sendControl(keyboardRecord(key, keyPressed));
  } else if (event.repeat) {
    sendControl(keyboardRecord(key, keyRepeated));
  }
  physicalTextPending = event.key?.length === 1 && !event.ctrlKey && !event.metaKey;
  event.preventDefault();
  event.stopPropagation();
}

function handleKeyUp(event) {
  if (event.isComposing || event.keyCode === 229) {
    return;
  }
  const key = linuxKeyCodes.get(event.code);
  if (key === undefined) {
    return;
  }
  if (event.code === "KeyC" || event.code === "ShiftLeft" || event.code === "ShiftRight" ||
      event.code === "ControlLeft" || event.code === "ControlRight" ||
      event.code === "MetaLeft" || event.code === "MetaRight") {
    completeShortcutClipboardCopy();
  }
  if (pressedKeys.delete(key)) {
    sendControl(keyboardRecord(key, keyReleased));
  }
  physicalTextPending = false;
  event.preventDefault();
  event.stopPropagation();
}

function handleSurfaceFocus() {
  if (owner.controlOnFocus()) requestControl();
}

function handleSurfaceBlur(event) {
  if (event.relatedTarget !== imeProxy) {
    releaseControl();
  }
}

function handleVisibilityChange() {
  if (document.hidden) {
    releaseControl();
    controlConnectAttempt = null;
    videoConnectAttempt = null;
    audioConnectAttempt = null;
    videoSocket?.close(1000, "page hidden");
  } else if (sessionConnected) {
    void connectControl();
    if (!videoSocket) void connectVideo();
    if (options.audio !== false && !audioSocket) void connectAudio();
    if (owner.controlOnFocus() && document.activeElement === inputElement) {
      requestControl();
    }
  }
}

async function configureDecoder(configuration) {
  const generation = ++decoderGeneration;
  if (decoder) {
    decoder.close();
    decoder = null;
  }
  decoderConfiguration = {
    codec: configuration.codec,
    optimizeForLatency: true,
  };
  waitingForKeyframe = true;
  renderedFrameTimes.length = 0;
  let support;
  try {
    support = await VideoDecoder.isConfigSupported(decoderConfiguration);
  } catch (error) {
    if (generation !== decoderGeneration || sessionDisposed || !sessionConnected) return;
    throw error;
  }
  if (generation !== decoderGeneration) {
    return;
  }
  if (!support.supported) {
    decoderConfiguration = null;
    setStatus("Unsupported codec");
    owner.updateState("video", {
      state: "error",
      message: `This browser cannot decode ${configuration.codec}.`,
      codec: configuration.codec,
    });
    return;
  }

  const configuredDecoder = new VideoDecoder({
    output(frame) {
      pendingFrames.push(frame);
      if (pendingFrames.length > 24) {
        pendingFrames.shift().close();
        droppedFrames += 1;
      }
      scheduleVideoPresentation();
    },
    error(error) {
      console.error("video decoder error", error);
      if (decoder === configuredDecoder) {
        decoder = null;
      }
      setStatus(`Video decoder error · ${error.message || error.name}`);
      if (videoSocket?.readyState === WebSocket.OPEN) {
        videoSocket.close(4001, "video decoder error");
      }
    },
  });
  configuredDecoder.configure(decoderConfiguration);
  decoder = configuredDecoder;
  owner.updateState("video", { codec: configuration.codec });
}

function scheduleVideoPresentation() {
  if (pendingFrames.length === 0 || animationPending || presentationTimer !== null) {
    return;
  }
  const presentation = expectedPresentationTime(pendingFrames[0].timestamp);
  const delay = presentation === null ? 0 : presentation - performance.now();
  if (delay > 8) {
    presentationTimer = setTimeout(() => {
      presentationTimer = null;
      scheduleVideoPresentation();
    }, Math.min(delay - 4, 1000));
    return;
  }
  animationPending = true;
  animationFrame = requestAnimationFrame(renderFrame);
}

function renderFrame() {
  animationFrame = null;
  animationPending = false;
  if (pendingFrames.length === 0) {
    return;
  }
  if (!display || !context) {
    for (const frame of pendingFrames.splice(0)) frame.close();
    return;
  }
  const now = performance.now();
  let frame;
  if (!clockSynchronized()) {
    frame = pendingFrames.pop();
    for (const stale of pendingFrames.splice(0)) {
      stale.close();
      droppedFrames += 1;
    }
  } else {
    let due = 0;
    while (due < pendingFrames.length &&
        expectedPresentationTime(pendingFrames[due].timestamp) - now <= 8) {
      due += 1;
    }
    if (due === 0) {
      scheduleVideoPresentation();
      return;
    }
    const ready = pendingFrames.splice(0, due);
    frame = ready.pop();
    for (const stale of ready) {
      stale.close();
      droppedFrames += 1;
    }
  }
  if (display.width !== frame.displayWidth || display.height !== frame.displayHeight) {
    display.width = frame.displayWidth;
    display.height = frame.displayHeight;
  }
  context.drawImage(frame, 0, 0, display.width, display.height);
  const presentation = expectedPresentationTime(frame.timestamp);
  videoLateness = presentation === null ? 0 : now - presentation;
  lastVideoCaptureMicros = frame.timestamp;
  lastVideoPresentation = now;
  frame.close();
  renderedFrames += 1;
  renderedFrameTimes.push(now);
  const windowStart = now - 1000;
  while (renderedFrameTimes.length > 1 && renderedFrameTimes[0] < windowStart) {
    renderedFrameTimes.shift();
  }
  const elapsed = now - renderedFrameTimes[0];
  const renderedFps = elapsed > 0
    ? (renderedFrameTimes.length - 1) * 1000 / elapsed
    : 0;
  const lag = Math.max(0, inputSequence - latestAppliedInput);
  const audioMode = audioScheduled ? "sync" : "queue";
  owner.setStats({
    width: display.width, height: display.height, renderedFps, generation: currentGeneration,
    bitrateKbps: qualityBitrate, scalePercent: qualityScale, rttMs: rtt,
    clockConfident: clockSynchronized(), clockUncertaintyMs: Number.isFinite(clockBestRTT) ? clockBestRTT / 2 : null,
    latencyTargetMs: targetLatencyMilliseconds, latenessMs: videoLateness, audioVideoSkewMs: audioVideoSkew,
    pendingInputCount: lag, decoderQueue: decoder?.decodeQueueSize || 0, droppedFrames,
    audioQueueMs: audioConfiguration ? audioQueuedFrames * 1000 / audioConfiguration.sampleRate : 0,
    audioUnderflows, audioMode, resizeState,
  });
  scheduleVideoPresentation();
}

function decodeMessage(buffer) {
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength < headerSize) {
    return;
  }
  const view = new DataView(buffer);
  if (view.getUint8(0) !== 2 || view.getUint8(1) !== 1) {
    return;
  }
  const keyframe = (view.getUint8(2) & 1) !== 0;
  const discontinuity = (view.getUint8(2) & 2) !== 0;
  receivedChunks += 1;
  intervalChunks += 1;
  if (keyframe) {
    receivedKeyframes += 1;
  }
  if (renderedFrames === 0) {
    owner.updateState("video", {
      message: `Receiving video · ${receivedChunks} chunks · ${receivedKeyframes} keyframes`,
    });
  }
  if (!decoder || decoder.state !== "configured") {
    return;
  }
  const timestamp = Number(view.getBigUint64(12, true));
  const generation = view.getUint32(20, true);
  latestAppliedInput = view.getUint32(36, true);
  if (generation !== currentGeneration) {
    currentGeneration = generation;
    decoder.reset(); decoder.configure(decoderConfiguration); waitingForKeyframe = true;
  }
  for (const [id, request] of resizeRequests) {
    if (request.generation === generation) {
      const latencyMs = performance.now() - request.requested;
      resizeState = "presented";
      emit("resize", Object.freeze({
        state: resizeState,
        latencyMs,
        width: view.getUint16(24, true),
        height: view.getUint16(26, true),
        generation,
      }));
      resizeRequests.delete(id);
    }
  }

  if (discontinuity || decoder.decodeQueueSize > 6) {
    droppedFrames += decoder.decodeQueueSize;
    decoder.reset();
    decoder.configure(decoderConfiguration);
    waitingForKeyframe = true;
  }
  if (waitingForKeyframe && !keyframe) {
    return;
  }
  waitingForKeyframe = false;
  decoder.decode(new EncodedVideoChunk({
    type: keyframe ? "key" : "delta",
    timestamp,
    data: new Uint8Array(buffer, headerSize),
  }));
}

function handleCompositionUpdate(event) {
  if (controlActive) {
    controlSocket.send(JSON.stringify({ type: "text", action: "preedit", text: event.data, sequence: nextInputSequence() }));
  }
}

function handleCompositionEnd(event) {
  if (controlActive) {
    controlSocket.send(JSON.stringify({
      type: "text",
      action: "commit",
      text: event.data,
      sequence: nextInputSequence(),
    }));
  }
  suppressCompositionText = event.data;
  if (compositionTimer !== null) clearTimeout(compositionTimer);
  compositionTimer = setTimeout(() => {
    compositionTimer = null;
    if (suppressCompositionText === event.data) {
      suppressCompositionText = null;
    }
  }, 0);
  imeProxy.value = "";
}

function handleBeforeInput(event) {
  if (event.isComposing || event.inputType !== "insertText" || !event.data) {
    return;
  }
  if (physicalTextPending || suppressCompositionText === event.data) {
    physicalTextPending = false;
    suppressCompositionText = null;
    event.preventDefault();
  } else if (controlActive) {
    controlSocket.send(JSON.stringify({
      type: "text",
      action: "commit",
      text: event.data,
      sequence: nextInputSequence(),
    }));
    event.preventDefault();
  }
  imeProxy.value = "";
}

function handleTextInputFocus() {
  requestControl();
}

function handleTextInputBlur(event) {
  if (controlActive) {
    controlSocket.send(JSON.stringify({
      type: "text",
      action: "preedit",
      text: "",
      sequence: nextInputSequence(),
    }));
  }
  imeProxy.value = "";
  if (event.relatedTarget === display) {
    return;
  }
  releaseControl();
}

function sendFeedback() {
  if (!controlSocket || controlSocket.readyState !== WebSocket.OPEN) return;
  const now = performance.now();
  while (renderedFrameTimes.length > 0 && renderedFrameTimes[0] < now - 1000) {
    renderedFrameTimes.shift();
  }
  const id = ++pingID;
  pings.set(id, now);
  for (const [pendingID, sent] of pings) {
    if (sent < now - 10_000) {
      pings.delete(pendingID);
    }
  }
  controlSocket.send(JSON.stringify({ type: "ping", id }));
  controlSocket.send(JSON.stringify({ type: "feedback", queue: decoder?.decodeQueueSize || 0, dropped: droppedFrames, fps: renderedFrameTimes.length, rtt, active: intervalChunks > 0 }));
  droppedFrames = 0;
  intervalChunks = 0;
}

async function connectVideo() {
  if (!sessionConnected || document.hidden) return;
  if (videoReconnectTimer !== null) {
    clearTimeout(videoReconnectTimer);
    videoReconnectTimer = null;
  }
  if (videoConnectAttempt) return;
  setStatus("Connecting");
  const attempt = { generation: connectionGeneration };
  videoConnectAttempt = attempt;
  let socket;
  try {
    socket = await createWebSocket("/stream");
  } catch (error) {
    if (videoConnectAttempt !== attempt) return;
    videoConnectAttempt = null;
    if (!sessionConnected || attempt.generation !== connectionGeneration || document.hidden) return;
    const failure = error instanceof Error ? error : new Error(String(error));
    emit("error", failure);
    setStatus(`Reconnecting · ${failure.message}`);
    videoReconnectTimer = setTimeout(() => {
      videoReconnectTimer = null;
      void connectVideo();
    }, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 5000);
    return;
  }
  if (videoConnectAttempt !== attempt || !sessionConnected || document.hidden ||
      attempt.generation !== connectionGeneration) {
    if (videoConnectAttempt === attempt) videoConnectAttempt = null;
    socket.close(1000, "stale connection attempt");
    return;
  }
  videoConnectAttempt = null;
  videoSocket = socket;
  socket.binaryType = "arraybuffer";
  socket.addEventListener("open", () => {
    if (videoSocket !== socket) return;
    reconnectDelay = 250;
    setStatus("Connected", true);
  });
  socket.addEventListener("message", (event) => {
    if (videoSocket !== socket) return;
    if (typeof event.data === "string") {
      const message = JSON.parse(event.data);
      if (message.type === "video-config") {
        configureDecoder(message).catch((error) => {
          if (videoSocket !== socket || sessionDisposed || !sessionConnected) return;
          console.error("video decoder configuration failed", error);
          setStatus("Video decoder error");
          socket.close(4001, "video decoder configuration failed");
        });
      }
      return;
    }
    decodeMessage(event.data);
  });
  socket.addEventListener("close", (event) => {
    if (videoSocket !== socket) return;
    videoSocket = null;
    const reason = event.reason || `WebSocket code ${event.code}`;
    console.warn("video WebSocket closed", event.code, event.reason);
    setStatus(sessionConnected ? `Reconnecting · ${event.code}` : "Disconnected");
    if (renderedFrames === 0) {
      owner.updateState("video", { message: `${reason}. Retrying…` });
    }
    decoderGeneration += 1;
    if (decoder) {
      decoder.close();
      decoder = null;
    }
    for (const frame of pendingFrames.splice(0)) {
      frame.close();
    }
    if (presentationTimer !== null) {
      clearTimeout(presentationTimer);
      presentationTimer = null;
    }
    decoderConfiguration = null;
    waitingForKeyframe = true;
    if (sessionConnected && !document.hidden) {
      videoReconnectTimer = setTimeout(() => {
        videoReconnectTimer = null;
        void connectVideo();
      }, reconnectDelay);
    }
    reconnectDelay = Math.min(reconnectDelay * 2, 5000);
  });
  socket.addEventListener("error", () => socket.close());
}

function decodeAudioMessage(buffer) {
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength <= audioHeaderSize ||
      !audioDecoder || audioDecoder.state !== "configured") {
    return;
  }
  const view = new DataView(buffer);
  if (view.getUint8(0) !== 2 || view.getUint8(1) !== 2) {
    return;
  }
  const discontinuity = (view.getUint8(2) & 1) !== 0;
  const timestamp = Number(view.getBigUint64(12, true));
  const generation = view.getUint32(20, true);
  if (discontinuity || generation !== audioGeneration || audioDecoder.decodeQueueSize > 12) {
    audioGeneration = generation;
    audioDecoder.reset();
    audioDecoder.configure({
      codec: audioConfiguration.codec,
      sampleRate: audioConfiguration.sampleRate,
      numberOfChannels: audioConfiguration.channels,
    });
    resetAudioPlayer();
  }
  audioDecoder.decode(new EncodedAudioChunk({
    type: "key",
    timestamp,
    data: new Uint8Array(buffer, audioHeaderSize),
  }));
}

async function connectAudio() {
  if (!sessionConnected || document.hidden || options.audio === false) return;
  if (audioReconnectTimer !== null) {
    clearTimeout(audioReconnectTimer);
    audioReconnectTimer = null;
  }
  if (audioConnectAttempt) return;
  setAudioStatus("Audio connecting");
  const attempt = { generation: connectionGeneration };
  audioConnectAttempt = attempt;
  let socket;
  try {
    socket = await createWebSocket("/audio");
  } catch (error) {
    if (audioConnectAttempt !== attempt) return;
    audioConnectAttempt = null;
    if (!sessionConnected || document.hidden || attempt.generation !== connectionGeneration) return;
    const failure = error instanceof Error ? error : new Error(String(error));
    emit("error", failure);
    setAudioStatus(`Audio reconnecting · ${failure.message}`);
    audioReconnectTimer = setTimeout(() => {
      audioReconnectTimer = null;
      void connectAudio();
    }, audioReconnectDelay);
    audioReconnectDelay = Math.min(audioReconnectDelay * 2, 5000);
    return;
  }
  if (audioConnectAttempt !== attempt || !sessionConnected || document.hidden ||
      attempt.generation !== connectionGeneration) {
    if (audioConnectAttempt === attempt) audioConnectAttempt = null;
    socket.close(1000, "stale connection attempt");
    return;
  }
  audioConnectAttempt = null;
  socket.binaryType = "arraybuffer";
  audioSocket = socket;
  socket.addEventListener("open", () => {
    audioReconnectDelay = 250;
  });
  socket.addEventListener("message", (event) => {
    if (audioSocket !== socket) {
      return;
    }
    if (typeof event.data === "string") {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        socket.close(1003, "invalid audio configuration");
        return;
      }
      if (message.type !== "audio-config" || message.version !== 2) {
        socket.close(1003, "invalid audio configuration");
        return;
      }
      audioDecoderSetupGeneration += 1;
      audioConfiguration = message;
      if (!message.enabled) {
        setAudioStatus("Session audio unavailable");
      } else {
        setAudioStatus(audioWanted ? "Audio starting" : "Audio ready");
        configureAudioDecoder().catch((error) => {
          console.warn("audio decoder configuration failed", error);
          setAudioStatus("Audio decoder error");
        });
      }
      return;
    }
    decodeAudioMessage(event.data);
  });
  socket.addEventListener("close", () => {
    if (audioSocket !== socket) {
      return;
    }
    audioSocket = null;
    audioDecoderSetupGeneration += 1;
    closeAudioDecoder();
    resetAudioPlayer();
    setAudioStatus(sessionConnected ? "Audio reconnecting" : "Audio disconnected");
    if (sessionConnected && !document.hidden) {
      audioReconnectTimer = setTimeout(() => {
        audioReconnectTimer = null;
        void connectAudio();
      }, audioReconnectDelay);
    }
    audioReconnectDelay = Math.min(audioReconnectDelay * 2, 5000);
  });
  socket.addEventListener("error", () => socket.close());
}

function setLatencyTarget(milliseconds) {
  milliseconds = Number(milliseconds);
  if (!Number.isFinite(milliseconds) || milliseconds < 0) {
    throw new RangeError("Latency must be a non-negative number");
  }
  targetLatencyMilliseconds = milliseconds;
  resetAudioPlayer();
  if (presentationTimer !== null) {
    clearTimeout(presentationTimer);
    presentationTimer = null;
  }
  scheduleVideoPresentation();
}

function setMuted(muted) {
  audioMuted = Boolean(muted);
  if (audioGain) audioGain.gain.value = audioMuted ? 0 : audioVolume;
  if (audioWanted) setAudioStatus(audioMuted ? "Audio muted" : "Audio active");
}

function setVolume(volume) {
  volume = Number(volume);
  if (!Number.isFinite(volume) || volume < 0) {
    throw new RangeError("Volume must be a non-negative number");
  }
  audioVolume = volume;
  if (audioGain && !audioMuted) audioGain.gain.value = volume;
}

function refreshResizeObservation() {
  resizeObserver?.disconnect();
  resizeObserver = null;
  if (typeof window === "undefined") return;
  window.removeEventListener("resize", scheduleResize);

  const policy = owner.remoteDisplayPolicy();
  if (!sessionConnected || policy.mode !== "observe" || !display) return;
  const element = policy.element ?? display;
  if (typeof ResizeObserver !== "undefined") {
    resizeObserver = new ResizeObserver(scheduleResize);
    resizeObserver.observe(element);
  }
  window.addEventListener("resize", scheduleResize);
  scheduleResize();
}

function remoteDisplayPolicyChanged() {
  lastResizeRequest = null;
  if (resizeTimer !== null) {
    clearTimeout(resizeTimer);
    resizeTimer = null;
  }
  resizePending = false;
  refreshResizeObservation();
  sendResize();
}

function addSurfaceListener(target, type, listener, options) {
  target.addEventListener(type, listener, options);
  surfaceCleanup.push(() => target.removeEventListener(type, listener, options));
}

function attachSurface(surfaceOptions) {
  if (sessionDisposed) {
    throw new Error("The session has been disposed");
  }
  if (!surfaceOptions?.canvas) {
    throw new TypeError("attachSurface requires a canvas");
  }
  if (display) {
    throw new Error("A surface is already attached to this session");
  }

  display = surfaceOptions.canvas;
  inputElement = surfaceOptions.inputElement ?? display;
  imeProxy = surfaceOptions.textInputElement ?? document.createElement("input");
  const ownsImeProxy = !surfaceOptions.textInputElement;
  if (ownsImeProxy) {
    imeProxy.type = "text";
    imeProxy.autocomplete = "off";
    imeProxy.setAttribute("aria-label", "Remote text input");
    Object.assign(imeProxy.style, {
      position: "fixed",
      width: "1px",
      height: "1px",
      opacity: "0",
      pointerEvents: "none",
      left: "0",
      bottom: "0",
    });
    document.body.append(imeProxy);
  }

  context = display.getContext("2d", { alpha: false });
  if (!context) {
    if (ownsImeProxy) imeProxy.remove();
    display = null;
    inputElement = null;
    imeProxy = null;
    throw new Error("The attached canvas does not provide a 2D context");
  }

  clipboardAutoSync = Boolean(surfaceOptions.clipboardAutoSync);
  owner.setControlOnFocus(Boolean(surfaceOptions.controlOnFocus));
  if (surfaceOptions.remoteDisplay) {
    owner.setRemoteDisplayPolicy(surfaceOptions.remoteDisplay);
  }

  addSurfaceListener(inputElement, "pointermove", queuePointerPosition);
  addSurfaceListener(inputElement, "pointermove", handleRelativePointerMove);
  addSurfaceListener(inputElement, "pointerdown", handlePointerDown);
  addSurfaceListener(inputElement, "pointerup", handlePointerUp);
  addSurfaceListener(inputElement, "pointercancel", releaseInput);
  addSurfaceListener(inputElement, "contextmenu", (event) => event.preventDefault());
  addSurfaceListener(inputElement, "wheel", handleWheel, { passive: false });
  addSurfaceListener(inputElement, "keydown", handleKeyDown);
  addSurfaceListener(inputElement, "keyup", handleKeyUp);
  addSurfaceListener(inputElement, "focus", handleSurfaceFocus);
  addSurfaceListener(inputElement, "blur", handleSurfaceBlur);
  addSurfaceListener(inputElement, "dblclick", () => {
    display.requestPointerLock?.();
  });
  if (imeProxy !== inputElement) {
    addSurfaceListener(imeProxy, "keydown", handleKeyDown);
    addSurfaceListener(imeProxy, "keyup", handleKeyUp);
  }
  addSurfaceListener(imeProxy, "compositionupdate", handleCompositionUpdate);
  addSurfaceListener(imeProxy, "compositionend", handleCompositionEnd);
  addSurfaceListener(imeProxy, "beforeinput", handleBeforeInput);
  addSurfaceListener(imeProxy, "focus", handleTextInputFocus);
  addSurfaceListener(imeProxy, "blur", handleTextInputBlur);
  addSurfaceListener(document, "pointerlockchange", handlePointerLockChange);
  addSurfaceListener(document, "pointerlockerror", () => {
    emit("error", new Error("The browser denied pointer lock"));
  });
  addSurfaceListener(document, "visibilitychange", handleVisibilityChange);
  refreshResizeObservation();

  const attachedCanvas = display;
  let surfaceDisposed = false;
  const disposeSurface = () => {
    if (surfaceDisposed) return;
    surfaceDisposed = true;
    releaseControl();
    if (document.pointerLockElement === attachedCanvas) document.exitPointerLock();
    for (const cleanup of surfaceCleanup.splice(0)) cleanup();
    resizeObserver?.disconnect();
    resizeObserver = null;
    window.removeEventListener("resize", scheduleResize);
    if (resizeTimer !== null) {
      clearTimeout(resizeTimer);
      resizeTimer = null;
    }
    resizePending = false;
    if (ownsImeProxy) imeProxy.remove();
    display = null;
    inputElement = null;
    imeProxy = null;
    context = null;
    if (surfaceDisposer === disposeSurface) surfaceDisposer = null;
  };
  surfaceDisposer = disposeSurface;
  return Object.freeze({
    requestPointerLock() {
      if (surfaceDisposed) throw new Error("The surface has been disposed");
      return Promise.resolve(attachedCanvas.requestPointerLock());
    },
    exitPointerLock() {
      if (document.pointerLockElement === attachedCanvas) document.exitPointerLock();
    },
    focus() {
      if (surfaceDisposed) throw new Error("The surface has been disposed");
      inputElement.focus({ preventScroll: true });
    },
    focusTextInput() {
      if (surfaceDisposed) throw new Error("The surface has been disposed");
      imeProxy.focus({ preventScroll: true });
    },
    dispose: disposeSurface,
  });
}

function connect() {
  if (sessionDisposed) {
    throw new Error("The session has been disposed");
  }
  if (sessionConnected) return;
  if (!display || !context) {
    throw new Error("Attach a canvas before connecting the session");
  }
  if (!("VideoDecoder" in window)) {
    const error = new Error("This browser does not provide the WebCodecs VideoDecoder API");
    owner.updateState("video", { state: "error", message: error.message });
    emit("error", error);
    return;
  }
  sessionConnected = true;
  connectionGeneration += 1;
  void connectControl();
  if (options.audio === false) {
    setAudioStatus("Audio disabled");
  } else {
    void connectAudio();
  }
  void connectVideo();
  refreshResizeObservation();
  feedbackTimer = setInterval(sendFeedback, 1000);
}

function disconnect() {
  const wasConnected = sessionConnected;
  sessionConnected = false;
  connectionGeneration += 1;
  controlConnectAttempt = null;
  videoConnectAttempt = null;
  audioConnectAttempt = null;
  releaseControl();
  resizeObserver?.disconnect();
  resizeObserver = null;
  window.removeEventListener("resize", scheduleResize);
  if (resizeTimer !== null) {
    clearTimeout(resizeTimer);
    resizeTimer = null;
  }
  resizePending = false;
  if (feedbackTimer !== null) {
    clearInterval(feedbackTimer);
    feedbackTimer = null;
  }
  for (const timer of [controlReconnectTimer, controlStableTimer, videoReconnectTimer, audioReconnectTimer]) {
    if (timer !== null) clearTimeout(timer);
  }
  controlReconnectTimer = null;
  controlStableTimer = null;
  videoReconnectTimer = null;
  audioReconnectTimer = null;
  for (const socket of [videoSocket, controlSocket, audioSocket]) {
    socket?.close(1000, "client disconnect");
  }
  videoSocket = null;
  controlSocket = null;
  audioSocket = null;
  decoderGeneration += 1;
  decoder?.close();
  decoder = null;
  audioDecoderSetupGeneration += 1;
  closeAudioDecoder();
  resetAudioPlayer();
  for (const frame of pendingFrames.splice(0)) frame.close();
  if (presentationTimer !== null) {
    clearTimeout(presentationTimer);
    presentationTimer = null;
  }
  if (animationFrame !== null) cancelAnimationFrame(animationFrame);
  animationFrame = null;
  animationPending = false;
  if (pointerAnimationFrame !== null) cancelAnimationFrame(pointerAnimationFrame);
  pointerAnimationFrame = null;
  pointerAnimationPending = false;
  pendingPointerPosition = null;
  if (wasConnected) {
    owner.updateState("video", { state: "disconnected", message: "Video disconnected" });
    owner.updateState("input", { state: "disconnected", message: "Input disconnected", connected: false });
    owner.updateState("audio", { state: "disconnected", message: "Audio disconnected" });
  }
}

function dispose() {
  if (disposePromise) return disposePromise;
  sessionDisposed = true;
  disposePromise = (async () => {
    surfaceDisposer?.();
    disconnect();
    if (compositionTimer !== null) clearTimeout(compositionTimer);
    compositionTimer = null;
    suppressCompositionText = null;
    if (pendingClipboardCopy) {
      const transaction = pendingClipboardCopy;
      pendingClipboardCopy = null;
      clearTimeout(transaction.timeout);
      transaction.reject(new Error("The session has been disposed"));
    }
    if (shortcutClipboardCopy) clearTimeout(shortcutClipboardCopy.timeout);
    shortcutClipboardCopy = null;
    clipboardPastePending = false;
    pings.clear();
    resizeRequests.clear();
    audioWanted = false;
    resetAudioPlayer();
    closeAudioDecoder();
    const player = audioPlayer;
    const gain = audioGain;
    const contextToClose = audioContext;
    audioPlayer = null;
    audioGain = null;
    audioContext = null;
    audioConfiguration = null;
    if (player) {
      player.port.onmessage = null;
      player.disconnect();
    }
    gain?.disconnect();
    if (contextToClose && contextToClose.state !== "closed") {
      await contextToClose.close();
    }
  })();
  return disposePromise;
}

return {
  attachSurface,
  connect,
  disconnect,
  dispose,
  enableAudio,
  getAudioMuted: () => audioMuted,
  getRemoteClipboard: () => remoteClipboard,
  remoteDisplayPolicyChanged,
  requestControl,
  releaseControl,
  sendClipboardText,
  setLatencyTarget,
  setMuted,
  setVolume,
};
}

function positiveNumber(value, name) {
  value = Number(value);
  if (!Number.isFinite(value) || value <= 0) {
    throw new RangeError(`${name} must be a positive number`);
  }
  return value;
}

function normalizeRemoteDisplayPolicy(policy) {
  if (!policy || typeof policy !== "object") {
    throw new TypeError("Remote display policy must be an object");
  }
  if (policy.mode === "manual") return Object.freeze({ mode: "manual" });
  if (policy.mode === "fixed") {
    return Object.freeze({
      mode: "fixed",
      width: positiveNumber(policy.width, "Remote display width"),
      height: positiveNumber(policy.height, "Remote display height"),
      scale: positiveNumber(policy.scale, "Remote display scale"),
    });
  }
  if (policy.mode !== "observe") {
    throw new TypeError(`Unknown remote display mode: ${policy.mode}`);
  }
  const normalized = { mode: "observe" };
  if (policy.element !== undefined) {
    if (typeof policy.element?.getBoundingClientRect !== "function") {
      throw new TypeError("Observed remote display element must be a DOM element");
    }
    normalized.element = policy.element;
  }
  for (const name of ["devicePixelRatio", "minWidth", "minHeight", "maxWidth", "maxHeight", "maxPixels"]) {
    if (policy[name] !== undefined) normalized[name] = positiveNumber(policy[name], name);
  }
  if (policy.debounceMs !== undefined) {
    const debounce = Number(policy.debounceMs);
    if (!Number.isFinite(debounce) || debounce < 0) {
      throw new RangeError("debounceMs must be a non-negative number");
    }
    normalized.debounceMs = debounce;
  }
  return Object.freeze(normalized);
}

/** Framework-free browser client for a Waymote streaming gateway. */
export class WaymoteSession {
  #listeners = new Map();
  #remoteDisplayPolicy;
  #controlOnFocus = false;
  #runtime;
  #disposed = false;
  #disposePromise = null;

  constructor(options = {}) {
    this.#remoteDisplayPolicy = normalizeRemoteDisplayPolicy(
      options.remoteDisplay ?? { mode: "manual" },
    );
    this.state = Object.freeze({
      video: Object.freeze({ state: "idle", message: "Video idle", codec: null }),
      input: Object.freeze({
        state: "idle",
        message: "Input idle",
        connected: false,
        pointerLocked: false,
      }),
      audio: Object.freeze({
        state: "idle",
        message: "Audio idle",
        available: false,
        muted: false,
      }),
    });
    this.stats = Object.freeze({});
    this.#runtime = createRuntime({
      emit: (type, value) => this.#emit(type, value),
      updateState: (section, changes) => this.#updateState(section, changes),
      setStats: (stats) => {
        this.stats = Object.freeze({ ...stats });
        this.#emit("stats", this.stats);
      },
      remoteDisplayPolicy: () => this.#remoteDisplayPolicy,
      controlOnFocus: () => this.#controlOnFocus,
      setControlOnFocus: (enabled) => { this.#controlOnFocus = enabled; },
      setRemoteDisplayPolicy: (policy) => this.#setRemoteDisplayPolicy(policy),
    }, options);

    const session = this;
    this.video = Object.freeze({
      setLatencyTarget: (milliseconds) => {
        this.#assertActive();
        this.#runtime.setLatencyTarget(milliseconds);
      },
    });
    this.audio = Object.freeze({
      enable: () => {
        this.#assertActive();
        return this.#runtime.enableAudio();
      },
      setMuted: (muted) => {
        this.#assertActive();
        this.#runtime.setMuted(muted);
      },
      setVolume: (volume) => {
        this.#assertActive();
        this.#runtime.setVolume(volume);
      },
      toggleMuted: () => {
        this.#assertActive();
        this.#runtime.setMuted(!this.#runtime.getAudioMuted());
      },
      get muted() { return session.#runtime.getAudioMuted(); },
    });
    this.input = Object.freeze({
      acquire: () => {
        this.#assertActive();
        this.#runtime.requestControl();
      },
      release: () => {
        this.#assertActive();
        this.#runtime.releaseControl();
      },
    });
    this.clipboard = Object.freeze({
      sendText: (text) => {
        this.#assertActive();
        return this.#runtime.sendClipboardText(String(text));
      },
      get latestRemoteText() { return session.#runtime.getRemoteClipboard(); },
    });
    this.remoteDisplay = Object.freeze({
      setPolicy: (policy) => this.#setRemoteDisplayPolicy(policy),
      manual: () => this.#setRemoteDisplayPolicy({ mode: "manual" }),
      fixed: (configuration) => this.#setRemoteDisplayPolicy({ mode: "fixed", ...configuration }),
      observe: (configuration = {}) => this.#setRemoteDisplayPolicy({ mode: "observe", ...configuration }),
      get policy() { return session.#remoteDisplayPolicy; },
    });
  }

  attachSurface(options) {
    this.#assertActive();
    return this.#runtime.attachSurface(options);
  }

  on(type, listener) {
    this.#assertActive();
    if (typeof listener !== "function") throw new TypeError("Event listener must be a function");
    let listeners = this.#listeners.get(type);
    if (!listeners) this.#listeners.set(type, listeners = new Set());
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  connect() {
    this.#assertActive();
    this.#runtime.connect();
  }

  disconnect() {
    if (this.#disposed) return;
    this.#runtime.disconnect();
  }

  dispose() {
    if (this.#disposePromise) return this.#disposePromise;
    this.#disposed = true;
    this.#listeners.clear();
    this.#disposePromise = this.#runtime.dispose();
    return this.#disposePromise;
  }

  #setRemoteDisplayPolicy(policy) {
    this.#assertActive();
    this.#remoteDisplayPolicy = normalizeRemoteDisplayPolicy(policy);
    this.#runtime?.remoteDisplayPolicyChanged();
  }

  #assertActive() {
    if (this.#disposed) throw new Error("The session has been disposed");
  }

  #updateState(section, changes) {
    const nextSection = Object.freeze({ ...this.state[section], ...changes });
    this.state = Object.freeze({ ...this.state, [section]: nextSection });
    this.#emit("state", this.state);
  }

  #emit(type, value) {
    for (const listener of [...(this.#listeners.get(type) ?? [])]) {
      try {
        listener(value);
      } catch (error) {
        console.error(`Waymote ${type} listener failed`, error);
      }
    }
  }
}

export const __testing = Object.freeze({ fitObservedResize, normalizeResizeDimensions });
