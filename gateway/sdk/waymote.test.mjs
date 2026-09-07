import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { WaymoteSession, __testing } from "./waymote.js";

class FakeTarget {
  listeners = new Map();

  addEventListener(type, listener) {
    let listeners = this.listeners.get(type);
    if (!listeners) this.listeners.set(type, listeners = new Set());
    listeners.add(listener);
  }

  removeEventListener(type, listener) {
    this.listeners.get(type)?.delete(listener);
  }

  dispatch(type, event) {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }

  get listenerCount() {
    return [...this.listeners.values()].reduce((count, listeners) => count + listeners.size, 0);
  }
}

test("observed resize supports tall displays without exceeding its pixel budget", () => {
  const fitted = __testing.fitObservedResize(1922.5, 2467.5, {
    maxPixels: 2560 * 1440,
  });
  assert.equal(fitted.width % 16, 0);
  assert.equal(fitted.height % 16, 0);
  assert.ok(fitted.width * fitted.height <= 2560 * 1440);
  assert.ok(fitted.height > 1440);
});

test("observed resize accepts the 6000 square protocol envelope", () => {
  assert.deepEqual(
    __testing.fitObservedResize(6000, 6000, { maxPixels: 6000 * 6000 }),
    { width: 6000, height: 6000, downscale: 1 },
  );
});

test("observed resize clamps dimensions above the protocol envelope", () => {
  const fitted = __testing.fitObservedResize(6002, 6002, { maxPixels: 6000 * 6000 });
  assert.equal(fitted.width, 6000);
  assert.equal(fitted.height, 6000);
  assert.ok(fitted.downscale < 1);
});

test("fixed resize dimensions cannot exceed the protocol envelope", () => {
  assert.deepEqual(
    __testing.normalizeResizeDimensions(6002, 6002),
    { width: 6000, height: 6000 },
  );
});

test("printable keys resolve to XKB keysyms from the browser layout", () => {
  const event = (key, modifiers = {}) => ({
    key,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    getModifierState: () => false,
    ...modifiers,
  });

  assert.equal(__testing.resolvedKeysym(event("q")), 0x71);
  assert.equal(__testing.resolvedKeysym(event("'")), 0x27);
  assert.equal(__testing.resolvedKeysym(event("ü")), 0xfc);
  assert.equal(__testing.resolvedKeysym(event("🦆")), 0x101f986);
  assert.equal(__testing.resolvedKeysym(event("a", { ctrlKey: true })), 0);
  assert.equal(__testing.resolvedKeysym(event("a", { metaKey: true })), 0);
  assert.equal(__testing.resolvedKeysym(event("a", { altKey: true })), 0);
  assert.equal(__testing.resolvedKeysym(event("€", {
    altKey: true,
    ctrlKey: true,
    getModifierState: (name) => name === "AltGraph",
  })), 0x10020ac);
});

test("keyboard records use resolved keysyms only when the gateway advertises support", async (t) => {
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  fakeWindow.VideoDecoder = true;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  fakeDocument.pointerLockElement = null;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;

  class FakeWebSocket extends FakeTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSED = 3;
    readyState = FakeWebSocket.CONNECTING;
    binaryType = "";
    sent = [];
    send(value) { this.sent.push(value); }
    close() { this.readyState = FakeWebSocket.CLOSED; }
  }
  globalThis.WebSocket = FakeWebSocket;

  const sockets = new Map();
  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  canvas.getContext = () => ({});
  canvas.focus = () => {};
  const textInput = new FakeTarget();
  textInput.value = "";
  textInput.focus = () => {};
  const session = new WaymoteSession({
    endpoint: "https://desktop.example.com",
    audio: false,
    createWebSocket(path) {
      const socket = new FakeWebSocket();
      sockets.set(path, socket);
      return socket;
    },
  });
  t.after(() => session.dispose());
  session.attachSurface({ canvas, textInputElement: textInput });
  session.connect();
  await Promise.resolve();
  await Promise.resolve();
  session.input.acquire();
  await Promise.resolve();
  await Promise.resolve();

  const controlSocket = sockets.get("/control");
  controlSocket.readyState = FakeWebSocket.OPEN;
  controlSocket.dispatch("open", {});
  const keyEvent = (type, key, overrides = {}) => canvas.dispatch(type, {
    code: "KeyQ",
    key,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    repeat: false,
    isComposing: false,
    keyCode: 81,
    getModifierState: () => false,
    preventDefault() {},
    stopPropagation() {},
    ...overrides,
  });

  controlSocket.dispatch("message", {
    data: JSON.stringify({ type: "control-state", state: "active" }),
  });
  keyEvent("keydown", "q");
  keyEvent("keyup", "q");
  controlSocket.dispatch("message", {
    data: JSON.stringify({
      type: "control-state",
      state: "active",
      resolvedKeysyms: true,
    }),
  });
  keyEvent("keydown", "'");

  const records = controlSocket.sent.filter((value) => value instanceof ArrayBuffer);
  assert.equal(new DataView(records[0]).getUint32(8, true), 0);
  assert.equal(new DataView(records[2]).getUint32(8, true), 0x27);
  keyEvent("keyup", "'");

  const keyboardRecords = () => controlSocket.sent.map((record) => {
    assert.ok(record instanceof ArrayBuffer, "keyboard input must not invoke clipboard control");
    const view = new DataView(record);
    assert.equal(view.getUint8(1), 4);
    return [view.getUint32(4, true), view.getUint8(2), view.getUint32(8, true)];
  });

  await t.test("repeat follows Shift release without releasing the printable key", () => {
    controlSocket.sent.length = 0;
    keyEvent("keydown", "Shift", { code: "ShiftLeft", shiftKey: true });
    keyEvent("keydown", "@", { code: "Digit2", shiftKey: true });
    keyEvent("keydown", "@", { code: "Digit2", shiftKey: true, repeat: true });
    keyEvent("keyup", "Shift", { code: "ShiftLeft" });
    keyEvent("keydown", "2", { code: "Digit2", repeat: true });
    keyEvent("keyup", "2", { code: "Digit2" });
    assert.deepEqual(keyboardRecords(), [
      [42, 1, 0], [3, 1, 0x40], [3, 2, 0x40], [42, 0, 0], [3, 2, 0x32], [3, 0, 0],
    ]);
  });

  await t.test("AltGraph characters bypass both clipboard shortcut handlers", async () => {
    controlSocket.sent.length = 0;
    const altGraph = {
      ctrlKey: true,
      altKey: true,
      getModifierState: (name) => name === "AltGraph",
    };
    keyEvent("keydown", "@", { ...altGraph, code: "KeyV" });
    keyEvent("keydown", "@", { ...altGraph, code: "KeyV", repeat: true });
    keyEvent("keyup", "@", { ...altGraph, code: "KeyV" });
    keyEvent("keydown", "Ć", { ...altGraph, code: "KeyC", shiftKey: true });
    keyEvent("keyup", "Ć", { ...altGraph, code: "KeyC", shiftKey: true });
    await Promise.resolve();
    await Promise.resolve();
    assert.deepEqual(keyboardRecords(), [
      [47, 1, 0x40], [47, 2, 0x40], [47, 0, 0], [46, 1, 0x01000106], [46, 0, 0],
    ]);
  });

  await t.test("Ctrl, Meta and ordinary Alt shortcuts remain physical", () => {
    for (const modifier of ["ctrlKey", "metaKey", "altKey"]) {
      controlSocket.sent.length = 0;
      keyEvent("keydown", "'", { [modifier]: true });
      keyEvent("keydown", "'", { [modifier]: true, repeat: true });
      keyEvent("keyup", "'", { [modifier]: true });
      assert.deepEqual(keyboardRecords(), [[16, 1, 0], [16, 2, 0], [16, 0, 0]]);
    }
  });

  await t.test("missing capability keeps repeats physical too", () => {
    controlSocket.dispatch("message", {
      data: JSON.stringify({ type: "control-state", state: "active" }),
    });
    controlSocket.sent.length = 0;
    keyEvent("keydown", "@", { code: "Digit2", shiftKey: true });
    keyEvent("keydown", "2", { code: "Digit2", repeat: true });
    keyEvent("keyup", "2", { code: "Digit2" });
    assert.deepEqual(keyboardRecords(), [[3, 1, 0], [3, 2, 0], [3, 0, 0]]);
  });
});

test("session disposal is terminal, idempotent, and disposes its surface", async () => {
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  fakeDocument.pointerLockElement = null;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;

  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  canvas.getContext = () => ({});
  canvas.requestPointerLock = () => Promise.resolve();
  canvas.focus = () => {};
  const textInput = new FakeTarget();
  textInput.value = "";
  textInput.focus = () => {};

  const session = new WaymoteSession();
  const surface = session.attachSurface({ canvas, textInputElement: textInput });
  assert.ok(canvas.listenerCount > 0);
  assert.ok(textInput.listenerCount > 0);
  assert.ok(fakeDocument.listenerCount > 0);

  const first = session.dispose();
  const second = session.dispose();
  assert.equal(first, second);
  await first;

  assert.equal(canvas.listenerCount, 0);
  assert.equal(textInput.listenerCount, 0);
  assert.equal(fakeDocument.listenerCount, 0);
  assert.throws(() => surface.focus(), /disposed/);
  assert.throws(() => session.connect(), /disposed/);
  assert.throws(() => session.attachSurface({ canvas }), /disposed/);
  assert.throws(() => session.on("state", () => {}), /disposed/);
  assert.throws(() => session.input.acquire(), /disposed/);
  assert.throws(() => session.audio.setMuted(true), /disposed/);
  assert.throws(() => session.remoteDisplay.manual(), /disposed/);
  session.disconnect();
});

test("disposal cancels a pending local clipboard paste continuation", async () => {
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  fakeDocument.pointerLockElement = null;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;

  let resolveClipboard;
  const clipboardText = new Promise((resolve) => {
    resolveClipboard = resolve;
  });
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { clipboard: { readText: () => clipboardText } },
  });

  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  canvas.getContext = () => ({});
  canvas.requestPointerLock = () => Promise.resolve();
  canvas.focus = () => {};
  const textInput = new FakeTarget();
  textInput.value = "";
  textInput.focus = () => {};

  const session = new WaymoteSession();
  session.attachSurface({ canvas, textInputElement: textInput });
  const originalWarn = console.warn;
  const warnings = [];
  console.warn = (...values) => warnings.push(values);
  try {
    canvas.dispatch("keydown", {
      code: "KeyV",
      ctrlKey: true,
      metaKey: false,
      shiftKey: false,
      repeat: false,
      isComposing: false,
      keyCode: 86,
      preventDefault() {},
      stopPropagation() {},
    });
    const disposal = session.dispose();
    resolveClipboard("text after disposal");
    await disposal;
    await clipboardText;
    await Promise.resolve();
    await Promise.resolve();
    assert.deepEqual(warnings, []);
  } finally {
    console.warn = originalWarn;
  }
});

test("disconnect invalidates an in-flight audio decoder setup", async () => {
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  fakeWindow.VideoDecoder = true;
  fakeWindow.AudioDecoder = true;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  fakeDocument.pointerLockElement = null;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;

  class FakeWebSocket extends FakeTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSED = 3;
    static sockets = [];

    constructor(url) {
      super();
      this.url = String(url);
      this.readyState = FakeWebSocket.CONNECTING;
      FakeWebSocket.sockets.push(this);
    }

    send() {}

    close(code = 1000, reason = "") {
      if (this.readyState === FakeWebSocket.CLOSED) return;
      this.readyState = FakeWebSocket.CLOSED;
      this.dispatch("close", { code, reason });
    }
  }
  globalThis.WebSocket = FakeWebSocket;

  let resolveSupport;
  let supportRequested;
  const support = new Promise((resolve) => {
    resolveSupport = resolve;
  });
  const supportStarted = new Promise((resolve) => {
    supportRequested = resolve;
  });
  let decoderConstructions = 0;
  globalThis.AudioDecoder = class {
    static isConfigSupported() {
      supportRequested();
      return support;
    }

    constructor() {
      decoderConstructions += 1;
    }
  };

  class FakeAudioContext {
    state = "running";
    destination = {};
    audioWorklet = { addModule: () => Promise.resolve() };

    createGain() {
      return { gain: { value: 1 }, connect() { return this; }, disconnect() {} };
    }

    resume() {
      return Promise.resolve();
    }

    close() {
      this.state = "closed";
      return Promise.resolve();
    }
  }
  globalThis.AudioContext = FakeAudioContext;
  globalThis.AudioWorkletNode = class {
    port = { onmessage: null, postMessage() {} };
    connect(target) { return target; }
    disconnect() {}
  };

  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  canvas.getContext = () => ({});
  canvas.requestPointerLock = () => Promise.resolve();
  canvas.focus = () => {};
  const textInput = new FakeTarget();
  textInput.value = "";
  textInput.focus = () => {};

  const session = new WaymoteSession({ endpoint: "https://desktop.example.com" });
  session.attachSurface({ canvas, textInputElement: textInput });
  session.connect();
  await Promise.resolve();
  const audioSocket = FakeWebSocket.sockets.find((socket) => socket.url.endsWith("/audio"));
  audioSocket.readyState = FakeWebSocket.OPEN;
  audioSocket.dispatch("message", {
    data: JSON.stringify({
      type: "audio-config",
      version: 2,
      enabled: true,
      codec: "opus",
      sampleRate: 48_000,
      channels: 2,
    }),
  });

  const enabling = session.audio.enable();
  await supportStarted;
  const originalWarn = console.warn;
  console.warn = () => {};
  try {
    session.disconnect();
  } finally {
    console.warn = originalWarn;
  }
  resolveSupport({ supported: true });
  await enabling;
  assert.equal(decoderConstructions, 0);
  await session.dispose();
});

test("video keyframes wait for decoder setup and reject stale sessions", async () => {
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  fakeWindow.VideoDecoder = true;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;

  class FakeWebSocket extends FakeTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSED = 3;
    readyState = FakeWebSocket.CONNECTING;
    binaryType = "";
    send() {}
    close() { this.readyState = FakeWebSocket.CLOSED; }
  }
  globalThis.WebSocket = FakeWebSocket;

  const supportResolvers = [];
  let decoderConstructions = 0;
  let decodedFrames = 0;
  globalThis.VideoDecoder = class {
    static isConfigSupported() {
      return new Promise((resolve) => supportResolvers.push(resolve));
    }

    state = "unconfigured";
    decodeQueueSize = 0;

    constructor({ output }) {
      decoderConstructions += 1;
      this.output = output;
    }

    configure() { this.state = "configured"; }
    reset() { this.state = "unconfigured"; }
    close() { this.state = "closed"; }
    decode(chunk) {
      decodedFrames += 1;
      this.output({
        timestamp: chunk.timestamp,
        displayWidth: 1280,
        displayHeight: 720,
        close() {},
      });
    }
  };
  globalThis.EncodedVideoChunk = class {
    constructor(init) { Object.assign(this, init); }
  };
  globalThis.requestAnimationFrame = (callback) => {
    queueMicrotask(callback);
    return 1;
  };
  globalThis.cancelAnimationFrame = () => {};

  const sockets = new Map();
  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  let renderedFrames = 0;
  canvas.getContext = () => ({ drawImage() { renderedFrames += 1; } });
  canvas.focus = () => {};
  const textInput = new FakeTarget();
  textInput.value = "";
  textInput.focus = () => {};
  const session = new WaymoteSession({
    endpoint: "https://desktop.example.com",
    audio: false,
    createWebSocket(path) {
      const socket = new FakeWebSocket();
      sockets.set(path, socket);
      return socket;
    },
  });
  session.attachSurface({ canvas, textInputElement: textInput });
  session.connect();
  await Promise.resolve();
  await Promise.resolve();

  const videoSocket = sockets.get("/stream");
  const keyframe = new ArrayBuffer(41);
  const view = new DataView(keyframe);
  view.setUint8(0, 2);
  view.setUint8(1, 1);
  view.setUint8(2, 1);
  videoSocket.dispatch("message", {
    data: JSON.stringify({ type: "video-config", codec: "avc1.42E01E" }),
  });
  videoSocket.dispatch("message", { data: keyframe });
  assert.equal(decodedFrames, 0);

  supportResolvers.shift()({ supported: true });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(decodedFrames, 1);
  assert.equal(renderedFrames, 1);

  videoSocket.dispatch("message", {
    data: JSON.stringify({ type: "video-config", codec: "avc1.42E01E" }),
  });
  videoSocket.dispatch("message", { data: keyframe });
  session.disconnect();
  supportResolvers.shift()({ supported: true });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(decoderConstructions, 1);
  assert.equal(decodedFrames, 1);
  await session.dispose();
});

async function pendingVideoSetup(t) {
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  fakeWindow.VideoDecoder = true;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;

  class FakeWebSocket extends FakeTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSED = 3;
    readyState = FakeWebSocket.CONNECTING;
    binaryType = "";
    send() {}
    close() { this.readyState = FakeWebSocket.CLOSED; }
  }
  globalThis.WebSocket = FakeWebSocket;

  const setups = [];
  const decodedTimestamps = [];
  globalThis.VideoDecoder = class {
    static isConfigSupported() {
      return new Promise((resolve, reject) => setups.push({ resolve, reject }));
    }
    state = "unconfigured";
    decodeQueueSize = 0;
    configure() { this.state = "configured"; }
    reset() { this.state = "unconfigured"; }
    close() { this.state = "closed"; }
    decode(chunk) { decodedTimestamps.push(chunk.timestamp); }
  };
  globalThis.EncodedVideoChunk = class {
    constructor(init) { Object.assign(this, init); }
  };

  const sockets = new Map();
  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  canvas.getContext = () => ({ drawImage() {} });
  canvas.focus = () => {};
  const textInput = new FakeTarget();
  textInput.value = "";
  textInput.focus = () => {};
  const session = new WaymoteSession({
    endpoint: "https://desktop.example.com",
    audio: false,
    createWebSocket(path) {
      const socket = new FakeWebSocket();
      sockets.set(path, socket);
      return socket;
    },
  });
  session.attachSurface({ canvas, textInputElement: textInput });
  t.after(() => session.dispose());
  session.connect();
  await Promise.resolve();
  await Promise.resolve();

  const message = (timestamp, flags = 0) => {
    const buffer = new ArrayBuffer(41);
    const view = new DataView(buffer);
    view.setUint8(0, 2);
    view.setUint8(1, 1);
    view.setUint8(2, flags);
    view.setBigUint64(12, BigInt(timestamp), true);
    return buffer;
  };
  const configure = (socket = sockets.get("/stream")) => socket.dispatch("message", {
    data: JSON.stringify({ type: "video-config", codec: "avc1.42E01E" }),
  });
  configure();
  return { session, sockets, setups, decodedTimestamps, message, configure };
}

const settleVideoSetup = () => new Promise((resolve) => setImmediate(resolve));

test("video decoder setup retains only the latest bounded frame group", async (t) => {
  const { sockets, setups, decodedTimestamps, message } = await pendingVideoSetup(t);
  const videoSocket = sockets.get("/stream");
  videoSocket.dispatch("message", { data: message(1) });
  videoSocket.dispatch("message", { data: message(2, 1) });
  for (let timestamp = 3; timestamp <= 8; timestamp += 1) {
    videoSocket.dispatch("message", { data: message(timestamp) });
  }
  videoSocket.dispatch("message", { data: message(9) });
  videoSocket.dispatch("message", { data: message(10, 1) });
  videoSocket.dispatch("message", { data: message(11) });

  setups[0].resolve({ supported: true });
  await settleVideoSetup();
  assert.deepEqual(decodedTimestamps, [10, 11]);
});

for (const [name, flags, expected] of [
  ["exactly six contiguous frames", [1, 0, 0, 0, 0, 0], [0, 1, 2, 3, 4, 5]],
  ["overflow before another boundary", [1, 0, 0, 0, 0, 0, 0, 0], []],
  ["leading deltas", [0, 0], []],
  ["a replacement keyframe", [1, 0, 1, 0], [2, 3]],
  ["a discontinuity keyframe", [1, 0, 3, 0], [2, 3]],
  ["a discontinuity without a keyframe", [1, 0, 2, 0], []],
]) {
  test(`video decoder setup handles ${name}`, async (t) => {
    const { sockets, setups, decodedTimestamps, message } = await pendingVideoSetup(t);
    const socket = sockets.get("/stream");
    flags.forEach((flag, timestamp) => socket.dispatch("message", { data: message(timestamp, flag) }));
    setups[0].resolve({ supported: true });
    await settleVideoSetup();
    assert.deepEqual(decodedTimestamps, expected);
    // Live messages must follow the buffered group, not remain queued after setup.
    socket.dispatch("message", { data: message(100, 1) });
    assert.deepEqual(decodedTimestamps, [...expected, 100]);
  });
}

test("video setup rejection closes only the current socket", async (t) => {
  const { session, sockets, setups, decodedTimestamps, message, configure } = await pendingVideoSetup(t);
  const oldSocket = sockets.get("/stream");
  oldSocket.dispatch("message", { data: message(1, 1) });
  session.disconnect();
  session.connect();
  await settleVideoSetup();
  const socket = sockets.get("/stream");
  configure();
  socket.dispatch("message", { data: message(2, 1) });
  // A delayed close/rejection from the old socket must not clear the new queue.
  oldSocket.dispatch("close", { code: 1000 });
  setups[0].reject(new Error("stale setup"));
  setups[1].resolve({ supported: true });
  await settleVideoSetup();
  assert.deepEqual(decodedTimestamps, [2]);
  assert.notEqual(socket.readyState, WebSocket.CLOSED);

  configure();
  socket.dispatch("message", { data: message(3, 1) });
  t.mock.method(console, "error", () => {});
  setups[2].reject(new Error("current setup"));
  await settleVideoSetup();
  assert.equal(socket.readyState, WebSocket.CLOSED);
  assert.deepEqual(decodedTimestamps, [2]);
});

test("superseded video setup cannot flush or close the current setup", async (t) => {
  const { sockets, setups, decodedTimestamps, message, configure } = await pendingVideoSetup(t);
  const socket = sockets.get("/stream");
  socket.dispatch("message", { data: message(1, 1) });
  configure();
  socket.dispatch("message", { data: message(2, 1) });
  configure();
  socket.dispatch("message", { data: message(3, 1) });
  setups[2].resolve({ supported: true });
  await settleVideoSetup();
  setups[0].resolve({ supported: true });
  setups[1].reject(new Error("superseded setup"));
  await settleVideoSetup();
  assert.deepEqual(decodedTimestamps, [3]);
  assert.notEqual(socket.readyState, WebSocket.CLOSED);
});

test("pending video buffers are released before setup settles", async (t) => {
  if (!globalThis.gc) {
    const env = { ...process.env };
    delete env.NODE_TEST_CONTEXT;
    const output = execFileSync(process.execPath, [
      "--expose-gc", "--test", "--test-reporter=tap",
      "--test-name-pattern=^pending video buffers are released before setup settles$",
      fileURLToPath(import.meta.url),
    ], { env, encoding: "utf8", timeout: 30_000 });
    assert.match(output, /# pass 5\b/);
    return;
  }
  for (const action of ["close", "disconnect", "dispose", "replace"]) {
    await t.test(action, async (t) => {
      const { session, sockets, setups, message, configure } = await pendingVideoSetup(t);
      const socket = sockets.get("/stream");
      const enqueue = (timestamp) => {
        const buffer = message(timestamp, timestamp === 0 ? 1 : 0);
        socket.dispatch("message", { data: buffer });
        return new WeakRef(buffer);
      };
      const refs = Array.from({ length: 6 }, (_, timestamp) => enqueue(timestamp));
      if (action === "close") {
        document.hidden = true; // Do not schedule a reconnect during this check.
        t.mock.method(console, "warn", () => {});
        socket.dispatch("close", { code: 1000 });
      } else if (action === "replace") {
        configure();
      } else {
        await session[action]();
      }
      // Keep the setup promise reachable and pending while testing collection.
      for (let i = 0; i < 5; i++) {
        await settleVideoSetup();
        globalThis.gc();
      }
      assert.ok(refs.every((ref) => ref.deref() === undefined), `${action} retained frame buffers`);
      setups.forEach(({ resolve }) => resolve({ supported: true }));
      await settleVideoSetup();
    });
  }
});

test("audio-disabled sessions use the socket factory only for video and control", async () => {
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  fakeWindow.VideoDecoder = true;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;

  class FakeWebSocket extends FakeTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSED = 3;
    readyState = FakeWebSocket.CONNECTING;
    binaryType = "";
    send() {}
    close() { this.readyState = FakeWebSocket.CLOSED; }
  }
  globalThis.WebSocket = FakeWebSocket;

  const paths = [];
  const session = new WaymoteSession({
    endpoint: "https://desktop.example.com",
    audio: false,
    createWebSocket(path) {
      paths.push(path);
      return new FakeWebSocket();
    },
  });
  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  canvas.getContext = () => ({});
  canvas.focus = () => {};
  const textInput = new FakeTarget();
  textInput.value = "";
  textInput.focus = () => {};
  session.attachSurface({ canvas, textInputElement: textInput });
  session.connect();
  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(paths.sort(), ["/control", "/stream"]);
  assert.equal(session.state.audio.state, "unavailable");
  await session.audio.enable();
  assert.deepEqual(paths.sort(), ["/control", "/stream"]);
  await session.dispose();
});

test("reconnect gets fresh sockets and closes late sockets from the prior connection", async () => {
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  fakeWindow.VideoDecoder = true;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;

  class FakeWebSocket extends FakeTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSED = 3;
    readyState = FakeWebSocket.CONNECTING;
    binaryType = "";
    closeCalls = 0;
    send() {}
    close() {
      this.closeCalls += 1;
      this.readyState = FakeWebSocket.CLOSED;
    }
  }
  globalThis.WebSocket = FakeWebSocket;

  const attempts = [];
  const session = new WaymoteSession({
    endpoint: "https://desktop.example.com",
    audio: false,
    createWebSocket(path) {
      let resolve;
      const promise = new Promise((next) => { resolve = next; });
      attempts.push({ path, resolve });
      return promise;
    },
  });
  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  canvas.getContext = () => ({});
  canvas.focus = () => {};
  const textInput = new FakeTarget();
  textInput.value = "";
  textInput.focus = () => {};
  session.attachSurface({ canvas, textInputElement: textInput });

  session.connect();
  await Promise.resolve();
  assert.equal(attempts.length, 2);
  session.disconnect();
  session.connect();
  await Promise.resolve();
  assert.equal(attempts.length, 4);

  const staleSockets = attempts.slice(0, 2).map(() => new FakeWebSocket());
  attempts.slice(0, 2).forEach((attempt, index) => attempt.resolve(staleSockets[index]));
  await Promise.resolve();
  await Promise.resolve();
  assert.ok(staleSockets.every((socket) => socket.closeCalls === 1));

  const currentSockets = attempts.slice(2).map(() => new FakeWebSocket());
  attempts.slice(2).forEach((attempt, index) => attempt.resolve(currentSockets[index]));
  await Promise.resolve();
  await Promise.resolve();
  assert.ok(currentSockets.every((socket) => socket.closeCalls === 0));

  await session.dispose();
  assert.ok(currentSockets.every((socket) => socket.closeCalls === 1));
});

test("visibility changes replace every pending transport socket", async () => {
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  fakeWindow.VideoDecoder = true;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;

  class FakeWebSocket extends FakeTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSED = 3;
    readyState = FakeWebSocket.CONNECTING;
    closeCalls = 0;
    send() {}
    close() {
      this.closeCalls += 1;
      this.readyState = FakeWebSocket.CLOSED;
    }
  }
  globalThis.WebSocket = FakeWebSocket;

  const attempts = [];
  const session = new WaymoteSession({
    endpoint: "https://desktop.example.com",
    createWebSocket(path) {
      let resolve;
      const promise = new Promise((next) => { resolve = next; });
      attempts.push({ path, resolve });
      return promise;
    },
  });
  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  canvas.getContext = () => ({});
  canvas.focus = () => {};
  const textInput = new FakeTarget();
  textInput.value = "";
  textInput.focus = () => {};
  session.attachSurface({ canvas, textInputElement: textInput });

  session.connect();
  await Promise.resolve();
  assert.deepEqual(attempts.map(({ path }) => path).sort(), ["/audio", "/control", "/stream"]);
  fakeDocument.hidden = true;
  fakeDocument.dispatch("visibilitychange", {});
  fakeDocument.hidden = false;
  fakeDocument.dispatch("visibilitychange", {});
  await Promise.resolve();
  assert.equal(attempts.length, 6);

  const staleSockets = attempts.slice(0, 3).map(() => new FakeWebSocket());
  attempts.slice(0, 3).forEach((attempt, index) => attempt.resolve(staleSockets[index]));
  await Promise.resolve();
  await Promise.resolve();
  assert.ok(staleSockets.every((socket) => socket.closeCalls === 1));

  const currentSockets = attempts.slice(3).map(() => new FakeWebSocket());
  attempts.slice(3).forEach((attempt, index) => attempt.resolve(currentSockets[index]));
  await Promise.resolve();
  await Promise.resolve();
  assert.ok(currentSockets.every((socket) => socket.closeCalls === 0));

  await session.dispose();
  assert.ok(currentSockets.every((socket) => socket.closeCalls === 1));
});
