import type { RemoteInputEvent } from "./input-session";
import type { RemoteViewport } from "./viewport";
import { rotatePictureDelta, type VideoRotation } from "../media/video-geometry";

type Point = { x: number; y: number };
type Contact = Point & { start: Point };

// Gesture lifetime belongs to the current input grant. Pointer coordinates
// belong to the source picture; the local viewport supplies its visible bounds.
export class RemoteTouchpad {
  position: Point = { x: 0.5, y: 0.5 };
  private contacts = new Map<number, Contact>();
  private hold: ReturnType<typeof setTimeout> | null = null;
  private fingers = 0;
  private moved = false;
  private dragging = false;
  private started = 0;
  private pair: { center: Point; distance: number } | null = null;
  private gesture: "pending" | "scroll" | "view" = "pending";
  // A press held past the hold delay is ambivalent: moving turns it into a left
  // drag, releasing without motion is a right click. Deferring the button until
  // one of the two happens is what makes long-press right-click possible
  // without losing the existing hold-then-drag gesture.
  private armed = false;
  private frame: number | null = null;

  constructor(
    private readonly picture: () => { width: number; height: number; rotation: VideoRotation } | null,
    private readonly input: (event: RemoteInputEvent) => void,
    private readonly scroll: (deltaY: number) => void,
    private readonly changed: (position: Point) => void,
    private readonly viewport: Pick<RemoteViewport, "scale" | "transform" | "visiblePosition">,
  ) {}

  down(id: number, x: number, y: number): void {
    if (!this.contacts.size) {
      this.started = performance.now();
      this.fingers = 0;
      this.moved = false;
      this.gesture = "pending";
      this.changed(this.position);
    }
    this.contacts.set(id, { x, y, start: { x, y } });
    this.fingers = Math.max(this.fingers, this.contacts.size);
    this.clearHold();
    if (this.fingers === 1) {
      this.armed = false;
      this.hold = setTimeout(() => {
        this.hold = null;
        this.armed = true;
      }, 500);
    } else {
      this.armed = false;
      this.endDrag();
      this.pair = this.pairGeometry();
    }
  }

  move(id: number, x: number, y: number): void {
    const contact = this.contacts.get(id);
    if (!contact) return;
    if (this.fingers > 1) {
      contact.x = x; contact.y = y;
      // A native touch packet produces one pointer event per finger. Decide
      // pinch versus parallel movement after both arrive, not halfway through.
      if (this.frame === null) this.frame = requestAnimationFrame(() => this.movePair());
      return;
    }
    const dx = x - contact.x, dy = y - contact.y;
    if (Math.hypot(x - contact.start.x, y - contact.start.y) > 8) {
      this.moved = true;
      this.clearHold();
    }
    if (!this.moved && !this.dragging) return;
    // Motion after the hold delay commits the press to a left drag.
    if (this.armed && !this.dragging) {
      this.dragging = true;
      this.input({ type: "move", ...this.position });
      this.input({ type: "button", button: 0, down: true });
    }
    // Keep the initial displacement while deciding tap versus motion. Updating
    // the origin before this threshold loses the start of every small swipe.
    contact.x = x; contact.y = y;
    const picture = this.picture();
    if (!picture?.width || !picture.height) return;
    const delta = rotatePictureDelta({ x: dx / picture.width, y: dy / picture.height }, picture.rotation, true);
    this.position = this.viewport.visiblePosition({
      x: Math.max(0, Math.min(1, this.position.x + delta.x)),
      y: Math.max(0, Math.min(1, this.position.y + delta.y)),
    });
    this.input({ type: "move", ...this.position });
    this.changed(this.position);
  }

  private pairGeometry(): { center: Point; distance: number } | null {
    if (this.fingers !== 2 || this.contacts.size !== 2) return null;
    const [a, b] = [...this.contacts.values()];
    return { center: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }, distance: Math.max(1, Math.hypot(b.x - a.x, b.y - a.y)) };
  }

  private movePair(): void {
    if (this.frame !== null) cancelAnimationFrame(this.frame);
    this.frame = null;
    const next = this.pairGeometry(), previous = this.pair;
    if (!next || !previous) return;
    if (this.gesture === "pending") {
      const pinch = Math.abs(next.distance - previous.distance) > Math.max(8, previous.distance * .08);
      const pan = Math.hypot(next.center.x - previous.center.x, next.center.y - previous.center.y) > 8;
      if (!pinch && !pan) return;
      this.gesture = pinch || this.viewport.scale > 1 ? "view" : "scroll";
      this.moved = true;
    }
    if (this.gesture === "view") this.viewport.transform(previous.center, next.center, next.distance / previous.distance);
    else this.scroll(previous.center.y - next.center.y);
    this.pair = next;
  }

  up(id: number): void {
    this.movePair();
    if (!this.contacts.delete(id)) return;
    this.clearHold();
    if (this.contacts.size) return;
    if (!this.moved && !this.dragging && performance.now() - this.started < 500 && this.fingers <= 2) {
      const button = this.fingers === 2 ? 2 : 0;
      this.input({ type: "move", ...this.position });
      this.input({ type: "button", button, down: true });
      this.input({ type: "button", button, down: false });
    } else if (this.armed && !this.dragging) {
      // Held past the delay and released without motion: right click, the
      // touch equivalent of pressing the secondary button.
      this.input({ type: "move", ...this.position });
      this.input({ type: "button", button: 2, down: true });
      this.input({ type: "button", button: 2, down: false });
    }
    this.armed = false;
    this.endDrag();
  }

  /** Single click at the current pointer position, for on-screen mouse buttons. */
  click(button: number): void {
    this.input({ type: "move", ...this.position });
    this.input({ type: "button", button, down: true });
    this.input({ type: "button", button, down: false });
    this.changed(this.position);
  }

  /** Two clicks inside the Host double-click window become a double click. */
  doubleClick(): void {
    this.click(0);
    this.click(0);
  }

  private clearHold(): void {
    if (this.hold !== null) clearTimeout(this.hold);
    this.hold = null;
  }

  private endDrag(): void {
    if (this.dragging) this.input({ type: "button", button: 0, down: false });
    this.dragging = false;
  }

  cancel(id: number): void {
    if (this.contacts.has(id)) this.reset();
  }

  reset(): void {
    if (this.frame !== null) cancelAnimationFrame(this.frame);
    this.frame = null;
    this.pair = null;
    this.clearHold();
    this.armed = false;
    this.endDrag();
    this.contacts.clear();
  }
}
