// A touch screen has no wheel, and two-finger drag is already taken by the
// touchpad. This turns a vertical drag on a small on-screen dial into wheel
// notches: the dial is relative (a wheel injection carries no position), so the
// thumb reports the difference since the last sample and springs back.
export const WHEEL_NOTCH = 120;
/** Finger travel for one dial step. Short on purpose: it must fit a thumb. */
export const JOG_PIXELS_PER_STEP = 12;
/** One dial step is worth two wheel notches, i.e. roughly two lines of text. */
export const JOG_WHEEL_PER_STEP = 2 * WHEEL_NOTCH;
/** The Host rejects a single injection beyond this, so a fling is clamped. */
export const WHEEL_LIMIT = 1200;

export type JogSample = { steps: number; delta: number };

/**
 * 把「手指自按下点起的总位移」换算成这一帧该补发的滚轮量。
 *
 * 手指往上拖（{@link travelPx} 为负）＝朝文档顶部滚动＝滚轮正数，与滚动条
 * 箭头、以及 Windows 的 `WHEEL_DELTA` 语义一致。返回 `steps` 供调用方记住
 * 已经发到哪一格，避免同一位移被重复发送。
 */
export function jogWheelDelta(travelPx: number, emittedSteps: number): JogSample {
  const steps = Math.trunc(travelPx / JOG_PIXELS_PER_STEP);
  if (steps === emittedSteps) return { steps: emittedSteps, delta: 0 };
  const raw = (emittedSteps - steps) * JOG_WHEEL_PER_STEP;
  return { steps, delta: Math.max(-WHEEL_LIMIT, Math.min(WHEEL_LIMIT, raw)) };
}

/** 滑块的视觉位置：0 居中，±1 到达轨道两端；不做滚动量的换算。 */
export function jogThumbOffset(travelPx: number, trackPx: number): number {
  if (trackPx <= 0) return 0;
  return Math.max(-1, Math.min(1, travelPx / (trackPx * 0.35)));
}
