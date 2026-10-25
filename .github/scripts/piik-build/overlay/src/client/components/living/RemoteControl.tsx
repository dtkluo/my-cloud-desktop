import { useCallback, useEffect, useRef, useState, type RefObject } from "react";
import { createPortal } from "react-dom";
import { useCopy, type CopyKey } from "../../ui/copy";
import { Glyph } from "../../ui/icons";
import type { InputTransport } from "../../remote-control/input-route";
import { RemoteInputSession, type RemoteInputState, type RemoteInputEvent } from "../../remote-control/input-session";
import { RemoteTouchpad } from "../../remote-control/touchpad";
import { RemoteViewport } from "../../remote-control/viewport";
import { RemoteGamepad } from "../../remote-control/gamepad";
import { matchesRemoteShortcut, remoteTextAvailable, remoteGamepadAvailable } from "../../remote-control/protocol";
import { jogThumbOffset, jogWheelDelta, WHEEL_NOTCH } from "../../remote-control/wheel-jog";
import { readRoomPreferences, saveRoomPreferences } from "../../lib/room-preferences";
import { RemoteKeyboard } from "./RemoteKeyboard";
import { Btn } from "./primitives";
import { videoFullscreenState, type FullscreenVideo } from "./video-fullscreen";
import { picturePoint, pictureRect, rotatePicturePoint, rotatePictureDelta, videoRotation, type VideoFit, type VideoRotation } from "../../media/video-geometry";
import "./remote-control.css";

// The video keeps its existing media owner. This temporary surface handles
// input only while its current routed endpoint holds a local App grant.
export function RemoteControl({ channel, videoRef, available, pictureFit, pictureRotation = 0 }: {
  channel: InputTransport | null; videoRef: RefObject<HTMLVideoElement | null>;
  available: boolean;
  pictureFit?: VideoFit;
  pictureRotation?: VideoRotation;
}) {
  const { t, vis } = useCopy();
  const [state, setState] = useState<RemoteInputState | null>(null);
  const [locked, setLocked] = useState(false);
  const [lockFailed, setLockFailed] = useState(false);
  const [presentation, setPresentation] = useState<"playing" | "paused" | "external">("paused");
  const [passwordOpen, setPasswordOpen] = useState(false);
  const [password, setPassword] = useState("");
  const [gamepadConnected, setGamepadConnected] = useState(false);
  const [keyboardOpen, setKeyboardOpen] = useState(false);
  const [keyboardPage, setKeyboardPage] = useState<"text" | undefined>(undefined);
  const keyboardSeeded = useRef(false);
  const [keyboardDocument, setKeyboardDocument] = useState<Document | null>(null);
  const keyboardDetached = Boolean(keyboardDocument && keyboardDocument !== document);
  const [touch, setTouch] = useState(false);
  const [releaseKey, setReleaseKey] = useState(() => readRoomPreferences().remoteReleaseKey);
  const session = useRef<RemoteInputSession | null>(null);
  const surface = useRef<HTMLDivElement | null>(null);
  const cursor = useRef<SVGSVGElement | null>(null);
  const touchpad = useRef<RemoteTouchpad | null>(null);
  const viewport = useRef<RemoteViewport | null>(null);
  // 曾经真正拿到过控制权（用于掉线后自动重取；用户主动停止时清零）。
  const regain = useRef(false);
  // 自动重取的定时器挂在 ref 上：服务端每推一条新状态都会让下面的 effect
  // 重跑，若用 effect 的 cleanup 清定时器，连续两条状态就能让它永远不触发。
  const regainTimer = useRef<number | null>(null);
  const regainAttempts = useRef(0);
  // 滚动拨盘：记录按下点与已发送的档位；抬起后滑块弹回中央。
  const jog = useRef<{ id: number; y: number; steps: number } | null>(null);
  const [jogOffset, setJogOffset] = useState(0);
  const [jogActive, setJogActive] = useState(false);
  const canControl = available && presentation === "playing";
  const active = state?.state === "active" && canControl && channel?.readyState === "open";
  const controlled = (state?.state === "active" || state?.state === "suspended") && canControl && channel?.readyState === "open";
  const gamepadAvailable = state !== null && remoteGamepadAvailable(state) && typeof navigator.getGamepads === "function";
  const input = useCallback((event: RemoteInputEvent) => session.current?.input(event), []);
  const reset = useCallback(() => { touchpad.current?.reset(); session.current?.input({ type: "reset" }); }, []);
  const closeKeyboard = () => {
    reset(); setKeyboardOpen(false); setKeyboardDocument(null); surface.current?.focus({ preventScroll: true });
  };
  const keyboardSurfaceChanged = useCallback((owner: Document) => {
    reset(); setKeyboardDocument(owner);
  }, [reset]);
  const release = useCallback(() => {
    reset();
    if (document.pointerLockElement === surface.current && surface.current) document.exitPointerLock();
    session.current?.release();
  }, [reset]);

  useEffect(() => {
    setState(null);
    setPasswordOpen(false); setPassword("");
    if (!channel) return;
    const current = new RemoteInputSession(channel, setState);
    session.current = current;
    return () => {
      current.dispose(); session.current = null;
    };
  }, [channel]);
  useEffect(() => {
    if (controlled || state?.mode !== "password" || !canControl) {
      setPasswordOpen(false); setPassword("");
    }
  }, [controlled, state?.mode, canControl]);
  useEffect(() => {
    if (!available) release();
  }, [available, channel, release]);
  useEffect(() => {
    if (!active) { touchpad.current?.reset(); setKeyboardOpen(false); setKeyboardDocument(null); }
  }, [active]);
  useEffect(() => {
    setGamepadConnected(false);
    if (!controlled || !gamepadAvailable) return;
    const current = new RemoteGamepad(input, setGamepadConnected);
    return () => current.dispose();
  }, [controlled, gamepadAvailable, state?.grant, channel, input]);
  useEffect(() => {
    const video = videoRef.current;
    const element = surface.current;
    if (!controlled || !video || !element) { setTouch(false); return; }
    const updateCursor = () => {
      const picture = pictureRect(video);
      const rect = surface.current?.getBoundingClientRect();
      if (!picture || !rect || !cursor.current) return;
      const position = rotatePicturePoint(current.position, videoRotation(video));
      cursor.current.style.left = `${picture.left - rect.left + position.x * picture.width}px`;
      cursor.current.style.top = `${picture.top - rect.top + position.y * picture.height}px`;
    };
    const view = new RemoteViewport(video, element, () => {
      current.position = view.visiblePosition(current.position);
      updateCursor();
    });
    viewport.current = view;
    const current = new RemoteTouchpad(
      () => {
        const picture = pictureRect(video);
        return picture && { ...picture, rotation: videoRotation(video) };
      },
      event => session.current?.input(event),
      delta => session.current?.scroll(delta, 0),
      updateCursor,
      view,
    );
    touchpad.current = current;
    // Layout changes and decoded aspect-ratio changes share the input geometry.
    const refresh = () => view.refresh();
    const observer = new ResizeObserver(refresh);
    observer.observe(video);
    video.addEventListener("resize", refresh);
    return () => {
      observer.disconnect(); video.removeEventListener("resize", refresh);
      current.reset(); view.reset(); touchpad.current = null; viewport.current = null;
    };
  }, [controlled, channel, videoRef]);
  useEffect(() => { viewport.current?.refresh(); }, [pictureFit]);
  useEffect(() => {
    reset(); viewport.current?.reset(); viewport.current?.refresh();
  }, [pictureRotation, reset]);
  useEffect(() => {
    const video = videoRef.current as FullscreenVideo | null;
    if (!video) return;
    // Native PiP/fullscreen moves the picture away from the page's input surface.
    // DOM fullscreen retains that surface and can continue controlling normally.
    const syncPresentation = () => {
      const external = document.pictureInPictureElement === video ||
        video.webkitPresentationMode === "picture-in-picture" || videoFullscreenState(video).nativeActive;
      const current = external ? "external" : video.paused || video.ended ? "paused" : "playing";
      // Invalidate the request as well as its grant before a late approval arrives.
      if (current !== "playing") release();
      setPresentation(current);
    };
    const events = ["play", "pause", "ended", "emptied", "enterpictureinpicture", "leavepictureinpicture", "webkitpresentationmodechanged", "webkitbeginfullscreen", "webkitendfullscreen"];
    syncPresentation();
    events.forEach(event => video.addEventListener(event, syncPresentation));
    return () => {
      events.forEach(event => video.removeEventListener(event, syncPresentation));
    };
  }, [release, videoRef]);
  useEffect(() => {
    if (!controlled) return;
    const element = surface.current;
    element?.focus({ preventScroll: true });
    const wheel = (event: WheelEvent) => { event.preventDefault(); session.current?.scroll(event.deltaY, event.deltaMode); };
    element?.addEventListener("wheel", wheel, { passive: false });
    // Release can land outside the picture after a drag. Observe it for this
    // grant only; the native owner ignores buttons it never pressed.
    const mouseUp = (event: MouseEvent) => session.current?.input({ type: "button", button: event.button, down: false });
    window.addEventListener("mouseup", mouseUp, true);
    const lockChanged = () => {
      reset(); setLocked(document.pointerLockElement === element);
      if (document.pointerLockElement === element) { setLockFailed(false); element?.focus({ preventScroll: true }); }
    };
    window.addEventListener("blur", reset);
    document.addEventListener("pointerlockchange", lockChanged);
    return () => {
      element?.removeEventListener("wheel", wheel);
      window.removeEventListener("mouseup", mouseUp, true);
      window.removeEventListener("blur", reset);
      document.removeEventListener("pointerlockchange", lockChanged);
      if (document.pointerLockElement === element) document.exitPointerLock();
      setLocked(false); setLockFailed(false);
    };
  }, [controlled, channel, release, reset]);
  useEffect(() => {
    if (!controlled) return;
    const owners = [...new Set([document, ...(keyboardDocument ? [keyboardDocument] : [])])];
    const hidden = () => {
      reset();
      // A visible detached keyboard is still an attended input surface.
      if (owners.every(owner => owner.hidden || owner.defaultView?.closed)) release();
    };
    owners.forEach(owner => owner.addEventListener("visibilitychange", hidden));
    hidden();
    return () => owners.forEach(owner => owner.removeEventListener("visibilitychange", hidden));
  }, [controlled, keyboardDocument, release, reset]);
  useEffect(() => {
    if (!controlled) return;
    const owners = [...new Set([document, ...(keyboardDocument ? [keyboardDocument] : [])])];
    const stop = (event: KeyboardEvent) => {
      if (!matchesRemoteShortcut(event, releaseKey)) return;
      event.preventDefault(); event.stopImmediatePropagation(); release();
    };
    owners.forEach(owner => owner.addEventListener("keydown", stop, true));
    return () => owners.forEach(owner => owner.removeEventListener("keydown", stop, true));
  }, [controlled, keyboardDocument, release, releaseKey]);
  // 掉线自愈：连接恢复后若此前真正拥有过控制权、且房间是自动授权的 room 模式，
  // 自动重新申请一次。这样 ICE 抖动/重连后不必让用户刷新整个页面才能拿回控制权。
  // 只在 state 回到 ready（无人控制、可申请）时触发，避免 failed/busy 反复重试。
  //
  // 定时器**不能**放进 effect 的 cleanup：`state` 每次推送都是新对象，effect 会
  // 反复重跑，而 Host 在抖动时会连推多条状态 —— 那样 800ms 的窗口永远等不到。
  const clearRegain = useCallback(() => {
    if (regainTimer.current !== null) { window.clearTimeout(regainTimer.current); regainTimer.current = null; }
  }, []);
  useEffect(() => clearRegain, [clearRegain]);
  useEffect(() => {
    if (controlled) {
      regain.current = true; regainAttempts.current = 0; clearRegain();
      return;
    }
    // 已经拿到 grant 但画面被判为不可控（暂停/画中画），重取没有意义。
    if (state?.state === "active") { regainAttempts.current = 0; clearRegain(); return; }
    // room 模式下 pending 超过 6 秒说明请求或回执在链路上丢了：重发一次。
    if (state?.state === "pending" && state.mode === "room") {
      if (regainTimer.current !== null || regainAttempts.current >= 20) return;
      regainTimer.current = window.setTimeout(() => {
        regainTimer.current = null;
        regainAttempts.current += 1;
        session.current?.request();
      }, 6000);
      return;
    }
    if (!regain.current || !canControl) return;
    if (!channel || channel.readyState !== "open") return;
    if (!state || state.mode !== "room" || state.state !== "ready") return;
    if (regainTimer.current !== null || regainAttempts.current >= 20) return;
    // 退避：前两次 0.8s，之后 2s、4s，避免在断流时刷屏请求。
    const attempt = regainAttempts.current;
    const delay = attempt < 2 ? 800 : attempt < 4 ? 2000 : 4000;
    regainTimer.current = window.setTimeout(() => {
      regainTimer.current = null;
      regainAttempts.current += 1;
      session.current?.request();
    }, delay);
  }, [controlled, canControl, channel, state, clearRegain]);
  // 手机切回页面时浏览器可能把视频留在暂停态，而暂停就等于 canControl=false
  // （控制入口会被整块禁掉）。这里只在确实暂停时尝试恢复播放。
  useEffect(() => {
    const resume = () => {
      const video = videoRef.current;
      if (document.hidden || !video || video.ended || !video.paused || !video.srcObject) return;
      void video.play().catch(() => { /* 自动播放被策略拦下时保持原样 */ });
    };
    document.addEventListener("visibilitychange", resume);
    return () => document.removeEventListener("visibilitychange", resume);
  }, [videoRef]);

  if (!channel || channel.readyState !== "open" || !state || state.mode === "off") return null;
  const point = (clientX: number, clientY: number) => {
    const video = videoRef.current;
    return video ? picturePoint(video, clientX, clientY) : null;
  };
  const requesting = state.state === "pending";
  const holding = controlled || requesting;
  const buttonTitle = holding ? controlled ? "remote.stop" : "remote.cancel" : "remote.request";
  const requestControl = () => {
    if (holding) {
      // 用户主动停止：不再自动重取，否则会把自己刚放下的控制权又拉回来。
      if (controlled) regain.current = false;
      release();
      return;
    }
    if (state.mode === "password") {
      release(); setPasswordOpen(true);
    } else session.current?.request();
  };
  const touchControls = touch || matchMedia("(pointer: coarse)").matches;
  // A touch device has no hardware keyboard, so the first open lands on the text
  // entry whose local <textarea> raises the system IME. Remembered pages win
  // afterwards, otherwise a deliberate switch back to ABC would never stick.
  const openKeyboard = () => {
    reset();
    const seed = !keyboardSeeded.current && touchControls ? "text" as const : undefined;
    keyboardSeeded.current = true;
    setKeyboardPage(seed);
    setKeyboardOpen(true);
  };
  const statusIcon = state.reason === "busy" ? "users" : state.reason === "password" || state.reason === "gamepad" || state.state === "failed" ? "alert"
    : state.state === "suspended" ? "pause" : gamepadConnected && controlled ? "gamepad" : "clock";
  const feedback: CopyKey | undefined = state.reason ? `remote.reason.${state.reason}`
    : state.state === "suspended" ? "remote.suspended" : state.state === "failed" ? "remote.failed"
    : state.state === "pending" ? state.mode === "ask" ? "remote.pending" : "remote.connecting"
    : gamepadConnected && controlled ? "remote.gamepadHelp"
    : undefined;
  const parent = videoRef.current?.parentElement;
  return <>
    <span className="lr-remote-controls" role="group" aria-label={t("remote.title")}>
      <span className="lr-remote-viewer-control">
        <Btn icon="mouse" title={presentation === "external" ? "remote.inlineRequired" : presentation === "paused" ? "remote.playbackRequired" : state.state === "unavailable" ? "remote.unavailable" : buttonTitle}
          hint={holding ? "hint-remote-stop" : "hint-remote-control"}
          hintText={feedback} hintTone={state.state === "failed" ? "warn" : undefined}
          busy={requesting} pressed={controlled} disabled={!canControl || state.state === "unavailable"}
          onClick={() => requestControl()} />
        {feedback && !passwordOpen && <span className="lr-remote-feedback" role="status">
          <Glyph name={statusIcon} size={15} />
          <span className={vis ? "visually-hidden" : undefined}>{t(feedback)}</span>
        </span>}
      </span>
      <Btn icon="keyboard" title={keyboardDetached ? "floating.focus" : "remote.keyboard"} hint={keyboardDetached ? "hint-window-detach" : "hint-remote-keyboard"}
        hintText={!active ? "remote.keyboardRequiresControl" : touchControls ? "remote.touchHelp" : undefined} expanded={keyboardOpen} disabled={!active}
        onClick={() => {
          if (keyboardDetached) keyboardDocument?.defaultView?.focus();
          else if (keyboardOpen) closeKeyboard();
          else openKeyboard();
        }} />
    </span>
    {parent && (controlled || state.state === "pending" || state.state === "failed" || state.reason || passwordOpen) && createPortal(<>
      {passwordOpen && <form className="lr-remote-password" onSubmit={event => {
        event.preventDefault(); session.current?.request(password); setPassword("");
      }} onKeyDown={event => {
        event.stopPropagation();
        if (event.key === "Escape" && !event.defaultPrevented && !event.nativeEvent.isComposing) {
          event.preventDefault(); setPasswordOpen(false); setPassword(""); release();
        }
      }}>
        <div className="lr-remote-panel-header">
          <strong><Glyph name="key" size={18} />{vis ? null : t("remote.password")}</strong>
          <button type="button" className="lr-btn is-dense is-quiet lr-popover-close" aria-label={t("common.cancel")}
            onClick={() => { setPasswordOpen(false); setPassword(""); release(); }}>
            <Glyph name="x" size={17} />
          </button>
        </div>
        <div className="lr-remote-policy-actions">
          <label className="lr-input">
            <input type="password" required autoFocus autoComplete="off" maxLength={128}
              value={password} aria-label={t("remote.password")} disabled={state.state === "pending"}
              onChange={event => setPassword(event.target.value)} />
          </label>
          <Btn icon="check" title="remote.request" size="compact" hint="hint-remote-control" type="submit" disabled={!password || state.state === "pending"} />
        </div>
        {state.reason && <p role="status" className={state.reason === "password" ? "is-bad" : undefined}><Glyph name={statusIcon} size={16} />
          <span className={vis ? "visually-hidden" : undefined}>{t(`remote.reason.${state.reason}`)}</span></p>}
      </form>}
      {controlled && <div ref={surface} className={`lr-remote-input-surface${active ? "" : " is-suspended"}${locked ? " is-locked" : ""}`} tabIndex={0}
        aria-label={t("remote.surface")} role="application"
        onContextMenu={event => event.preventDefault()}
        onAuxClick={event => event.preventDefault()}
        onPointerMove={event => {
          if (event.pointerType === "touch") {
            event.preventDefault(); event.stopPropagation();
            touchpad.current?.move(event.pointerId, event.clientX, event.clientY); return;
          }
          setTouch(false);
          if (document.pointerLockElement === surface.current) {
            const delta = rotatePictureDelta({ x: event.movementX, y: event.movementY }, pictureRotation, true);
            input({ type: "relative", dx: delta.x, dy: delta.y });
          } else {
            const position = point(event.clientX, event.clientY);
            if (position) {
              input({ type: "move", ...position });
              if (touchpad.current) touchpad.current.position = position;
            }
          }
        }}
        onPointerDown={event => {
          if (document.pointerLockElement !== surface.current) event.currentTarget.setPointerCapture(event.pointerId);
          if (event.pointerType === "touch") {
            event.preventDefault(); event.stopPropagation(); setTouch(true);
            surface.current?.focus({ preventScroll: true });
            touchpad.current?.down(event.pointerId, event.clientX, event.clientY);
          }
        }}
        onPointerUp={event => {
          if (event.pointerType === "touch") {
            event.preventDefault(); event.stopPropagation(); touchpad.current?.up(event.pointerId);
          }
        }}
        onClick={event => { event.preventDefault(); event.stopPropagation(); }}
        onDoubleClick={event => { event.preventDefault(); event.stopPropagation(); }}
        // Pointer down/up report the first/last mouse button only. Mouse events
        // preserve chords such as holding right to aim while left clicks fire.
        onMouseDown={event => {
          if (event.button > 4) return;
          event.preventDefault(); surface.current?.focus({ preventScroll: true });
          if (document.pointerLockElement === surface.current) { input({ type: "button", button: event.button, down: true }); return; }
          const position = point(event.clientX, event.clientY);
          if (position) { input({ type: "move", ...position }); input({ type: "button", button: event.button, down: true }); }
        }}
        onPointerCancel={reset}
        onLostPointerCapture={event => {
          if (event.pointerType === "touch") touchpad.current?.cancel(event.pointerId);
          // Normal mouse-up also releases capture. It must not release a key
          // still held for movement or a keyboard/mouse chord.
          else if (event.buttons !== 0) reset();
        }}
        onBlur={reset}
        onKeyDown={event => {
          event.preventDefault(); event.stopPropagation();
          if (!event.nativeEvent.isComposing) input({ type: "key", code: event.code, down: true });
        }}
        onKeyUp={event => { event.preventDefault(); event.stopPropagation(); input({ type: "key", code: event.code, down: false }); }}>
        <svg ref={cursor} className="lr-remote-touch-cursor" viewBox="0 0 24 28" aria-hidden="true" style={{ display: touch ? undefined : "none" }}>
          <path d="M2 2v21l6-6 5 9 4-2-5-9h9Z" />
        </svg>
      </div>}
      {/* Touch has no secondary button: long press is the drag gesture, so the
          right click needs its own control. Two-finger tap stays as a shortcut.
          The scroll dial replaces the middle button, which no touch surface
          could reach on a remote desktop; it sits higher than the button row
          because the bottom edge of a phone is outside the comfortable thumb
          arc. ▲/▼ = one notch, the slider is a relative dial (2 notches per
          step) so a single stroke can travel several screens. */}
      {controlled && touchControls && <>
        <div className="lr-remote-scroll" role="group" aria-label="滚动">
          <button type="button" className="lr-remote-scroll-step" aria-label="向上滚动"
            onPointerDown={event => { event.preventDefault(); event.stopPropagation(); input({ type: "wheel", delta: WHEEL_NOTCH }); }}>
            <svg viewBox="0 0 14 9" aria-hidden="true"><path d="M7 0 14 9H0Z" /></svg>
          </button>
          <div className={`lr-remote-jog${jogActive ? " is-dragging" : ""}`} role="slider" aria-label="拖动滚动" aria-valuemin={-100} aria-valuemax={100} aria-valuenow={Math.round(jogOffset * 100)}
            onPointerDown={event => {
              event.preventDefault(); event.stopPropagation();
              event.currentTarget.setPointerCapture(event.pointerId);
              jog.current = { id: event.pointerId, y: event.clientY, steps: 0 };
              setJogActive(true); setJogOffset(0);
            }}
            onPointerMove={event => {
              const current = jog.current;
              if (!current || current.id !== event.pointerId) return;
              event.preventDefault(); event.stopPropagation();
              const travel = event.clientY - current.y;
              const sample = jogWheelDelta(travel, current.steps);
              if (sample.steps !== current.steps) {
                current.steps = sample.steps;
                input({ type: "wheel", delta: sample.delta });
              }
              setJogOffset(jogThumbOffset(travel, event.currentTarget.clientHeight));
            }}
            onPointerUp={event => {
              if (jog.current?.id !== event.pointerId) return;
              event.stopPropagation();
              jog.current = null; setJogActive(false); setJogOffset(0);
              if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
            }}
            onPointerCancel={() => { jog.current = null; setJogActive(false); setJogOffset(0); }}
            onLostPointerCapture={() => { jog.current = null; setJogActive(false); setJogOffset(0); }}>
            <span className="lr-remote-jog-thumb" style={{ transform: `translateY(${jogOffset * 38}px)` }} />
          </div>
          <button type="button" className="lr-remote-scroll-step" aria-label="向下滚动"
            onPointerDown={event => { event.preventDefault(); event.stopPropagation(); input({ type: "wheel", delta: -WHEEL_NOTCH }); }}>
            <svg viewBox="0 0 14 9" aria-hidden="true"><path d="M0 0h14L7 9Z" /></svg>
          </button>
        </div>
        <div className="lr-remote-touch-actions" role="group" aria-label={t("remote.title")}>
          <button type="button" onClick={() => touchpad.current?.click(2)}>右键</button>
          <button type="button" onClick={() => touchpad.current?.doubleClick()}>双击</button>
        </div>
      </>}
      {active && keyboardOpen && <RemoteKeyboard input={input} touch={touchControls} platform={state.platform}
        allowText={remoteTextAvailable(state)}
        initialPage={keyboardPage}
        releaseKey={releaseKey} onReleaseKeyChange={key => { setReleaseKey(key); saveRoomPreferences({ remoteReleaseKey: key }); }}
        onSurfaceChange={keyboardSurfaceChanged}
        mouseControl={!touchControls && "requestPointerLock" in HTMLElement.prototype && <span className="lr-remote-game-mouse"><Btn icon="gamepad" size="compact"
          title={lockFailed ? "remote.lockFailed" : locked ? "remote.releaseMouse" : "remote.gameMouse"}
          cap={locked ? "remote.releaseMouse" : "remote.gameMouse"} pressed={locked}
          hint={locked ? "hint-remote-mouse-release" : "hint-remote-mouse-lock"}
          hintText={lockFailed ? "remote.lockFailed" : locked ? "remote.unlockMouse" : "remote.gameMouseHelp"}
          hintTone={lockFailed ? "warn" : undefined}
          onClick={() => void (async () => {
            if (locked) document.exitPointerLock();
            else try { await surface.current?.requestPointerLock(); setKeyboardOpen(false); } catch { setLockFailed(true); }
          })()} /></span>}
        close={closeKeyboard} />}
    </>, parent)}
  </>;
}
