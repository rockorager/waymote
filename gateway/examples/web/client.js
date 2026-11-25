import { WaymoteSession } from "/waymote.js";

// The bundled example deliberately owns all visible UI and permission prompts.
const display = document.querySelector("#display");
const empty = document.querySelector("#empty");
const status = document.querySelector("#status");
const controlStatus = document.querySelector("#control-status");
const codec = document.querySelector("#codec");
const metrics = document.querySelector("#metrics");
const latency = document.querySelector("#latency");
const audioButton = document.querySelector("#audio");
const audioStatus = document.querySelector("#audio-status");
const pointerLockButton = document.querySelector("#pointer-lock");
const textInputButton = document.querySelector("#text-input");
const sendClipboardButton = document.querySelector("#send-clipboard");
const copyClipboardButton = document.querySelector("#copy-clipboard");
const clipboardStatus = document.querySelector("#clipboard-status");
const imeProxy = document.querySelector("#ime-proxy");

// A gateway started with WAYMOTE_TOKEN expects it as a WebSocket subprotocol.
// Open the page as /#token=... so the token stays out of requests and logs.
const token = new URLSearchParams(location.hash.slice(1)).get("token");
const session = new WaymoteSession({
  createWebSocket: token ? (_path, url) => new WebSocket(url, [token]) : undefined,
  latency: Number(latency.value),
  // Keep the shared demo at one resolution: multiple portal viewers can take
  // input control in turn, but must not repeatedly reconfigure one encoder.
  remoteDisplay: { mode: "fixed", width: 1280, height: 720, scale: 1 },
});
const surface = session.attachSurface({
  canvas: display,
  inputElement: display,
  textInputElement: imeProxy,
  controlOnFocus: true,
  clipboardAutoSync: true,
});

let resizeSummary = "resize idle";

function setConnectionStyle(element, connected) {
  element.classList.toggle("connected", connected);
  element.classList.toggle("disconnected", !connected);
}

session.on("state", (state) => {
  status.textContent = state.video.message;
  controlStatus.textContent = state.input.message;
  audioStatus.textContent = state.audio.message;
  codec.textContent = state.video.codec
    ? `${state.video.codec} · WebCodecs`
    : "H.264 · WebCodecs";
  setConnectionStyle(status, state.video.state === "connected");
  setConnectionStyle(controlStatus, state.input.state === "active" || state.input.state === "ready");

  audioButton.disabled = !state.audio.available;
  audioButton.textContent = state.audio.muted ? "Unmute audio"
    : state.audio.state === "active" ? "Mute audio" : "Enable audio";
  pointerLockButton.textContent = state.input.pointerLocked ? "Unlock pointer" : "Lock pointer";
  if (state.video.state === "error") {
    empty.textContent = state.video.message;
    empty.classList.remove("hidden");
  }
});

session.on("stats", (stats) => {
  empty.classList.add("hidden");
  const clock = stats.clockConfident
    ? `clock ±${stats.clockUncertaintyMs?.toFixed(1) ?? "?"} ms`
    : "clock syncing";
  const skew = stats.audioVideoSkewMs === null ? "A/V —" : `A/V ${stats.audioVideoSkewMs.toFixed(1)} ms`;
  metrics.textContent = [
    `${stats.width}×${stats.height}`,
    `${stats.renderedFps.toFixed(0)} fps`,
    `${stats.bitrateKbps} kbps @ ${stats.scalePercent}%`,
    `${stats.rttMs.toFixed(1)} ms RTT`,
    clock,
    `target ${stats.latencyTargetMs} ms`,
    `late ${stats.latenessMs.toFixed(1)} ms`,
    skew,
    `input ${stats.pendingInputCount}`,
    `decode ${stats.decoderQueue}`,
    `dropped ${stats.droppedFrames}`,
    `audio ${stats.audioQueueMs.toFixed(0)} ms/${stats.audioMode}`,
    resizeSummary,
  ].join(" · ");
});

session.on("clipboard", (event) => {
  clipboardStatus.textContent = event.status;
  copyClipboardButton.disabled = event.text === null;
});

session.on("resize", (event) => {
  const size = event.width && event.height ? `${event.width}×${event.height}` : "";
  const latencyText = event.latencyMs === undefined ? "" : ` in ${event.latencyMs.toFixed(0)} ms`;
  resizeSummary = `resize ${event.state} ${size}${latencyText}`.trim();
});

session.on("error", (error) => {
  console.warn("Waymote stream error", error);
});

latency.addEventListener("change", () => {
  session.video.setLatencyTarget(Number(latency.value));
});

audioButton.addEventListener("click", async () => {
  try {
    if (session.state.audio.state === "active" || session.state.audio.state === "muted") {
      session.audio.setMuted(!session.audio.muted);
    } else {
      await session.audio.enable();
    }
  } catch (error) {
    console.warn("audio start failed", error);
    audioStatus.textContent = "Browser denied audio";
  }
});

pointerLockButton.addEventListener("click", () => {
  if (document.pointerLockElement === display) {
    surface.exitPointerLock();
  } else {
    surface.requestPointerLock().catch((error) => {
      console.warn("pointer lock failed", error);
    });
  }
});

textInputButton.addEventListener("click", () => {
  session.input.acquire();
  surface.focusTextInput();
});

sendClipboardButton.addEventListener("click", async () => {
  try {
    const text = await navigator.clipboard.readText();
    session.clipboard.sendText(text);
  } catch (error) {
    console.warn("local clipboard read failed", error);
    clipboardStatus.textContent = "Local clipboard unavailable";
  }
});

copyClipboardButton.addEventListener("click", async () => {
  const text = session.clipboard.latestRemoteText;
  if (text === null) return;
  try {
    await navigator.clipboard.writeText(text);
    clipboardStatus.textContent = "Remote clipboard copied";
  } catch (error) {
    let copied = false;
    const handleCopy = (event) => {
      event.clipboardData?.setData("text/plain", text);
      event.preventDefault();
      copied = true;
    };
    document.addEventListener("copy", handleCopy);
    document.execCommand("copy");
    document.removeEventListener("copy", handleCopy);
    if (copied) {
      clipboardStatus.textContent = "Remote clipboard copied";
    } else {
      console.warn("remote clipboard write failed", error);
      clipboardStatus.textContent = "Clipboard write unavailable";
    }
  }
});

for (const button of document.querySelectorAll("button")) {
  button.addEventListener("pointerdown", (event) => event.preventDefault());
}

session.connect();
