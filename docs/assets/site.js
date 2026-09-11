/* Glissé — the page edges behave like the app.
   A drag only counts if it BEGINS on the edge, which is the app's own
   activation rule. Left edge dims the page, right edge moves a volume HUD. */

(() => {
  'use strict';

  const SEGMENTS = 16;
  const MAX_DIM = 0.5; // capped so body text stays readable at the bottom of the range
  const INSET = 11;    // rail padding, in percent, matching .rail-ticks in the CSS

  const dim   = document.getElementById('dim');
  const hud   = document.getElementById('hud');
  const segs  = document.getElementById('hud-segs');
  const glyphBrightness = document.getElementById('glyph-brightness');
  const glyphVolume     = document.getElementById('glyph-volume');
  const nudges = document.querySelectorAll('.nudge');
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // start at full brightness so the page is never dimmed before the user asks
  const state = { brightness: 1, volume: 0.62 };
  let hudTimer = null;
  let audioCtx = null;
  let touched = false;

  /* ---- soft tick, built on the fly, only after a real gesture ---- */
  function tick() {
    if (reduced) return;
    try {
      audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
      if (audioCtx.state === 'suspended') audioCtx.resume();
      const t = audioCtx.currentTime;
      const osc = audioCtx.createOscillator();
      const gain = audioCtx.createGain();
      osc.type = 'square';
      osc.frequency.setValueAtTime(2100, t);
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.035, t + 0.001);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.03);
      osc.connect(gain).connect(audioCtx.destination);
      osc.start(t);
      osc.stop(t + 0.04);
    } catch (_) { /* audio is a bonus, never a requirement */ }
  }

  function paintHud(kind, value) {
    const lit = Math.round(value * SEGMENTS);
    [...segs.children].forEach((el, i) => el.classList.toggle('on', i < lit));
    // NB: `.hidden` is an HTMLElement property. Assigning it on an SVGElement
    // silently creates a JS expando and sets no attribute, so toggle style.
    glyphBrightness.style.display = kind === 'brightness' ? '' : 'none';
    glyphVolume.style.display     = kind === 'volume' ? '' : 'none';
    hud.classList.add('show');
    hud.setAttribute('aria-label',
      (kind === 'brightness' ? 'Brightness ' : 'Volume ') + Math.round(value * 100) + '%');
    clearTimeout(hudTimer);
    hudTimer = setTimeout(() => hud.classList.remove('show'), 1100);
  }

  function applyBrightness() {
    dim.style.opacity = String((1 - state.brightness) * MAX_DIM);
  }

  function firstTouch() {
    if (touched) return;
    touched = true;
    nudges.forEach((n) => n.classList.add('done'));
  }

  class Rail {
    constructor(el) {
      this.el = el;
      this.kind = el.dataset.kind;
      this.thumb = el.querySelector('.rail-thumb');
      this.ticks = [...el.querySelectorAll('.rail-ticks i')];
      this.lastSeg = -1;
      this.dragging = false;

      el.addEventListener('pointerdown', this.down.bind(this));
      el.addEventListener('pointermove', this.move.bind(this));
      el.addEventListener('pointerup', this.up.bind(this));
      el.addEventListener('pointercancel', this.up.bind(this));
      el.addEventListener('keydown', this.key.bind(this));
      el.addEventListener('focus', () => this.show());
      this.render();
    }

    get value() { return state[this.kind]; }
    set value(v) {
      state[this.kind] = Math.min(1, Math.max(0, v));
      this.render();
    }

    render() {
      const v = this.value;
      // keep the thumb inside the tick ladder (11%..89%) so it never clips the rail ends
      this.thumb.style.bottom = (INSET + v * (100 - INSET * 2)) + '%';
      this.el.setAttribute('aria-valuenow', String(Math.round(v * 100)));
      const lit = Math.round(v * this.ticks.length);
      // ticks are laid out top-to-bottom, value runs bottom-to-top
      this.ticks.forEach((t, i) =>
        t.classList.toggle('lit', (this.ticks.length - 1 - i) < lit));
      if (this.kind === 'brightness') applyBrightness();
    }

    show() { paintHud(this.kind, this.value); }

    commit(v) {
      this.value = v;
      const seg = Math.round(this.value * SEGMENTS);
      if (seg !== this.lastSeg) { this.lastSeg = seg; tick(); }
      this.show();
    }

    down(e) {
      // the gesture must begin on the rail — same rule the app enforces
      this.dragging = true;
      this.el.classList.add('is-live');
      this.el.setPointerCapture(e.pointerId);
      firstTouch();
      this.commit(this.fromPointer(e));
      e.preventDefault();
    }

    move(e) {
      if (!this.dragging) return;
      this.commit(this.fromPointer(e));
      e.preventDefault();
    }

    up(e) {
      if (!this.dragging) return;
      this.dragging = false;
      this.el.classList.remove('is-live');
      try { this.el.releasePointerCapture(e.pointerId); } catch (_) {}
    }

    fromPointer(e) {
      const r = this.el.getBoundingClientRect();
      const pad = r.height * (INSET / 100); // matches the visual tick ladder inset
      const usable = r.height - pad * 2;
      return 1 - (e.clientY - r.top - pad) / usable;
    }

    key(e) {
      const step = e.shiftKey ? 1 / SEGMENTS / 4 : 1 / SEGMENTS;
      const map = {
        ArrowUp: step, ArrowRight: step,
        ArrowDown: -step, ArrowLeft: -step,
        PageUp: step * 4, PageDown: -step * 4
      };
      let next = null;
      if (e.key in map) next = this.value + map[e.key];
      else if (e.key === 'Home') next = 0;
      else if (e.key === 'End') next = 1;
      if (next === null) return;
      e.preventDefault();
      firstTouch();
      this.commit(next);
    }
  }

  document.querySelectorAll('.rail').forEach((el) => new Rail(el));
  applyBrightness();

  /* ---- copy the install command ---- */
  const toast = document.getElementById('toast');
  let toastTimer = null;
  function flash(msg) {
    toast.textContent = msg;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), 1800);
  }

  document.querySelectorAll('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const text = btn.dataset.copy;
      try {
        await navigator.clipboard.writeText(text);
        flash('Copied');
      } catch (_) {
        // clipboard can be blocked; select the text so the user can copy it
        const target = document.getElementById(btn.dataset.for);
        if (target) {
          const range = document.createRange();
          range.selectNodeContents(target);
          const sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
        }
        flash('Press Cmd C');
      }
    });
  });
})();
