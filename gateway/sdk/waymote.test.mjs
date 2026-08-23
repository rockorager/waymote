import assert from "node:assert/strict";
import test from "node:test";

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
