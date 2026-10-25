// Piik auto-host driver for the cloud-desktop workflow.
// Cold start: preload a fetch hook -> open the local Host page -> create/reuse a private room
// with a room password -> share the whole screen -> pick the HD 1080p/30fps preset ->
// verify system sound -> enable remote control for room viewers -> emit JSON.
//
// Requires: Node >= 22 (built-in WebSocket), Chrome with --remote-debugging-port.
// No npm dependencies by design.

import { setTimeout as sleep } from 'node:timers/promises';
import fs from 'node:fs';

const CFG = {
  cdpPort: process.env.PIIK_CDP_PORT || '9223',
  hostUrl: process.env.PIIK_HOST_URL || 'http://127.0.0.1:8787/#piik-client=1',
  password: process.env.PIIK_ROOM_PASSWORD || '8682268',
  preset: process.env.PIIK_PRESET || 'HD · 1080p 30 fps',
  out: process.env.PIIK_RESULT || 'C:/piik-auto/piik-result.json',
  deadlineMs: Number(process.env.PIIK_DEADLINE_MS || 240000),
};

const R = {
  ok: false,
  roomId: '',
  inviteUrl: '',
  site: '',
  policy: '',
  password: CFG.password,
  sharing: false,
  preset: '',
  resolution: '',
  fps: 0,
  audio: false,
  remoteControl: false,
  remoteMode: '',
  steps: [],
  errors: [],
};
const t0 = Date.now();

function wto(p, ms, label) {
  return Promise.race([p, new Promise((_, j) => setTimeout(() => j(new Error('timeout:' + label)), ms))]);
}

async function getTarget() {
  for (let i = 0; i < 80; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${CFG.cdpPort}/json/list`);
      const pages = (await r.json()).filter((t) => t.type === 'page');
      const p = pages.find((t) => t.url.includes('8787')) || pages[0];
      if (p && p.webSocketDebuggerUrl) return p;
    } catch (e) {}
    await sleep(500);
  }
  throw new Error('no cdp page target');
}

class CDP {
  constructor(url) {
    this.id = 0;
    this.pending = new Map();
    this.ws = new WebSocket(url);
    this.ws.addEventListener('message', (ev) => {
      let m;
      try { m = JSON.parse(String(ev.data)); } catch { return; }
      if (m.id && this.pending.has(m.id)) {
        const { res, rej } = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) rej(new Error(JSON.stringify(m.error))); else res(m.result);
      }
    });
    this.ws.addEventListener('close', () => {
      for (const { rej } of this.pending.values()) rej(new Error('ws closed'));
      this.pending.clear();
    });
  }
  ready() {
    return wto(new Promise((r, j) => {
      this.ws.addEventListener('open', () => r());
      this.ws.addEventListener('error', () => j(new Error('ws error')));
    }), 15000, 'ws-open');
  }
  send(method, params = {}, ms = 30000) {
    const id = ++this.id;
    return wto(new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method, params }));
    }), ms, method);
  }
  async eval(expression, ms = 30000) {
    const r = await this.send('Runtime.evaluate', {
      expression, returnByValue: true, awaitPromise: true, userGesture: true,
    }, ms);
    if (r.exceptionDetails) throw new Error('JS:' + JSON.stringify(r.exceptionDetails).slice(0, 200));
    return r.result.value;
  }
  close() { try { this.ws.close(); } catch {} }
}

const CLICK = (aria) => `(function(){var el=[].slice.call(document.querySelectorAll('[aria-label]')).filter(function(e){return e.getAttribute('aria-label')===${JSON.stringify(aria)};})[0];if(!el)return 'MISS';el.click();return 'OK';})()`;
const CLICKP = (pre) => `(function(){var el=[].slice.call(document.querySelectorAll('[aria-label]')).filter(function(e){return (e.getAttribute('aria-label')||'').indexOf(${JSON.stringify(pre)})===0;})[0];if(!el)return 'MISS';el.click();return 'OK';})()`;
// Try several aria-label candidates in order; the host UI is localized.
const CLICK_ANY = (list) => `(function(){var L=${JSON.stringify(list)};for(var i=0;i<L.length;i++){var el=[].slice.call(document.querySelectorAll('[aria-label]')).filter(function(e){return e.getAttribute('aria-label')===L[i];})[0];if(el&&!el.disabled){el.click();return 'OK:'+L[i];}}return 'MISS';})()`;
const HAS_ANY = (list) => `(function(){var L=${JSON.stringify(list)};for(var i=0;i<L.length;i++){if([].slice.call(document.querySelectorAll('[aria-label]')).filter(function(e){return e.getAttribute('aria-label')===L[i];}).length)return true;}return false;})()`;
const SWITCH_ANY = (list) => `(function(){var L=${JSON.stringify(list)};for(var i=0;i<L.length;i++){var s=[].slice.call(document.querySelectorAll('[role=switch]')).filter(function(e){return (e.getAttribute('aria-label')||'').indexOf(L[i])>=0;})[0];if(s){if(s.getAttribute('aria-checked')==='true')return 'ALREADY';s.click();return 'ON';}}return 'MISS';})()`;
const SWITCH_STATE_ANY = (list) => `(function(){var L=${JSON.stringify(list)};for(var i=0;i<L.length;i++){var s=[].slice.call(document.querySelectorAll('[role=switch]')).filter(function(e){return (e.getAttribute('aria-label')||'').indexOf(L[i])>=0;})[0];if(s)return s.getAttribute('aria-checked');}return 'NA';})()`;
const TEXT = `(document.body.innerText||'').replace(/\\s+/g,' ')`;
const HAS = (s) => `(${TEXT}).indexOf(${JSON.stringify(s)})>=0`;
const HAS_EL = (aria) => `!![].slice.call(document.querySelectorAll('[aria-label]')).filter(function(e){return e.getAttribute('aria-label')===${JSON.stringify(aria)};})[0]`;
const SWITCH_STATE = (kw) => `(function(){var s=[].slice.call(document.querySelectorAll('[role=switch]')).filter(function(e){return (e.getAttribute('aria-label')||'').indexOf(${JSON.stringify(kw)})>=0;})[0];return s? s.getAttribute('aria-checked'):'NA';})()`;
const SWITCH_ON = (kw) => `(function(){var s=[].slice.call(document.querySelectorAll('[role=switch]')).filter(function(e){return (e.getAttribute('aria-label')||'').indexOf(${JSON.stringify(kw)})>=0;})[0];if(!s)return 'MISS';if(s.getAttribute('aria-checked')==='true')return 'ALREADY';s.click();return 'ON';})()`;

const HOOK = `
(function(){
  if(window.__piikAuto) return;
  window.__piikAuto = { rooms: [] };
  // Seed the persisted remote-control mode BEFORE the host UI mounts. A fresh
  // Chrome profile has empty localStorage, so the form draft would default to
  // "ask" and switching remote control on would immediately apply "ask" --
  // leaving every Viewer stuck on "waiting for host approval".
  try {
    var K = 'piik:room-preferences:v1';
    var raw = window.localStorage.getItem(K);
    var obj = raw ? JSON.parse(raw) : {};
    obj.remoteControlMode = 'room';
    window.localStorage.setItem(K, JSON.stringify(obj));
  } catch (e) {}
  var orig = window.fetch;
  window.fetch = function(input, init){
    try {
      var url = typeof input === 'string' ? input : ((input && input.url) || '');
      var method = ((init && init.method) || 'GET').toUpperCase();
      if (url.indexOf('/api/rooms') >= 0 && method === 'POST'
          && url.indexOf('/access') < 0 && url.indexOf('replacement') < 0) {
        init = Object.assign({}, init, {
          body: JSON.stringify({ codeEntryPolicy: 'private', roomPassword: ${JSON.stringify(CFG.password)} })
        });
      }
    } catch (e) {}
    return orig.call(this, input, init).then(function(resp){
      try {
        if (((resp && resp.url) || '').indexOf('/api/rooms') >= 0) {
          resp.clone().json().then(function(j){ window.__piikAuto.rooms.push(j); }).catch(function(){});
        }
      } catch (e) {}
      return resp;
    });
  };
})();`;

async function step(name, fn) {
  try {
    const v = await fn();
    R.steps.push(name + '=' + (typeof v === 'string' ? v.slice(0, 40) : String(v)));
    return v;
  } catch (e) {
    R.errors.push(name + ': ' + String(e).slice(0, 160));
    return null;
  }
}

async function waitFor(cdp, expr, ms) {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    if (await cdp.eval(expr).catch(() => false)) return true;
    await sleep(700);
  }
  return false;
}

try {
  const t = await getTarget();
  const cdp = new CDP(t.webSocketDebuggerUrl);
  await cdp.ready();
  await cdp.send('Runtime.enable');
  await cdp.send('Page.enable');
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: HOOK });
  await cdp.send('Page.navigate', { url: CFG.hostUrl });
  await cdp.eval('window.__piikAuto=window.__piikAuto||{rooms:[]}; 1');

  const ready = await waitFor(cdp, `(${HAS_EL('Create room')} || ${HAS_EL('Start sharing')} || ${HAS_EL('Stop sharing')})`, 60000);
  if (!ready) throw new Error('host ui not ready: ' + (await cdp.eval(TEXT)).slice(0, 160));

  // 1. room (private + password via hook)
  let rooms = [];
  await step('read-rooms', async () => {
    rooms = JSON.parse((await cdp.eval('JSON.stringify((window.__piikAuto&&window.__piikAuto.rooms)||[])')) || '[]');
    return rooms.length;
  });
  if (!rooms.length) {
    await step('create-room', () => cdp.eval(CLICK('Create room')));
    await sleep(3500);
    rooms = JSON.parse((await cdp.eval('JSON.stringify((window.__piikAuto&&window.__piikAuto.rooms)||[])')) || '[]');
  }
  if (!rooms.length) {
    // page restored an existing room from a previous run; reuse whatever code is on screen
    const m = (await cdp.eval(TEXT)).match(/Room code\s*((?:\d\s*){4})/);
    if (m) R.roomId = m[1].replace(/\s/g, '');
  }
  const room = rooms[rooms.length - 1];
  if (room) {
    R.roomId = room.roomId;
    R.inviteUrl = room.inviteUrl;
    R.policy = room.codeEntryPolicy;
  }
  await step('room', () => (R.roomId || 'MISS'));

  // 2. share the whole screen
  if (!(await cdp.eval(HAS('Stop sharing')))) {
    await step('start-sharing', () => cdp.eval(CLICK('Start sharing')));
    await waitFor(cdp, HAS_EL('Screens'), 20000);
    await step('screens-tab', () => cdp.eval(CLICK('Screens')));
    await waitFor(cdp, `!![].slice.call(document.querySelectorAll('[aria-label]')).filter(function(e){return (e.getAttribute('aria-label')||'').indexOf('Share screen:')===0;})[0]`, 20000);
    await step('pick-screen', () => cdp.eval(CLICKP('Share screen:')));
  }
  R.sharing = await waitFor(cdp, HAS('Stop sharing'), 25000);
  if (!R.sharing) throw new Error('sharing did not start');

  // 3. picture preset + measured limits
  await step('open-settings', () => cdp.eval(CLICK('Sharing settings')));
  await sleep(2500);
  await step('preset', () => cdp.eval(CLICKP(CFG.preset)));
  await sleep(2000);
  const w = (await cdp.eval(`(function(){var i=[].slice.call(document.querySelectorAll('input[aria-label="Width limit in pixels"]'))[0];return i? i.value:'';})()`)) || '';
  const h = (await cdp.eval(`(function(){var i=[].slice.call(document.querySelectorAll('input[aria-label="Height limit in pixels"]'))[0];return i? i.value:'';})()`)) || '';
  R.fps = Number((await cdp.eval(`(function(){var i=[].slice.call(document.querySelectorAll('input[aria-label="FPS limit"]'))[0];return i? i.value:'0';})()`)) || 0);
  R.resolution = w && h ? (w + 'x' + h) : '';
  R.preset = R.resolution ? (R.resolution + '@' + (R.fps || 0) + 'fps') : '';

  // 4. system sound: only flip if it is off; a GPU-less VM may have no audio endpoint
  let sw = await cdp.eval(SWITCH_STATE('System sound')).catch(() => 'NA');
  if (sw === 'false') {
    await step('sound-on', () => cdp.eval(SWITCH_ON('System sound')));
    await sleep(2000);
    sw = await cdp.eval(SWITCH_STATE('System sound')).catch(() => 'NA');
  }
  R.audioSwitch = sw;
  R.audio = !(await cdp.eval(HAS('Source sound is not being shared')));

  // 5. remote control, authorized for ROOM VIEWERS (not the default ask mode).
  //    Policy modes live in internal/app/remoteinput/policy.go: off | ask | room | password.
  //    - "ask" (default): every Viewer request is parked as pending until the host
  //      clicks Allow -- i.e. the "waiting for host" prompt.
  //    - "room": Manager.receive() takes the non-ask branch, authorize("") passes and
  //      canJoin() succeeds, so the grant is issued automatically. This is what we want.
  //    Picking the segment only edits a local form draft; the applied policy changes
  //    solely when the commit button is pressed. Skipping it silently left "ask" active.
  await step('open-remote', () => cdp.eval(CLICK_ANY(['Remote control', '远程控制'])));
  await sleep(2500);
  await step('remote-switch', () => cdp.eval(SWITCH_ANY(['Remote control', '远程控制'])));
  await sleep(2500);
  await step('remote-mode-room', () => cdp.eval(CLICK_ANY(['Room Viewers', '房间观众'])));
  await sleep(1500);
  // Commit button: "Allow Viewers" while control is still off, "Apply" once it is on.
  await step('remote-commit', () => cdp.eval(CLICK_ANY(['Allow Viewers', '允许观众控制', 'Apply', '应用'])));
  await sleep(3500);
  R.remoteControl = (await cdp.eval(SWITCH_STATE_ANY(['Remote control', '远程控制'])).catch(() => 'NA')) === 'true';
  // The commit row is rendered only while draft !== applied mode. Its disappearance is
  // the only DOM-level proof that "room" was actually applied rather than just drafted.
  R.remoteApplied = !(await cdp.eval(HAS_ANY(['Allow Viewers', '允许观众控制', 'Apply', '应用'])));
  R.remoteMode = R.remoteApplied ? 'room' : (await cdp.eval(`(function(){var b=[].slice.call(document.querySelectorAll('[aria-label="Room Viewers"],[aria-label="房间观众"]'))[0];return b? (b.getAttribute('aria-pressed')||'') : 'NA';})()`)) || '';

  if (R.inviteUrl) {
    try { R.site = new URL(R.inviteUrl).origin; } catch (e) {}
  }
  R.ok = !!(R.sharing && R.inviteUrl && R.remoteControl && R.remoteApplied);
  cdp.close();
} catch (e) {
  R.errors.push('fatal: ' + String(e).slice(0, 240));
}

R.elapsedSec = Math.round((Date.now() - t0) / 1000);
try {
  fs.mkdirSync(CFG.out.replace(/[\\/][^\\/]+$/, ''), { recursive: true });
} catch (e) {}
fs.writeFileSync(CFG.out, JSON.stringify(R, null, 1), 'utf8');
console.log(JSON.stringify({ ok: R.ok, roomId: R.roomId, sharing: R.sharing, remote: R.remoteControl, remoteMode: R.remoteMode, audio: R.audio, el: R.elapsedSec }));
process.exit(R.ok ? 0 : 1);
