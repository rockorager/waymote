/** Public browser API for the Waymote streaming gateway. */
export interface RemoteDisplayManualPolicy {
  readonly mode: "manual";
}

export interface RemoteDisplayFixedPolicy {
  readonly mode: "fixed";
  readonly width: number;
  readonly height: number;
  /** Wayland output scale as a multiplier, for example 1 or 1.5. */
  readonly scale: number;
}

export interface RemoteDisplayObservePolicy {
  readonly mode: "observe";
  /** Defaults to the attached canvas. */
  readonly element?: Element;
  /** Defaults to window.devicePixelRatio. */
  readonly devicePixelRatio?: number;
  readonly debounceMs?: number;
  readonly minWidth?: number;
  readonly minHeight?: number;
  readonly maxWidth?: number;
  readonly maxHeight?: number;
  readonly maxPixels?: number;
}

export type RemoteDisplayPolicy =
  | RemoteDisplayManualPolicy
  | RemoteDisplayFixedPolicy
  | RemoteDisplayObservePolicy;

export interface WaymoteSessionOptions {
  readonly endpoint?: string | URL;
  readonly latency?: number;
  /** Defaults to true. When false, the session never opens the audio transport. */
  readonly audio?: boolean;
  /**
   * Creates each initial and reconnecting transport socket. Use this to attach
   * fresh authentication without placing credentials in the URL.
   */
  readonly createWebSocket?: (
    path: "/stream" | "/audio" | "/control",
    url: URL,
  ) => WebSocket | Promise<WebSocket>;
  /** Defaults to audio-player.js beside the SDK module. */
  readonly audioWorkletURL?: string | URL;
  /** Defaults to manual; local canvas sizing never implicitly changes this. */
  readonly remoteDisplay?: RemoteDisplayPolicy;
  /**
   * Operating system of the remote desktop. Defaults to linux. Selects the
   * remote's own paste shortcut for the host's paste gesture: Command-V on a
   * macOS remote and Ctrl-V on a Linux one.
   */
  readonly remotePlatform?: "linux" | "macos";
}

export interface VideoState {
  readonly state: "idle" | "connecting" | "connected" | "reconnecting" | "disconnected" | "error";
  readonly message: string;
  readonly codec: string | null;
}

export interface InputState {
  readonly state: "idle" | "connecting" | "requesting" | "ready" | "active" | "busy" | "disconnected";
  readonly message: string;
  readonly connected: boolean;
  readonly pointerLocked: boolean;
  /** Linux key codes of the one-shot modifiers latched for the next key press. */
  readonly stickyModifiers: readonly number[];
}

export interface AudioState {
  readonly state: "idle" | "connecting" | "ready" | "active" | "muted" | "unavailable" | "disconnected" | "error";
  readonly message: string;
  readonly available: boolean;
  readonly muted: boolean;
}

export interface WaymoteSessionState {
  readonly video: VideoState;
  readonly input: InputState;
  readonly audio: AudioState;
}

export interface WaymoteStats {
  readonly width: number;
  readonly height: number;
  readonly renderedFps: number;
  readonly generation: number;
  readonly bitrateKbps: number;
  readonly scalePercent: number;
  readonly rttMs: number;
  readonly clockConfident: boolean;
  readonly clockUncertaintyMs: number | null;
  readonly latencyTargetMs: number;
  readonly latenessMs: number;
  readonly audioVideoSkewMs: number | null;
  readonly pendingInputCount: number;
  readonly decoderQueue: number;
  readonly droppedFrames: number;
  readonly audioQueueMs: number;
  readonly audioUnderflows: number;
  readonly audioMode: "queue" | "sync";
  readonly resizeState: "idle" | "requested" | "applied" | "presented";
}

export interface ClipboardEvent {
  readonly text: string | null;
  readonly status: string;
}

export interface ResizeEvent {
  readonly state: "requested" | "applied" | "presented";
  readonly latencyMs?: number;
  readonly width: number;
  readonly height: number;
  readonly scale?: number;
  readonly generation?: number;
}

export interface QualityEvent {
  readonly bitrateKbps: number;
  readonly frameRate: number;
  readonly scalePercent: number;
}

export interface HostDisplay {
  readonly id: string;
  readonly name: string;
  readonly width: number;
  readonly height: number;
  readonly isMain: boolean;
}

export interface DisplayState {
  readonly displays: readonly HostDisplay[];
  readonly selectedID: string | null;
  readonly generation: number;
  /** True until a frame of the selected display has been drawn on the surface. */
  readonly switching: boolean;
  readonly error: string | null;
}

export interface DisplayController {
  /** Null until the server advertises display selection with display-state. */
  readonly state: DisplayState | null;
  /**
   * Selects a display, acquiring input control first when needed. Returns false
   * when selection is unsupported, the display is unknown, or a switch is in
   * progress, and true without a request when the display is already selected.
   */
  select(id: string): boolean;
}

export interface WaymoteEventMap {
  readonly state: WaymoteSessionState;
  readonly stats: WaymoteStats;
  readonly clipboard: ClipboardEvent;
  readonly resize: ResizeEvent;
  readonly quality: QualityEvent;
  readonly displays: DisplayState | null;
  readonly error: Error;
}

export interface SurfaceOptions {
  readonly canvas: HTMLCanvasElement;
  readonly inputElement?: HTMLElement;
  readonly textInputElement?: HTMLInputElement | HTMLTextAreaElement;
  readonly remoteDisplay?: RemoteDisplayPolicy;
  readonly controlOnFocus?: boolean;
  /**
   * Writes new remote copies to the host clipboard while the page has focus.
   * The clipboard the gateway replays when it grants control is not written.
   */
  readonly clipboardAutoSync?: boolean;
}

export interface SurfaceHandle {
  requestPointerLock(): Promise<void>;
  exitPointerLock(): void;
  focus(): void;
  focusTextInput(): void;
  dispose(): void;
}

export interface VideoController {
  setLatencyTarget(milliseconds: number): void;
}

export interface AudioController {
  enable(): Promise<void>;
  setMuted(muted: boolean): void;
  setVolume(volume: number): void;
  toggleMuted(): void;
  readonly muted: boolean;
}

export interface InputController {
  acquire(): void;
  release(): void;
  /**
   * Swaps Command (Super) and Control for hardware keys, so a Mac browser's
   * Command shortcuts reach a Linux desktop as Ctrl shortcuts and the reverse.
   * Defaults to false.
   */
  setSwapCommandControl(enabled: boolean): void;
  /**
   * Presses and releases one key on the remote, holding the given modifier keys
   * around it, plus any latched sticky modifiers, which this consumes unless the
   * key is itself a modifier. Keys are Linux key codes from 1 to 255. Returns
   * false when input control is not active.
   */
  tapKey(key: number, modifiers?: readonly number[]): boolean;
  /**
   * Latches one-shot modifiers (Linux key codes of Shift, Ctrl, Alt, or Super;
   * other keys are ignored). They wrap the next non-modifier key press, whether
   * from a hardware key, a character typed on an on-screen keyboard, or tapKey,
   * and are then cleared. Reflected in InputState.stickyModifiers.
   */
  setStickyModifiers(keys: readonly number[]): void;
  /**
   * Writes text to the remote clipboard and taps the remote's own paste
   * shortcut. Returns false when input control is not active or the text
   * exceeds the clipboard limit.
   */
  pasteText(text: string): boolean;
}

export interface ClipboardController {
  sendText(text: string): boolean;
  readonly latestRemoteText: string | null;
}

export interface RemoteDisplayController {
  setPolicy(policy: RemoteDisplayPolicy): void;
  manual(): void;
  fixed(configuration: Omit<RemoteDisplayFixedPolicy, "mode">): void;
  observe(configuration?: Omit<RemoteDisplayObservePolicy, "mode">): void;
  readonly policy: RemoteDisplayPolicy;
}

export declare class WaymoteSession {
  constructor(options?: WaymoteSessionOptions);
  readonly state: WaymoteSessionState;
  readonly stats: Readonly<Partial<WaymoteStats>>;
  readonly video: VideoController;
  readonly audio: AudioController;
  readonly input: InputController;
  readonly clipboard: ClipboardController;
  readonly displays: DisplayController;
  readonly remoteDisplay: RemoteDisplayController;
  attachSurface(options: SurfaceOptions): SurfaceHandle;
  connect(): void;
  /** Temporarily disconnect while retaining the surface and reusable audio graph. */
  disconnect(): void;
  /** Permanently release transport, media, audio, surface, and event resources. */
  dispose(): Promise<void>;
  on<K extends keyof WaymoteEventMap>(
    type: K,
    listener: (event: WaymoteEventMap[K]) => void,
  ): () => void;
}
