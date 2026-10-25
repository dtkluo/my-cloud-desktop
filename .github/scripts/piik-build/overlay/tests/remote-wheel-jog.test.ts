import { expect, it } from "vitest";
import {
  JOG_PIXELS_PER_STEP,
  JOG_WHEEL_PER_STEP,
  WHEEL_LIMIT,
  WHEEL_NOTCH,
  jogThumbOffset,
  jogWheelDelta,
} from "../src/client/remote-control/wheel-jog";

it("turns thumb travel into wheel notches without repeating a position", () => {
  // 手指往上拖（负位移）＝朝文档顶部滚动＝滚轮正数。
  expect(jogWheelDelta(-JOG_PIXELS_PER_STEP, 0)).toEqual({ steps: -1, delta: JOG_WHEEL_PER_STEP });
  expect(jogWheelDelta(JOG_PIXELS_PER_STEP, 0)).toEqual({ steps: 1, delta: -JOG_WHEEL_PER_STEP });

  // 同一段位移只报一次；继续拖才继续发。
  expect(jogWheelDelta(-JOG_PIXELS_PER_STEP, -1).delta).toBe(0);
  expect(jogWheelDelta(-JOG_PIXELS_PER_STEP * 3, -1)).toEqual({ steps: -3, delta: 2 * JOG_WHEEL_PER_STEP });
});

it("keeps a partial step until it completes", () => {
  const almost = JOG_PIXELS_PER_STEP - 1;
  expect(jogWheelDelta(-almost, 0)).toEqual({ steps: 0, delta: 0 });
});

it("clamps a fling to what the Host accepts", () => {
  // Host 侧 `|delta| > 1200` 直接判非法，所以一次补发不能超过这个值。
  const sample = jogWheelDelta(-JOG_PIXELS_PER_STEP * 20, 0);
  expect(sample.steps).toBe(-20);
  expect(sample.delta).toBe(WHEEL_LIMIT);
  expect(Math.abs(sample.delta)).toBeLessThanOrEqual(WHEEL_LIMIT);
});

it("moves the thumb inside the track and springs back to centre", () => {
  expect(jogThumbOffset(0, 108)).toBe(0);
  expect(jogThumbOffset(-1000, 108)).toBe(-1);
  expect(jogThumbOffset(1000, 108)).toBe(1);
  expect(jogThumbOffset(9, 0)).toBe(0);
  expect(WHEEL_NOTCH).toBe(120);
});
