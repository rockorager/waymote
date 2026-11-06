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

test("keyboard and native clipboard input", async (t) => {
  const navigatorDescriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  const navigator = { platform: "Linux x86_64", clipboard: {
    readText() { assert.fail("paste must not use scripted clipboard reads"); },
  } };
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: navigator });
  t.after(() => {
    if (navigatorDescriptor) Object.defineProperty(globalThis, "navigator", navigatorDescriptor);
    else delete globalThis.navigator;
  });
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
  textInput.focus = t.mock.fn();
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
  const keyEvent = (type, key, overrides = {}, target = canvas) => {
    const event = {
      code: "KeyQ", key, ctrlKey: false, metaKey: false, altKey: false,
      repeat: false, isComposing: false, keyCode: 81,
      getModifierState: () => false,
      defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() {},
      ...overrides,
    };
    target.dispatch(type, event);
    return event;
  };
  const paste = (target, text, types = ["text/plain"]) => {
    const event = {
      clipboardData: text === undefined ? null : { types, getData: () => text },
      defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() {},
    };
    target.dispatch("paste", event);
    return event;
  };
  const messages = () => controlSocket.sent.map((record) => {
    if (typeof record === "string") return JSON.parse(record);
    const view = new DataView(record);
    assert.equal(view.getUint8(1), 4);
    return [view.getUint32(4, true), view.getUint8(2)];
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

  await t.test("Command-V pastes once with Super released and no missing V keyup", () => {
    navigator.platform = "MacIntel";
    controlSocket.sent.length = 0;
    textInput.focus.mock.resetCalls();
    keyEvent("keydown", "Meta", { code: "MetaLeft", metaKey: true });
    assert.equal(keyEvent("keydown", "v", { code: "KeyV", metaKey: true }).defaultPrevented, false);
    assert.equal(textInput.focus.mock.callCount(), 1);
    assert.equal(paste(textInput, "Host-7x!\n雪").defaultPrevented, true);
    assert.equal(keyEvent("keydown", "v", { code: "KeyV", metaKey: true, repeat: true }).defaultPrevented, true);
    // Safari omits the V keyup while Command is held.
    keyEvent("keyup", "Meta", { code: "MetaLeft" }, textInput);
    assert.deepEqual(messages(), [
      [125, 1], { type: "clipboard-write", text: "Host-7x!\n雪" },
      [125, 0], [29, 1], [47, 1], [47, 0], [29, 0], [125, 1], [125, 0],
    ]);
  });

  await t.test("Command-Shift-V restores physically held right-side modifiers", () => {
    controlSocket.sent.length = 0;
    keyEvent("keydown", "Meta", { code: "MetaRight", metaKey: true });
    keyEvent("keydown", "Shift", { code: "ShiftRight", metaKey: true, shiftKey: true });
    keyEvent("keydown", "V", { code: "KeyV", metaKey: true, shiftKey: true });
    paste(textInput, "terminal text");
    keyEvent("keyup", "Meta", { code: "MetaRight", shiftKey: true });
    keyEvent("keyup", "Shift", { code: "ShiftRight" });
    assert.deepEqual(messages(), [
      [126, 1], [54, 1], { type: "clipboard-write", text: "terminal text" },
      [126, 0], [54, 0], [29, 1], [42, 1], [47, 1], [47, 0], [29, 0], [42, 0],
      [126, 1], [54, 1], [126, 0], [54, 0],
    ]);
  });

  await t.test("Ctrl-V on macOS remains ordinary remote input", () => {
    controlSocket.sent.length = 0;
    textInput.focus.mock.resetCalls();
    keyEvent("keydown", "Control", { code: "ControlLeft", ctrlKey: true });
    assert.equal(keyEvent("keydown", "v", { code: "KeyV", ctrlKey: true }).defaultPrevented, true);
    keyEvent("keyup", "v", { code: "KeyV", ctrlKey: true });
    keyEvent("keyup", "Control", { code: "ControlLeft" });
    assert.equal(textInput.focus.mock.callCount(), 0);
    assert.deepEqual(messages(), [[29, 1], [47, 1], [47, 0], [29, 0]]);
  });

  await t.test("Command release clears lost letter keyups but not modifiers", () => {
    for (const [code, linuxKey] of [["MetaLeft", 125], ["MetaRight", 126]]) {
      controlSocket.sent.length = 0;
      keyEvent("keydown", "Shift", { code: "ShiftLeft", shiftKey: true });
      keyEvent("keydown", "Meta", { code, metaKey: true, shiftKey: true });
      keyEvent("keydown", "Z", { code: "KeyZ", metaKey: true, shiftKey: true });
      keyEvent("keydown", "ArrowLeft", { code: "ArrowLeft", metaKey: true, shiftKey: true });
      keyEvent("keyup", "Meta", { code, shiftKey: true });
      // Late keyups from browsers that do deliver them must not release twice.
      keyEvent("keyup", "Z", { code: "KeyZ", shiftKey: true });
      keyEvent("keyup", "ArrowLeft", { code: "ArrowLeft", shiftKey: true });
      keyEvent("keyup", "Shift", { code: "ShiftLeft" });
      assert.deepEqual(messages(), [
        [42, 1], [linuxKey, 1], [44, 1], [105, 1], [44, 0], [105, 0], [linuxKey, 0], [42, 0],
      ]);
    }
  });

  await t.test("Linux Super release leaves other held keys alone", () => {
    navigator.platform = "Linux x86_64";
    controlSocket.sent.length = 0;
    keyEvent("keydown", "Meta", { code: "MetaLeft", metaKey: true });
    keyEvent("keydown", "ArrowLeft", { code: "ArrowLeft", metaKey: true });
    keyEvent("keyup", "Meta", { code: "MetaLeft" });
    assert.deepEqual(messages(), [[125, 1], [105, 1], [125, 0]]);
    keyEvent("keyup", "ArrowLeft", { code: "ArrowLeft" });
    assert.deepEqual(messages().at(-1), [105, 0]);
  });

  await t.test("fresh presses repair lost keyups and retain resolved keysyms", () => {
    controlSocket.dispatch("message", {
      data: JSON.stringify({ type: "control-state", state: "active", resolvedKeysyms: true }),
    });
    controlSocket.sent.length = 0;
    keyEvent("keydown", "q");
    keyEvent("keydown", "'");
    keyEvent("keyup", "'");
    assert.deepEqual(keyboardRecords(), [[16, 1, 0x71], [16, 0, 0], [16, 1, 0x27], [16, 0, 0]]);
  });

  await t.test("Linux Ctrl-Shift-V on the IME proxy uses native paste", () => {
    controlSocket.sent.length = 0;
    keyEvent("keydown", "Control", { code: "ControlLeft", ctrlKey: true }, textInput);
    keyEvent("keydown", "Shift", { code: "ShiftLeft", ctrlKey: true, shiftKey: true }, textInput);
    assert.equal(keyEvent("keydown", "V", {
      code: "KeyV", ctrlKey: true, shiftKey: true,
    }, textInput).defaultPrevented, false);
    paste(textInput, "one paste");
    keyEvent("keyup", "V", { code: "KeyV", ctrlKey: true, shiftKey: true }, textInput);
    keyEvent("keyup", "Shift", { code: "ShiftLeft", ctrlKey: true }, textInput);
    keyEvent("keyup", "Control", { code: "ControlLeft" }, textInput);
    assert.deepEqual(messages(), [
      [29, 1], [42, 1], { type: "clipboard-write", text: "one paste" },
      [29, 1], [42, 1], [47, 1], [47, 0], [42, 0], [29, 0],
    ]);
  });

  await t.test("extra Meta or Alt prevents Linux platform paste handling", () => {
    for (const modifier of ["metaKey", "altKey"]) {
      controlSocket.sent.length = 0;
      assert.equal(keyEvent("keydown", "v", {
        code: "KeyV", ctrlKey: true, [modifier]: true,
      }).defaultPrevented, true);
      keyEvent("keyup", "v", { code: "KeyV" });
      assert.deepEqual(messages(), [[47, 1], [47, 0]]);
    }
  });

  await t.test("absent text never pastes stale data; empty text and WebKit types work", () => {
    controlSocket.sent.length = 0;
    keyEvent("keydown", "V", { code: "KeyV", ctrlKey: true, shiftKey: true });
    keyEvent("keyup", "V", { code: "KeyV" });
    paste(canvas, undefined);
    paste(canvas, "", ["image/png"]);
    assert.deepEqual(messages(), []);
    for (const [text, types] of [["", ["text/plain"]], ["WebKit-6x!", []]]) {
      controlSocket.sent.length = 0;
      assert.equal(paste(canvas, text, types).defaultPrevented, true);
      assert.deepEqual(messages(), [
        { type: "clipboard-write", text }, [29, 1], [47, 1], [47, 0], [29, 0],
      ]);
    }
  });

  await t.test("paste enforces the UTF-8 byte limit before sending keys", () => {
    controlSocket.sent.length = 0;
    const text = "é".repeat(512 * 1024);
    paste(canvas, text);
    assert.deepEqual(messages(), [
      { type: "clipboard-write", text }, [29, 1], [47, 1], [47, 0], [29, 0],
    ]);
    controlSocket.sent.length = 0;
    paste(canvas, text + "é");
    assert.deepEqual(messages(), []);
  });

  await t.test("release and disposal cancel a pending native paste shortcut", async () => {
    keyEvent("keydown", "V", { code: "KeyV", ctrlKey: true, shiftKey: true });
    session.input.release();
    session.input.acquire();
    controlSocket.dispatch("message", {
      data: JSON.stringify({ type: "control-state", state: "active" }),
    });
    controlSocket.sent.length = 0;
    paste(textInput, "menu paste after release");
    assert.deepEqual(messages(), [
      { type: "clipboard-write", text: "menu paste after release" },
      [29, 1], [47, 1], [47, 0], [29, 0],
    ]);
    session.input.release();
    controlSocket.sent.length = 0;
    paste(textInput, "not sent");
    assert.deepEqual(messages(), []);
    keyEvent("keydown", "v", { code: "KeyV", ctrlKey: true });
    await session.dispose();
    controlSocket.sent.length = 0;
    paste(textInput, "after disposal");
    paste(canvas, "after disposal");
    assert.deepEqual(messages(), []);
    assert.equal(textInput.listenerCount, 0);
    assert.equal(canvas.listenerCount, 0);
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

async function pendingVideoSetup(t, configuration = {}) {
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
    sent = [];
    send(data) { this.sent.push(data); }
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
    data: JSON.stringify({ type: "video-config", codec: "avc1.42E01E", ...configuration }),
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

for (const [name, configuration, expected] of [
  ["requests keyframes from servers that accept them", { keyframeRequests: true },
    [{ type: "keyframe-requests" }, { type: "keyframe" }]],
  ["sends nothing to servers that do not accept keyframe requests", {}, []],
]) {
  test(`video decoder ${name}`, async (t) => {
    const { sockets, setups, decodedTimestamps, message } = await pendingVideoSetup(t, configuration);
    const socket = sockets.get("/stream");
    socket.readyState = WebSocket.OPEN;
    setups[0].resolve({ supported: true });
    await settleVideoSetup();
    socket.dispatch("message", { data: message(1, 1) });
    socket.dispatch("message", { data: message(2, 2) });
    socket.dispatch("message", { data: message(3) });
    socket.dispatch("message", { data: message(4, 1) });
    assert.deepEqual(decodedTimestamps, [1, 4]);
    assert.deepEqual(socket.sent.map((data) => JSON.parse(data)), expected);
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

async function controlledSession(t, { platform = "Linux x86_64", ...options } = {}) {
  const navigatorDescriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  const navigator = { platform };
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: navigator });
  t.after(() => {
    if (navigatorDescriptor) Object.defineProperty(globalThis, "navigator", navigatorDescriptor);
    else delete globalThis.navigator;
  });
  const fakeWindow = new FakeTarget();
  fakeWindow.devicePixelRatio = 1;
  fakeWindow.VideoDecoder = true;
  const fakeDocument = new FakeTarget();
  fakeDocument.hidden = false;
  fakeDocument.pointerLockElement = null;
  fakeDocument.hasFocus = () => true;
  fakeDocument.exitPointerLock = () => { fakeDocument.pointerLockElement = null; };
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
  const animationFrames = [];
  globalThis.requestAnimationFrame = (callback) => animationFrames.push(callback);
  globalThis.cancelAnimationFrame = () => {};

  const sockets = new Map();
  const canvas = new FakeTarget();
  canvas.width = 1280;
  canvas.height = 720;
  canvas.bounds = { left: 0, top: 0, width: 1280, height: 720 };
  canvas.getBoundingClientRect = () => canvas.bounds;
  canvas.getContext = () => ({ drawImage() {} });
  canvas.focus = () => {};
  canvas.setPointerCapture = () => {};
  canvas.hasPointerCapture = () => false;
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
    ...options,
  });
  t.after(() => session.dispose());
  session.attachSurface({ canvas, textInputElement: textInput, clipboardAutoSync: true });
  session.connect();
  await Promise.resolve();
  await Promise.resolve();
  session.input.acquire();
  await Promise.resolve();
  await Promise.resolve();

  const control = sockets.get("/control");
  control.readyState = FakeWebSocket.OPEN;
  control.dispatch("open", {});
  const receive = (message) => control.dispatch("message", { data: JSON.stringify(message) });
  receive({ type: "control-state", state: "active" });
  control.sent.length = 0;

  const keyEvent = (type, code, overrides = {}, target = canvas) => {
    const event = {
      code, key: "", ctrlKey: false, metaKey: false, altKey: false, shiftKey: false,
      repeat: false, isComposing: false, keyCode: 0,
      currentTarget: target,
      getModifierState: () => false,
      defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() {},
      ...overrides,
    };
    target.dispatch(type, event);
    return event;
  };
  const pointerEvent = (type, clientX, clientY, button = 0) => {
    const event = {
      clientX, clientY, button, pointerId: 1,
      preventDefault() {},
    };
    canvas.dispatch(type, event);
    return event;
  };
  const paste = (text, target = textInput) => {
    const event = {
      clipboardData: { types: ["text/plain"], getData: () => text },
      defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() {},
    };
    target.dispatch("paste", event);
    return event;
  };
  const beforeInput = (data) => {
    const event = {
      inputType: "insertText", data, isComposing: false,
      defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; },
    };
    textInput.dispatch("beforeinput", event);
    return event;
  };
  // Keyboard records become [key, state], other records name their type, and
  // JSON messages are parsed.
  const recordNames = { 1: "motion", 2: "button", 5: "release-all", 6: "resize" };
  const messages = () => control.sent.map((record) => {
    if (typeof record === "string") {
      return record.startsWith("{") ? JSON.parse(record) : record;
    }
    const view = new DataView(record);
    const type = view.getUint8(1);
    if (type === 4) return [view.getUint32(4, true), view.getUint8(2)];
    if (type === 1) return ["motion", view.getUint32(4, true), view.getUint32(8, true)];
    if (type === 2) return ["button", view.getUint32(4, true), view.getUint8(2)];
    return recordNames[type] ?? type;
  });
  return {
    session, navigator, canvas, textInput, control, sockets, animationFrames,
    receive, keyEvent, pointerEvent, paste, beforeInput, messages,
  };
}

test("pointer capture discards a queued absolute position", async (t) => {
  const { canvas, animationFrames, pointerEvent, messages } = await controlledSession(t);
  pointerEvent("pointermove", 320, 180);
  assert.equal(animationFrames.length, 1);
  document.pointerLockElement = canvas;
  document.dispatch("pointerlockchange", {});
  animationFrames.shift()();
  assert.deepEqual(messages(), []);
});

test("a click is not followed by a motion queued against an earlier layout", async (t) => {
  const { canvas, animationFrames, pointerEvent, messages } = await controlledSession(t);
  pointerEvent("pointermove", 320, 180);
  canvas.bounds = { left: 640, top: 0, width: 640, height: 360 };
  pointerEvent("pointerdown", 960, 180);
  animationFrames.shift()();
  assert.deepEqual(messages(), [["motion", 32768, 32768], ["button", 0x110, 1]]);
});

test("a macOS remote pastes with its own Command-V shortcut", async (t) => {
  await t.test("from Command-V on a Mac host", async (t) => {
    const { keyEvent, paste, messages } = await controlledSession(t, {
      platform: "MacIntel", remotePlatform: "macos",
    });
    keyEvent("keydown", "MetaLeft", { metaKey: true });
    keyEvent("keydown", "KeyV", { metaKey: true });
    paste("for the Mac");
    keyEvent("keyup", "MetaLeft");
    // Command is the remote paste modifier, so it stays held through the tap.
    assert.deepEqual(messages(), [
      [125, 1], { type: "clipboard-write", text: "for the Mac" },
      [125, 1], [47, 1], [47, 0], [125, 0],
    ]);
  });

  await t.test("from Ctrl-V on a Linux host", async (t) => {
    const { keyEvent, paste, messages } = await controlledSession(t, { remotePlatform: "macos" });
    keyEvent("keydown", "ControlLeft", { ctrlKey: true });
    keyEvent("keydown", "KeyV", { ctrlKey: true });
    paste("from Linux");
    keyEvent("keyup", "KeyV");
    keyEvent("keyup", "ControlLeft");
    assert.deepEqual(messages(), [
      [29, 1], { type: "clipboard-write", text: "from Linux" },
      [29, 0], [125, 1], [47, 1], [47, 0], [125, 0], [29, 1], [29, 0],
    ]);
  });

  await t.test("with Shift and from a menu paste", async (t) => {
    const { keyEvent, paste, messages, control } = await controlledSession(t, {
      platform: "MacIntel", remotePlatform: "macos",
    });
    keyEvent("keydown", "MetaLeft", { metaKey: true });
    keyEvent("keydown", "ShiftLeft", { metaKey: true, shiftKey: true });
    keyEvent("keydown", "KeyV", { metaKey: true, shiftKey: true });
    control.sent.length = 0;
    paste("plain text");
    assert.deepEqual(messages(), [
      { type: "clipboard-write", text: "plain text" }, [125, 1], [42, 1], [47, 1], [47, 0],
    ]);
    keyEvent("keyup", "ShiftLeft", { metaKey: true });
    keyEvent("keyup", "MetaLeft");
    control.sent.length = 0;
    paste("menu");
    assert.deepEqual(messages(), [
      { type: "clipboard-write", text: "menu" }, [125, 1], [47, 1], [47, 0], [125, 0],
    ]);
  });
});

test("remote platforms other than linux and macos are rejected", () => {
  assert.throws(() => new WaymoteSession({ remotePlatform: "darwin" }), /Unknown remote platform/);
});

test("clipboard replays after a control claim do not overwrite the host clipboard", async (t) => {
  const { session, navigator, receive, control } = await controlledSession(t);
  const written = [];
  navigator.clipboard = { writeText: async (text) => { written.push(text); } };
  const remoteCopy = (text) => receive({ type: "clipboard", text });

  // The replay may arrive on either side of the control-state reply.
  remoteCopy("Replayed on connect");
  remoteCopy("First remote copy");
  for (const replayFirst of [true, false]) {
    session.input.release();
    session.input.acquire();
    if (replayFirst) remoteCopy("Replayed on acquire");
    receive({ type: "control-state", state: "active" });
    if (!replayFirst) remoteCopy("Replayed on acquire");
  }
  // The gateway hands control back after another viewer releases it.
  receive({ type: "control-state", state: "ready" });
  assert.equal(control.sent.at(-1), "acquire");
  remoteCopy("Replayed after ready");
  receive({ type: "control-state", state: "active" });
  // Acquiring while already active is only a confirmation without a replay.
  session.input.acquire();
  receive({ type: "control-state", state: "active" });
  remoteCopy("Second remote copy");
  remoteCopy("Second remote copy");
  assert.deepEqual(written, ["First remote copy", "Second remote copy", "Second remote copy"]);
  assert.equal(session.clipboard.latestRemoteText, "Second remote copy");
});

test("Command and Control can be swapped for hardware keys", async (t) => {
  await t.test("on both sides, toggled at runtime", async (t) => {
    const { session, keyEvent, messages } = await controlledSession(t, { platform: "MacIntel" });
    session.input.setSwapCommandControl(true);
    for (const [code, flag] of [["MetaLeft", "metaKey"], ["MetaRight", "metaKey"],
      ["ControlLeft", "ctrlKey"], ["ControlRight", "ctrlKey"]]) {
      keyEvent("keydown", code, { [flag]: true });
      keyEvent("keydown", "KeyT", { [flag]: true });
      keyEvent("keyup", "KeyT", { [flag]: true });
      keyEvent("keyup", code);
    }
    session.input.setSwapCommandControl(false);
    keyEvent("keydown", "MetaLeft", { metaKey: true });
    keyEvent("keyup", "MetaLeft");
    assert.deepEqual(messages(), [
      [29, 1], [20, 1], [20, 0], [29, 0],
      [97, 1], [20, 1], [20, 0], [97, 0],
      [125, 1], [20, 1], [20, 0], [125, 0],
      [126, 1], [20, 1], [20, 0], [126, 0],
      [125, 1], [125, 0],
    ]);
  });

  await t.test("without leaving a held key pressed when toggled", async (t) => {
    const { session, keyEvent, messages } = await controlledSession(t);
    session.input.setSwapCommandControl(true);
    keyEvent("keydown", "MetaLeft", { metaKey: true });
    keyEvent("keydown", "ShiftLeft", { metaKey: true, shiftKey: true });
    session.input.setSwapCommandControl(false);
    keyEvent("keyup", "MetaLeft", { shiftKey: true });
    keyEvent("keyup", "ShiftLeft");
    assert.deepEqual(messages(), [[29, 1], [42, 1], [29, 0], [42, 0]]);
  });

  await t.test("for modifier flags without a tracked keydown", async (t) => {
    const { session, keyEvent, messages, control } = await controlledSession(t, {
      platform: "MacIntel",
    });
    session.input.setSwapCommandControl(true);
    keyEvent("keydown", "KeyC", { metaKey: true, shiftKey: true });
    keyEvent("keyup", "KeyC");
    keyEvent("keydown", "KeyC", { ctrlKey: true, shiftKey: true });
    keyEvent("keyup", "KeyC");
    assert.deepEqual(messages(), [
      [42, 1], [29, 1], [46, 1], [46, 0], [42, 0], [29, 0],
      [125, 1], [42, 1], [46, 1], [46, 0], [125, 0], [42, 0],
    ]);
    control.sent.length = 0;
    session.input.setSwapCommandControl(false);
    keyEvent("keydown", "KeyC", { metaKey: true, shiftKey: true });
    assert.deepEqual(messages(), [[42, 1], [125, 1], [46, 1], [46, 0], [42, 0], [125, 0]]);
  });

  await t.test("while the Mac paste gesture still pastes", async (t) => {
    const { session, keyEvent, paste, messages } = await controlledSession(t, {
      platform: "MacIntel",
    });
    session.input.setSwapCommandControl(true);
    keyEvent("keydown", "MetaLeft", { metaKey: true });
    keyEvent("keydown", "KeyV", { metaKey: true });
    paste("swapped");
    keyEvent("keyup", "MetaLeft");
    // The swapped Command already is the Linux paste modifier, so nothing is released.
    assert.deepEqual(messages(), [
      [29, 1], { type: "clipboard-write", text: "swapped" },
      [29, 1], [47, 1], [47, 0], [29, 0],
    ]);
  });
});

test("sticky modifiers and tapped keys for on-screen key strips", async (t) => {
  await t.test("tapKey consumes the latch and reports it in the input state", async (t) => {
    const { session, messages } = await controlledSession(t);
    const latched = [];
    session.on("state", (state) => latched.push(state.input.stickyModifiers));
    session.input.setStickyModifiers([125, 15, 125]);
    session.input.setStickyModifiers([125]);
    assert.deepEqual(session.state.input.stickyModifiers, [125]);
    assert.equal(session.input.tapKey(15, [56]), true);
    assert.deepEqual(session.state.input.stickyModifiers, []);
    assert.deepEqual(latched, [[125], []]);
    assert.deepEqual(messages(), [[56, 1], [125, 1], [15, 1], [15, 0], [56, 0], [125, 0]]);
  });

  await t.test("a lone modifier tap keeps the latch and held keys stay held", async (t) => {
    const { session, keyEvent, messages, control } = await controlledSession(t);
    session.input.setStickyModifiers([42]);
    session.input.tapKey(125);
    assert.deepEqual(session.state.input.stickyModifiers, [42]);
    assert.deepEqual(messages(), [[125, 1], [125, 0]]);
    session.input.setStickyModifiers([]);
    keyEvent("keydown", "ShiftLeft", { shiftKey: true });
    control.sent.length = 0;
    session.input.tapKey(15, [42]);
    assert.deepEqual(messages(), [[42, 1], [15, 1], [15, 0]]);
    assert.throws(() => session.input.tapKey(256), RangeError);
    assert.throws(() => session.input.tapKey(15, [Number.NaN]), RangeError);
  });

  await t.test("the latch wraps the next hardware key and is released with it", async (t) => {
    const { session, keyEvent, messages } = await controlledSession(t);
    session.input.setStickyModifiers([125]);
    keyEvent("keydown", "ShiftLeft", { shiftKey: true });
    assert.deepEqual(session.state.input.stickyModifiers, [125]);
    session.input.setStickyModifiers([29, 42]);
    keyEvent("keydown", "KeyA", { key: "A", shiftKey: true });
    assert.deepEqual(session.state.input.stickyModifiers, []);
    keyEvent("keyup", "KeyA", { key: "A", shiftKey: true });
    keyEvent("keydown", "KeyB", { key: "B", shiftKey: true });
    keyEvent("keyup", "KeyB", { key: "B", shiftKey: true });
    keyEvent("keyup", "ShiftLeft");
    // Shift is physically held, so only the user's keyup releases it.
    assert.deepEqual(messages(), [
      [42, 1], [29, 1], [30, 1], [30, 0], [29, 0], [48, 1], [48, 0], [42, 0],
    ]);
  });

  await t.test("Command release on Apple also releases the latch of a lost keyup", async (t) => {
    const { session, keyEvent, messages } = await controlledSession(t, { platform: "MacIntel" });
    keyEvent("keydown", "MetaLeft", { metaKey: true });
    session.input.setStickyModifiers([56]);
    keyEvent("keydown", "KeyZ", { metaKey: true });
    keyEvent("keyup", "MetaLeft");
    keyEvent("keyup", "KeyZ");
    assert.deepEqual(messages(), [[125, 1], [56, 1], [44, 1], [44, 0], [56, 0], [125, 0]]);
  });

  await t.test("characters typed with a latch become shortcut keys", async (t) => {
    const { session, beforeInput, messages } = await controlledSession(t);
    session.input.setStickyModifiers([125]);
    assert.equal(beforeInput("c").defaultPrevented, true);
    session.input.setStickyModifiers([29]);
    beforeInput("?");
    beforeInput("x");
    session.input.setStickyModifiers([29]);
    beforeInput("é");
    assert.deepEqual(session.state.input.stickyModifiers, [29]);
    assert.deepEqual(messages().map((message) => message.text ?? message), [
      [125, 1], [46, 1], [46, 0], [125, 0],
      [42, 1], [29, 1], [53, 1], [53, 0], [42, 0], [29, 0],
      "x", "é",
    ]);
  });

  await t.test("losing control clears the latch and disables tapping", async (t) => {
    const { session, receive, messages } = await controlledSession(t);
    session.input.setStickyModifiers([125]);
    receive({ type: "control-state", state: "busy" });
    assert.deepEqual(session.state.input.stickyModifiers, []);
    assert.equal(session.input.tapKey(15), false);
    assert.equal(session.input.pasteText("not sent"), false);
    receive({ type: "control-state", state: "active" });
    session.input.setStickyModifiers([125]);
    session.input.release();
    assert.deepEqual(session.state.input.stickyModifiers, []);
    assert.deepEqual(messages().filter((message) => Array.isArray(message)), []);
  });

  await t.test("pasteText taps the remote paste shortcut", async (t) => {
    const { session, messages } = await controlledSession(t, { remotePlatform: "macos" });
    assert.equal(session.input.pasteText("from the strip"), true);
    assert.equal(session.input.pasteText("é".repeat(512 * 1024 + 1)), false);
    assert.deepEqual(messages(), [
      { type: "clipboard-write", text: "from the strip" }, [125, 1], [47, 1], [47, 0], [125, 0],
    ]);
  });
});

test("iOS keyboard symbols are typed as text without resolved keysyms", async (t) => {
  const { receive, keyEvent, beforeInput, textInput, messages, control } = await controlledSession(t);
  const softKey = (code, character, shiftKey) => {
    keyEvent("keydown", code, { key: character, shiftKey }, textInput);
    beforeInput(character);
    keyEvent("keyup", code, { key: character }, textInput);
  };
  const sent = () => messages().map((message) => message.text ?? message);
  // The iOS keyboard sends Shift then "A" on the letters page, "!" on the 123
  // page as Digit1 without Shift, and "'" on the #+= page with Shift held.
  keyEvent("keydown", "ShiftLeft", { key: "Shift", shiftKey: true }, textInput);
  softKey("KeyA", "A", true);
  keyEvent("keyup", "ShiftLeft", { key: "Shift" }, textInput);
  softKey("Digit1", "!", false);
  keyEvent("keydown", "ShiftLeft", { key: "Shift", shiftKey: true }, textInput);
  softKey("Quote", "'", true);
  keyEvent("keyup", "ShiftLeft", { key: "Shift" }, textInput);
  // A hardware keyboard on the canvas keeps physical keys.
  keyEvent("keydown", "Digit1", { key: "!" });
  keyEvent("keyup", "Digit1", { key: "!" });
  assert.deepEqual(sent(), [
    [42, 1], [30, 1], [30, 0], [42, 0], "!", [42, 1], "'", [42, 0], [2, 1], [2, 0],
  ]);

  receive({ type: "control-state", state: "active", resolvedKeysyms: true });
  control.sent.length = 0;
  softKey("Digit1", "!", false);
  assert.deepEqual(sent(), [[2, 1], [2, 0]]);
});

const hostDisplays = [
  { id: "7", name: "Built-in Retina Display", width: 3024, height: 1964, isMain: true },
  { id: "42", name: "Portrait", width: 1200, height: 2000, isMain: false },
];

async function displaySession(t, options) {
  const context = await controlledSession(t, options);
  const decoders = [];
  const closedFrames = [];
  globalThis.EncodedVideoChunk = class {
    constructor(init) { Object.assign(this, init); }
  };
  globalThis.VideoDecoder = class {
    static async isConfigSupported() { return { supported: true }; }
    state = "unconfigured";
    decodeQueueSize = 0;
    constructor({ output }) {
      this.output = output;
      decoders.push(this);
    }
    configure() { this.state = "configured"; }
    reset() { this.state = "unconfigured"; }
    close() { this.state = "closed"; }
    decode(chunk) {
      const size = new DataView(chunk.data.buffer, chunk.data.byteOffset);
      this.output(frame(chunk.timestamp, size.getUint16(0, true), size.getUint16(2, true)));
    }
  };
  const frame = (timestamp, displayWidth, displayHeight) => ({
    timestamp, displayWidth, displayHeight,
    close() { closedFrames.push(timestamp); },
  });
  const video = context.sockets.get("/stream");
  video.dispatch("message", {
    data: JSON.stringify({ type: "video-config", codec: "avc1.42E01E" }),
  });
  await settleVideoSetup();
  const states = [];
  context.session.on("displays", (state) => states.push(state));
  return {
    ...context, decoders, closedFrames, frame, states,
    displayState(selectedID, generation, switching = false, extra = {}) {
      context.receive({
        type: "display-state", displays: hostDisplays, selectedID, generation, switching, ...extra,
      });
    },
    queueFrame(generation, width, height) {
      const buffer = new ArrayBuffer(44);
      const header = new DataView(buffer);
      header.setUint8(0, 2);
      header.setUint8(1, 1);
      header.setUint8(2, 1);
      header.setBigUint64(12, BigInt(generation * 1000), true);
      header.setUint32(20, generation, true);
      header.setUint16(40, width, true);
      header.setUint16(42, height, true);
      video.dispatch("message", { data: buffer });
    },
    paint() {
      for (const callback of context.animationFrames.splice(0)) callback(0);
    },
  };
}

test("display selection resumes input only after the new display is drawn", async (t) => {
  const {
    session, control, canvas, keyEvent, pointerEvent, beforeInput, paste, messages, states,
    displayState, queueFrame, paint,
  } = await displaySession(t);
  displayState("7", 3);
  assert.equal(session.displays.state.switching, true);
  queueFrame(3, 1600, 900);
  paint();
  assert.equal(session.displays.state.switching, false);
  keyEvent("keydown", "KeyA", { key: "a" });
  control.sent.length = 0;

  assert.equal(session.displays.select("42"), true);
  assert.deepEqual(messages(), ["release-all", { type: "display-select", id: "42" }]);
  displayState("42", 5);
  control.sent.length = 0;
  // A frame of the old generation does not end the switch.
  queueFrame(3, 1600, 900);
  paint();
  assert.equal(session.displays.select("7"), false);
  session.input.setStickyModifiers([125]);
  beforeInput("c");
  assert.deepEqual(session.state.input.stickyModifiers, [125]);
  beforeInput("x");
  keyEvent("keydown", "KeyB", { key: "b" });
  pointerEvent("pointerdown", 640, 360);
  assert.equal(session.input.tapKey(15), false);
  assert.equal(session.input.pasteText("while switching"), false);
  assert.equal(session.clipboard.sendText("while switching"), false);
  paste("while switching");
  queueFrame(5, 600, 1000);
  assert.equal(session.displays.state.switching, true);
  assert.deepEqual(messages(), []);

  paint();
  assert.equal(session.displays.state.switching, false);
  assert.deepEqual(session.state.input.stickyModifiers, []);
  assert.deepEqual(messages(), [{ type: "display-presented", generation: 5 }]);
  assert.deepEqual(states.map(({ selectedID, switching }) => [selectedID, switching]), [
    ["7", true], ["7", false], ["7", true], ["42", true], ["42", false],
  ]);
  // Keys and buttons pressed during the switch are not held afterwards, and
  // the pointer maps into the portrait display's letterboxed area.
  control.sent.length = 0;
  keyEvent("keyup", "KeyB", { key: "b" });
  pointerEvent("pointerup", 640, 360);
  canvas.bounds = { left: 100, top: 20, width: 800, height: 600 };
  pointerEvent("pointerdown", 410, 470);
  assert.deepEqual(messages(), [["motion", 16384, 49151], ["button", 0x110, 1]]);
});

test("display selection stays inert until the server advertises it", async (t) => {
  const { session, control, receive, messages, states, displayState, queueFrame, paint } =
    await displaySession(t);
  assert.equal(session.displays.state, null);
  assert.equal(session.displays.select("42"), false);
  queueFrame(3, 1600, 900);
  paint();
  displayState("missing", 3);
  displayState("7", 3, false, { displays: [{ id: "7", name: "No size", isMain: true }] });
  receive({ type: "display-state", displays: hostDisplays, selectedID: "7", generation: -1, switching: false });
  assert.equal(session.displays.state, null);
  assert.deepEqual(messages(), []);
  assert.deepEqual(states, []);

  displayState("7", 3, false, { error: "Display 42 disconnected" });
  assert.deepEqual(session.displays.state, {
    displays: hostDisplays, selectedID: "7", generation: 3, switching: false,
    error: "Display 42 disconnected",
  });
  control.sent.length = 0;
  assert.equal(session.displays.select("missing"), false);
  assert.equal(session.displays.select("7"), true);
  assert.deepEqual(messages(), []);
  control.dispatch("close", { code: 1006 });
  assert.equal(session.displays.state, null);
  assert.equal(session.displays.select("42"), false);
  // The display was already drawn, so it is acknowledged at once.
  assert.deepEqual(states.map((state) => state && [state.selectedID, state.switching]), [
    ["7", true], ["7", false], null,
  ]);
});

test("display selection reacquires control and yields to another viewer", async (t) => {
  const { session, control, receive, messages, displayState, queueFrame, paint } =
    await displaySession(t);
  queueFrame(3, 1600, 900);
  paint();
  displayState("7", 3);
  session.input.release();
  control.sent.length = 0;
  assert.equal(session.displays.select("42"), true);
  assert.deepEqual(messages(), ["acquire"]);
  receive({ type: "control-state", state: "busy" });
  assert.equal(session.displays.state.switching, false);
  assert.equal(session.displays.state.error, "Another viewer is controlling the desktop.");
  receive({ type: "control-state", state: "active" });
  assert.deepEqual(messages(), ["acquire"]);

  session.input.release();
  control.sent.length = 0;
  assert.equal(session.displays.select("42"), true);
  assert.equal(session.displays.state.error, null);
  receive({ type: "control-state", state: "active" });
  assert.deepEqual(messages(), [
    "acquire", "release-all", { type: "display-select", id: "42" },
  ]);
});

test("a host display change may arrive on video before its display-state", async (t) => {
  const {
    session, canvas, control, messages, closedFrames, displayState, queueFrame, paint,
  } = await displaySession(t);
  displayState("7", 3);
  queueFrame(3, 1600, 900);
  paint();
  displayState("7", 3, true);
  control.sent.length = 0;
  assert.equal(session.displays.select("42"), false);
  queueFrame(4, 1600, 900);
  closedFrames.length = 0;
  // The generation change drops frames of the old generation before drawing.
  queueFrame(6, 600, 1000);
  assert.deepEqual(closedFrames, [4000]);
  paint();
  assert.equal(session.displays.state.switching, true);
  assert.deepEqual(messages(), []);
  displayState("42", 5);
  assert.deepEqual([session.displays.state.selectedID, session.displays.state.switching], ["42", false]);
  assert.deepEqual([canvas.width, canvas.height], [600, 1000]);
  assert.deepEqual(messages(), ["release-all", { type: "display-presented", generation: 6 }]);
});

test("frames from a replaced video decoder are never drawn", async (t) => {
  const { session, canvas, sockets, decoders, closedFrames, frame, displayState, paint } =
    await displaySession(t);
  sockets.get("/stream").dispatch("message", {
    data: JSON.stringify({ type: "video-config", codec: "avc1.42E01E" }),
  });
  await settleVideoSetup();
  assert.equal(decoders.length, 2);
  displayState("7", 0);
  decoders[0].output(frame(9000, 640, 480));
  paint();
  assert.deepEqual(closedFrames, [9000]);
  assert.deepEqual([canvas.width, canvas.height], [1280, 720]);
  session.disconnect();
  assert.equal(session.displays.state, null);
});
