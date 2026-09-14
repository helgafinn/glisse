/* Glissé — the page edges behave like the app.
   A drag only counts if it BEGINS on the edge, which is the app's own
   activation rule. Left edge dims the page, right edge moves a volume HUD. */

(() => {
  'use strict';

  const SEGMENTS = 16;
  const MAX_DIM = 0.5; // capped so body text stays readable at the bottom of the range
  const INSET = 11;    // rail padding, in percent, matching .rail-ticks in the CSS

  const dim = document.getElementById('dim');
  const hud = document.getElementById('hud');
  const segs = document.getElementById('hud-segs');
  const glyphBrightness = document.getElementById('glyph-brightness');
  const glyphVolume = document.getElementById('glyph-volume');
  const nudges = document.querySelectorAll('.nudge');
  const hero = document.querySelector('.hero');
  const heroScene = document.querySelector('.hero-scene');

  const reducedQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
  const finePointerQuery = window.matchMedia('(hover: hover) and (pointer: fine)');
  let reduced = reducedQuery.matches;
  let finePointer = finePointerQuery.matches;

  // start at full brightness so the page is never dimmed before the user asks
  const state = { brightness: 1, volume: 0.62 };
  let hudTimer = null;
  let audioCtx = null;
  let touched = false;

  /* ---- smooth desktop wheel motion; native for touch, keys, and reduced motion ---- */
  const wheelScroll = {
    targetY: window.scrollY,
    rafId: null,
    lastFrame: 0,
    direction: 0,
    lastWrittenY: null
  };
  const wheelScrollKeys = new Set([
    'ArrowDown', 'ArrowLeft', 'ArrowRight', 'ArrowUp',
    'End', 'Home', 'PageDown', 'PageUp', ' ', 'Tab'
  ]);

  function wheelScrollCanRun() {
    return Boolean(!reduced && finePointer);
  }

  function maxScrollY() {
    return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
  }

  function stopWheelScroll() {
    if (wheelScroll.rafId !== null) cancelAnimationFrame(wheelScroll.rafId);
    wheelScroll.rafId = null;
    wheelScroll.lastFrame = 0;
    wheelScroll.direction = 0;
    wheelScroll.lastWrittenY = null;
    wheelScroll.targetY = window.scrollY;
    document.documentElement.classList.remove('is-wheel-scrolling');
  }

  function writeWheelScroll(y) {
    wheelScroll.lastWrittenY = y;
    window.scrollTo(0, y);
  }

  function stepWheelScroll(now) {
    wheelScroll.rafId = null;
    if (!wheelScrollCanRun() || document.hidden) {
      stopWheelScroll();
      return;
    }

    wheelScroll.targetY = Math.min(maxScrollY(), Math.max(0, wheelScroll.targetY));
    const distance = wheelScroll.targetY - window.scrollY;
    if (Math.abs(distance) < 0.5) {
      writeWheelScroll(wheelScroll.targetY);
      wheelScroll.targetY = window.scrollY;
      wheelScroll.lastFrame = 0;
      wheelScroll.direction = 0;
      wheelScroll.lastWrittenY = null;
      document.documentElement.classList.remove('is-wheel-scrolling');
      return;
    }

    // Keep the same feel at 60 Hz and 120 Hz instead of using a per-frame lerp.
    const frameMs = wheelScroll.lastFrame
      ? Math.min(48, Math.max(1, now - wheelScroll.lastFrame))
      : 1000 / 60;
    wheelScroll.lastFrame = now;
    const blend = 1 - Math.pow(1 - 0.16, frameMs / (1000 / 60));
    writeWheelScroll(window.scrollY + distance * blend);
    wheelScroll.rafId = requestAnimationFrame(stepWheelScroll);
  }

  function normalizeWheelDelta(delta, mode) {
    if (mode === 1) return delta * 16;
    if (mode === 2) return delta * window.innerHeight;
    return delta;
  }

  function nestedScrollerCanConsume(start, deltaX, deltaY) {
    let element = start instanceof Element ? start : null;
    while (element && element !== document.documentElement) {
      const style = window.getComputedStyle(element);
      const canScrollY = /^(auto|scroll|overlay)$/.test(style.overflowY) &&
        element.scrollHeight > element.clientHeight + 1;
      const canScrollX = /^(auto|scroll|overlay)$/.test(style.overflowX) &&
        element.scrollWidth > element.clientWidth + 1;

      const canMoveY = canScrollY && (
        (deltaY < 0 && element.scrollTop > 0) ||
        (deltaY > 0 && element.scrollTop + element.clientHeight < element.scrollHeight - 1)
      );
      const canMoveX = canScrollX && (
        (deltaX < 0 && element.scrollLeft > 0) ||
        (deltaX > 0 && element.scrollLeft + element.clientWidth < element.scrollWidth - 1)
      );
      if (canMoveY || canMoveX) return true;
      element = element.parentElement;
    }
    return false;
  }

  document.addEventListener('wheel', (event) => {
    if (!wheelScrollCanRun() || !event.cancelable || event.ctrlKey || event.defaultPrevented) {
      stopWheelScroll();
      return;
    }

    const deltaX = normalizeWheelDelta(event.deltaX, event.deltaMode);
    const deltaY = normalizeWheelDelta(event.deltaY, event.deltaMode);
    if ((!deltaX && !deltaY) || nestedScrollerCanConsume(event.target, deltaX, deltaY)) {
      stopWheelScroll();
      return;
    }
    if (Math.abs(deltaY) <= Math.abs(deltaX)) {
      stopWheelScroll();
      return;
    }

    const direction = Math.sign(deltaY);
    const continuesDirection = wheelScroll.rafId !== null &&
      direction === wheelScroll.direction;
    const origin = continuesDirection ? wheelScroll.targetY : window.scrollY;
    const maxLead = Math.max(window.innerHeight * 1.5, Math.abs(deltaY));
    const intendedTarget = origin + deltaY;
    const boundedTarget = Math.min(
      window.scrollY + maxLead,
      Math.max(window.scrollY - maxLead, intendedTarget)
    );
    const nextTarget = Math.min(maxScrollY(), Math.max(0, boundedTarget));
    if (wheelScroll.rafId === null && Math.abs(nextTarget - window.scrollY) < 0.5) return;

    event.preventDefault();
    wheelScroll.targetY = nextTarget;
    wheelScroll.direction = direction;
    document.documentElement.classList.add('is-wheel-scrolling');
    if (wheelScroll.rafId === null) {
      wheelScroll.lastFrame = 0;
      wheelScroll.rafId = requestAnimationFrame(stepWheelScroll);
    }
  }, { passive: false });

  // Any navigation mode other than the wheel immediately returns control to the browser.
  document.addEventListener('pointerdown', stopWheelScroll, { passive: true });
  document.addEventListener('touchstart', stopWheelScroll, { passive: true });
  document.addEventListener('focusin', stopWheelScroll, { capture: true });
  document.addEventListener('keydown', (event) => {
    if (wheelScrollKeys.has(event.key)) stopWheelScroll();
  }, { capture: true });
  window.addEventListener('scroll', () => {
    if (wheelScroll.rafId === null) return;
    if (wheelScroll.lastWrittenY !== null &&
        Math.abs(window.scrollY - wheelScroll.lastWrittenY) < 1) {
      wheelScroll.lastWrittenY = null;
      return;
    }
    stopWheelScroll();
  }, { passive: true });
  window.addEventListener('hashchange', stopWheelScroll);
  window.addEventListener('resize', () => {
    wheelScroll.targetY = Math.min(maxScrollY(), wheelScroll.targetY);
  }, { passive: true });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) stopWheelScroll();
  });

  /* ---- decorative product motion; never writes to a live Rail ---- */
  const transientDemoPauses = new Set();
  let demoIsUserOwned = false;
  let heroVisible = (() => {
    if (!hero) return false;
    const rect = hero.getBoundingClientRect();
    return rect.bottom > 0 && rect.top < window.innerHeight;
  })();

  const parallax = {
    currentX: 0,
    currentY: 0,
    targetX: 0,
    targetY: 0,
    pointerInside: false,
    rafId: null
  };

  // Ambient decoration only rests when it cannot be seen or motion is unwanted.
  function ambientMotionCanRun() {
    return Boolean(heroVisible && !document.hidden && !reduced);
  }

  // The product demonstration additionally yields to the real sliders.
  function heroMotionCanRun() {
    return Boolean(
      heroScene &&
      ambientMotionCanRun() &&
      !demoIsUserOwned &&
      transientDemoPauses.size === 0
    );
  }

  function parallaxCanRun() {
    return heroMotionCanRun() && finePointer;
  }

  function paintParallax(x, y) {
    if (!heroScene) return;

    // The combined offsets top out around five pixels and two degrees.
    heroScene.style.setProperty('--stage-x', `${(x * 1.2).toFixed(2)}px`);
    heroScene.style.setProperty('--stage-y', `${(y * 0.9).toFixed(2)}px`);
    heroScene.style.setProperty('--tilt-x', `${(-y * 1.4).toFixed(2)}deg`);
    heroScene.style.setProperty('--tilt-y', `${(x * 1.8).toFixed(2)}deg`);
    heroScene.style.setProperty('--back-x', `${(-x * 1.4).toFixed(2)}px`);
    heroScene.style.setProperty('--back-y', `${(-y * 1.1).toFixed(2)}px`);
    heroScene.style.setProperty('--device-x', `${(x * 0.7).toFixed(2)}px`);
    heroScene.style.setProperty('--device-y', `${(y * 0.55).toFixed(2)}px`);
    heroScene.style.setProperty('--front-x', `${(x * 3.4).toFixed(2)}px`);
    heroScene.style.setProperty('--front-y', `${(y * 2.6).toFixed(2)}px`);
  }

  function stepParallax() {
    parallax.rafId = null;

    if (!parallaxCanRun()) {
      parallax.currentX = 0;
      parallax.currentY = 0;
      paintParallax(0, 0);
      return;
    }

    const easing = parallax.pointerInside ? 0.14 : 0.38;
    parallax.currentX += (parallax.targetX - parallax.currentX) * easing;
    parallax.currentY += (parallax.targetY - parallax.currentY) * easing;

    const closeEnough =
      Math.abs(parallax.targetX - parallax.currentX) < 0.002 &&
      Math.abs(parallax.targetY - parallax.currentY) < 0.002;

    if (closeEnough) {
      parallax.currentX = parallax.targetX;
      parallax.currentY = parallax.targetY;
    }

    paintParallax(parallax.currentX, parallax.currentY);
    if (!closeEnough) parallax.rafId = requestAnimationFrame(stepParallax);
  }

  function scheduleParallax() {
    if (parallax.rafId === null) {
      parallax.rafId = requestAnimationFrame(stepParallax);
    }
  }

  function resetParallax(immediate = false) {
    parallax.targetX = 0;
    parallax.targetY = 0;

    if (immediate || !parallaxCanRun()) {
      if (parallax.rafId !== null) cancelAnimationFrame(parallax.rafId);
      parallax.rafId = null;
      parallax.currentX = 0;
      parallax.currentY = 0;
      paintParallax(0, 0);
      return;
    }

    scheduleParallax();
  }

  function syncHeroMotion() {
    if (!heroScene) return;
    const paused = !heroMotionCanRun();
    // Confetti keeps drifting after a real gesture; only the demo hands over.
    if (hero) hero.classList.toggle('is-motion-paused', !ambientMotionCanRun());
    heroScene.classList.toggle('is-motion-paused', paused);
    heroScene.classList.toggle('is-user-owned', demoIsUserOwned);
    if (paused || !finePointer) resetParallax(true);
  }

  function setTransientDemoPause(reason, active) {
    if (active) transientDemoPauses.add(reason);
    else transientDemoPauses.delete(reason);
    syncHeroMotion();
  }

  function claimDecorativeDemo() {
    if (demoIsUserOwned) return;
    demoIsUserOwned = true;
    resetParallax(true);
    syncHeroMotion();
  }

  if (hero && heroScene) {
    hero.addEventListener('pointerenter', () => {
      if (!parallaxCanRun()) return;
      parallax.pointerInside = true;
    }, { passive: true });

    hero.addEventListener('pointermove', (event) => {
      if (!parallaxCanRun()) return;
      const rect = hero.getBoundingClientRect();
      if (!rect.width || !rect.height) return;

      parallax.pointerInside = true;
      parallax.targetX = Math.max(-1, Math.min(1,
        ((event.clientX - rect.left) / rect.width - 0.5) * 2));
      parallax.targetY = Math.max(-1, Math.min(1,
        ((event.clientY - rect.top) / rect.height - 0.5) * 2));
      scheduleParallax();
    }, { passive: true });

    hero.addEventListener('pointerleave', () => {
      parallax.pointerInside = false;
      resetParallax(false);
    }, { passive: true });
  }

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
    glyphVolume.style.display = kind === 'volume' ? '' : 'none';
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
    claimDecorativeDemo();
    if (touched) return;
    touched = true;
    nudges.forEach((nudge) => nudge.classList.add('done'));
  }

  class Rail {
    constructor(el) {
      this.el = el;
      this.kind = el.dataset.kind;
      this.thumb = el.querySelector('.rail-thumb');
      this.ticks = [...el.querySelectorAll('.rail-ticks i')];
      this.lastSeg = -1;
      this.dragging = false;
      this.hoverPause = `rail-hover-${this.kind}`;
      this.focusPause = `rail-focus-${this.kind}`;

      el.addEventListener('pointerdown', this.down.bind(this));
      el.addEventListener('pointermove', this.move.bind(this));
      el.addEventListener('pointerup', this.up.bind(this));
      el.addEventListener('pointercancel', this.up.bind(this));
      el.addEventListener('keydown', this.key.bind(this));
      el.addEventListener('pointerenter', () => setTransientDemoPause(this.hoverPause, true));
      el.addEventListener('pointerleave', () => setTransientDemoPause(this.hoverPause, false));
      el.addEventListener('focus', () => {
        setTransientDemoPause(this.focusPause, true);
        this.show();
      });
      el.addEventListener('blur', () => setTransientDemoPause(this.focusPause, false));
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
      this.ticks.forEach((tickEl, i) =>
        tickEl.classList.toggle('lit', (this.ticks.length - 1 - i) < lit));
      if (this.kind === 'brightness') applyBrightness();
    }

    show() { paintHud(this.kind, this.value); }

    commit(v) {
      this.value = v;
      const seg = Math.round(this.value * SEGMENTS);
      if (seg !== this.lastSeg) { this.lastSeg = seg; tick(); }
      this.show();
    }

    down(event) {
      // the gesture must begin on the rail — same rule the app enforces
      this.dragging = true;
      this.el.classList.add('is-live');
      this.el.setPointerCapture(event.pointerId);
      firstTouch();
      this.commit(this.fromPointer(event));
      event.preventDefault();
    }

    move(event) {
      if (!this.dragging) return;
      this.commit(this.fromPointer(event));
      event.preventDefault();
    }

    up(event) {
      if (!this.dragging) return;
      this.dragging = false;
      this.el.classList.remove('is-live');
      try { this.el.releasePointerCapture(event.pointerId); } catch (_) {}
    }

    fromPointer(event) {
      const rect = this.el.getBoundingClientRect();
      const pad = rect.height * (INSET / 100); // matches the visual tick ladder inset
      const usable = rect.height - pad * 2;
      return 1 - (event.clientY - rect.top - pad) / usable;
    }

    key(event) {
      const step = event.shiftKey ? 1 / SEGMENTS / 4 : 1 / SEGMENTS;
      const map = {
        ArrowUp: step, ArrowRight: step,
        ArrowDown: -step, ArrowLeft: -step,
        PageUp: step * 4, PageDown: -step * 4
      };
      let next = null;
      if (event.key in map) next = this.value + map[event.key];
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = 1;
      if (next === null) return;
      event.preventDefault();
      firstTouch();
      this.commit(next);
    }
  }

  // Each instance owns its own listeners, including the transient demo-pause lifecycle.
  document.querySelectorAll('.rail').forEach((el) => new Rail(el));
  applyBrightness();

  /* ---- one observer for visibility, reveals, and one-shot SVG stories ---- */
  const revealTargets = new Set();
  const activeRevealTargets = new Set();
  const revealCompletions = new Map();
  const oneShotTargets = new Set();
  const activeOneShotTargets = new Set();
  const oneShotTimers = new Map();
  let observer = null;

  function maybeStopObserving(target) {
    if (!observer || target === hero) return;
    if (!revealTargets.has(target) && !oneShotTargets.has(target)) {
      observer.unobserve(target);
    }
  }

  function finishReveal(target) {
    const completion = revealCompletions.get(target);
    if (completion) {
      target.removeEventListener('transitionend', completion.handler);
      clearTimeout(completion.timer);
    }
    revealCompletions.delete(target);
    activeRevealTargets.delete(target);
    target.classList.remove('is-reveal-pending', 'is-revealed');
  }

  function revealOnce(target) {
    const handler = (event) => {
      if (event.target === target && event.propertyName === 'transform') finishReveal(target);
    };
    const timer = setTimeout(() => finishReveal(target), 1050);

    activeRevealTargets.add(target);
    revealCompletions.set(target, { handler, timer });
    target.addEventListener('transitionend', handler);
    target.classList.add('is-revealed');
  }

  function oneShotRuntime(target) {
    if (target.matches('.activation-scene')) return 1750;
    if (target.matches('.edge-illo')) return 1150;
    return 1050;
  }

  function finishOneShot(target) {
    const timer = oneShotTimers.get(target);
    if (timer !== undefined) clearTimeout(timer);
    oneShotTimers.delete(target);
    activeOneShotTargets.delete(target);
    target.classList.remove('is-motion-pending', 'is-animated');
    target.classList.add('is-motion-complete');
  }

  function startOneShot(target) {
    activeOneShotTargets.add(target);
    target.classList.add('is-animated');
    const timer = setTimeout(() => finishOneShot(target), oneShotRuntime(target));
    oneShotTimers.set(target, timer);
  }

  if ('IntersectionObserver' in window) {
    observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        const target = entry.target;

        if (target === hero) {
          heroVisible = entry.isIntersecting;
          syncHeroMotion();
        }

        if (!entry.isIntersecting) return;

        if (revealTargets.has(target)) {
          revealOnce(target);
          revealTargets.delete(target);
        }

        if (oneShotTargets.has(target)) {
          startOneShot(target);
          oneShotTargets.delete(target);
        }

        maybeStopObserving(target);
      });
    }, {
      rootMargin: '0px 0px -8% 0px',
      threshold: [0, 0.14, 0.35]
    });
  }

  function registerRevealGroup(elements, delayStep = 70, delayCap = 240) {
    if (!observer || reduced) return;
    elements.filter(Boolean).forEach((element, index) => {
      if (revealTargets.has(element)) return;
      element.classList.add('reveal-item', 'is-reveal-pending');
      element.style.setProperty('--reveal-delay', `${Math.min(index * delayStep, delayCap)}ms`);
      revealTargets.add(element);
      observer.observe(element);
    });
  }

  function registerOneShot(elements) {
    if (!observer || reduced) return;
    elements.filter(Boolean).forEach((element) => {
      element.classList.add('is-motion-pending');
      oneShotTargets.add(element);
      observer.observe(element);
    });
  }

  if (observer) {
    if (hero) observer.observe(hero);

    const heroGrid = hero && hero.querySelector('.hero-grid');
    registerRevealGroup([
      hero && hero.querySelector('.hero-top'),
      heroGrid && heroGrid.firstElementChild,
      heroScene
    ], 100);

    registerRevealGroup([...document.querySelectorAll('.edge')], 100);

    const activationScene = document.querySelector('.activation-scene');
    const activationGrid = activationScene && activationScene.closest('.hero-grid');
    registerRevealGroup([
      activationGrid && activationGrid.firstElementChild,
      activationScene
    ], 100);

    const featureList = document.querySelector('.feat');
    const featureWrap = featureList && featureList.parentElement;
    registerRevealGroup([
      featureWrap && featureWrap.querySelector(':scope > .pill'),
      featureWrap && featureWrap.querySelector(':scope > .h2')
    ], 80);
    registerRevealGroup(featureList ? [...featureList.children] : [], 34, 238);

    const install = document.getElementById('install');
    const honestList = document.querySelector('.honest');
    registerRevealGroup([
      install && install.querySelector('.wrap'),
      honestList && honestList.closest('.wrap')
    ], 100);

    registerOneShot([
      ...document.querySelectorAll('.edge-illo'),
      activationScene,
      ...document.querySelectorAll('.motion-wave')
    ]);
  } else {
    syncHeroMotion();
  }

  function completePendingMotion() {
    revealTargets.forEach((target) => {
      target.classList.remove('is-reveal-pending', 'is-revealed');
      if (observer) observer.unobserve(target);
    });
    revealTargets.clear();
    activeRevealTargets.forEach((target) => finishReveal(target));

    oneShotTargets.forEach((target) => {
      target.classList.remove('is-motion-pending');
      target.classList.add('is-motion-complete');
      if (observer) observer.unobserve(target);
    });
    oneShotTargets.clear();

    activeOneShotTargets.forEach((target) => finishOneShot(target));
  }

  function onReducedMotionChange(event) {
    reduced = event.matches;
    if (reduced) completePendingMotion();
    syncHeroMotion();
  }

  function onFinePointerChange(event) {
    finePointer = event.matches;
    if (!finePointer) resetParallax(true);
    syncHeroMotion();
  }

  function listenToMediaChange(query, handler) {
    if (typeof query.addEventListener === 'function') query.addEventListener('change', handler);
    else if (typeof query.addListener === 'function') query.addListener(handler);
  }

  listenToMediaChange(reducedQuery, onReducedMotionChange);
  listenToMediaChange(finePointerQuery, onFinePointerChange);

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) resetParallax(true);
    syncHeroMotion();
  });

  syncHeroMotion();

  /* ---- copy the install command ---- */
  const toast = document.getElementById('toast');
  let toastTimer = null;
  function flash(message) {
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), 1800);
  }

  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', async () => {
      const text = button.dataset.copy;
      try {
        await navigator.clipboard.writeText(text);
        flash('Copied');
      } catch (_) {
        // clipboard can be blocked; select the text so the user can copy it
        const target = document.getElementById(button.dataset.for);
        if (target) {
          const range = document.createRange();
          range.selectNodeContents(target);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        }
        flash('Press Cmd C');
      }
    });
  });
})();
