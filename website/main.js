(() => {
  document.documentElement.classList.add('js');

  const nav = document.getElementById('nav');
  const hero = document.querySelector('.hero');

  const onScroll = () => {
    const past = hero ? window.scrollY > hero.offsetHeight - 72 : window.scrollY > 40;
    nav.classList.toggle('is-solid', past);
  };
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });

  const reveals = document.querySelectorAll('.reveal');
  const show = (el) => el.classList.add('is-in');
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          show(e.target);
          io.unobserve(e.target);
        }
      }
    }, { rootMargin: '0px 0px -6% 0px', threshold: 0.08 });
    reveals.forEach((el) => io.observe(el));
    // Programmatic scrolls / late layout: catch anything already on screen
    requestAnimationFrame(() => {
      reveals.forEach((el) => {
        const r = el.getBoundingClientRect();
        if (r.top < window.innerHeight * 0.92 && r.bottom > 64) show(el);
      });
    });
  } else {
    reveals.forEach(show);
  }

  // Defer the heavy dither iframe until the page has loaded and gone idle, so
  // its canvas simulation never blocks first paint or inflates blocking time.
  const frame = document.querySelector('.hero-viz');
  if (frame && frame.dataset.src) {
    const load = () => { if (!frame.src) frame.src = frame.dataset.src; };
    const idle = () => ('requestIdleCallback' in window)
      ? requestIdleCallback(load, { timeout: 1500 })
      : setTimeout(load, 200);
    if (document.readyState === 'complete') idle();
    else window.addEventListener('load', idle, { once: true });
  }

  // Pause dither iframe work when the hero leaves the viewport.
  if (frame && 'IntersectionObserver' in window) {
    const freeze = new IntersectionObserver(([e]) => {
      try {
        frame.contentWindow?.postMessage({ type: 'mouse-dither', visible: e.isIntersecting }, '*');
      } catch (_) { /* cross-origin or not ready */ }
    }, { threshold: 0.05 });
    freeze.observe(hero);
  }

  // Live GitHub star count in the nav pill; falls back to the plain label.
  const stars = document.getElementById('gh-stars');
  const starsFallback = document.getElementById('gh-fallback');
  if (stars) {
    fetch('https://api.github.com/repos/reagent-systems/mouse', {
      headers: { Accept: 'application/vnd.github+json' }
    })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        const n = d && d.stargazers_count;
        if (typeof n !== 'number') return;
        stars.textContent = n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(/\.0$/, '') + 'k' : String(n);
        if (starsFallback) starsFallback.style.display = 'none';
      })
      .catch(() => { /* offline or rate-limited: keep the label */ });
  }
})();
