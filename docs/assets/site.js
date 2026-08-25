const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const revealObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.isIntersecting) {
      entry.target.classList.add('visible');
      revealObserver.unobserve(entry.target);
    }
  });
}, { threshold: 0.12 });

document.querySelectorAll('.reveal').forEach((element) => revealObserver.observe(element));

const desktop = document.querySelector('#desktop-demo');
const startButton = document.querySelector('#demo-start');
const startPanel = document.querySelector('#demo-start-panel');
const taskbarApps = [...document.querySelectorAll('.taskbar-app')];
const previews = new Map([...document.querySelectorAll('[data-preview]')].map((preview) => [preview.dataset.preview, preview]));
const demoWindows = new Map([...document.querySelectorAll('[data-demo-window]')].map((windowElement) => [windowElement.dataset.demoWindow, windowElement]));
let previewTimer;
let activeApp = 'home';
let peekWasActive = false;

function closeStart() {
  startPanel?.classList.remove('open');
  startPanel?.setAttribute('aria-hidden', 'true');
  startButton?.setAttribute('aria-expanded', 'false');
}

function closePreviews() {
  clearTimeout(previewTimer);
  previews.forEach((preview) => {
    preview.classList.remove('open');
    preview.setAttribute('aria-hidden', 'true');
  });
  taskbarApps.forEach((button) => button.classList.remove('previewing'));
  stopAeroPeek();
}

function openPreview(app) {
  const preview = previews.get(app);
  if (!preview) return;
  closePreviews();
  preview.classList.add('open');
  preview.setAttribute('aria-hidden', 'false');
  document.querySelector(`.taskbar-app[data-app="${app}"]`)?.classList.add('previewing');
}

function activateApp(app) {
  activeApp = app;
  desktop?.classList.toggle('app-open', app !== 'home');
  demoWindows.forEach((windowElement, name) => windowElement.classList.toggle('active', name === app));
  closeStart();
  closePreviews();
}

function startAeroPeek(app) {
  const target = demoWindows.get(app);
  if (!desktop || !target) return;
  peekWasActive = target.classList.contains('active');
  target.classList.add('active', 'peek-target');
  desktop.classList.add('aero-active');
}

function stopAeroPeek() {
  if (!desktop) return;
  desktop.classList.remove('aero-active');
  demoWindows.forEach((windowElement, name) => {
    windowElement.classList.remove('peek-target');
    if (name !== activeApp && !peekWasActive) windowElement.classList.remove('active');
  });
  peekWasActive = false;
}

startButton?.addEventListener('click', (event) => {
  event.stopPropagation();
  const opening = !startPanel?.classList.contains('open');
  closePreviews();
  startPanel?.classList.toggle('open', opening);
  startPanel?.setAttribute('aria-hidden', String(!opening));
  startButton.setAttribute('aria-expanded', String(opening));
});

taskbarApps.forEach((button) => {
  const app = button.dataset.app;
  button.addEventListener('mouseenter', () => {
    clearTimeout(previewTimer);
    closeStart();
    previewTimer = setTimeout(() => openPreview(app), 180);
  });
  button.addEventListener('mouseleave', () => {
    previewTimer = setTimeout(closePreviews, 180);
  });
  button.addEventListener('click', () => {
    if (demoWindows.has(app)) activateApp(app);
    else {
      button.animate([{ transform: 'translateY(-3px) scale(1)' }, { transform: 'translateY(-5px) scale(1.08)' }, { transform: 'translateY(-3px) scale(1)' }], { duration: 330, easing: 'ease-out' });
    }
  });
});

previews.forEach((preview, app) => {
  preview.addEventListener('mouseenter', () => {
    clearTimeout(previewTimer);
    startAeroPeek(app);
  });
  preview.addEventListener('mouseleave', () => {
    stopAeroPeek();
    previewTimer = setTimeout(closePreviews, 180);
  });
  preview.addEventListener('click', () => activateApp(app));
});

desktop?.addEventListener('click', (event) => {
  if (!startPanel?.contains(event.target) && !startButton?.contains(event.target)) closeStart();
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    closeStart();
    closePreviews();
  }
});

const search = document.querySelector('.start-search input');
search?.addEventListener('input', () => {
  const query = search.value.trim().toLowerCase();
  document.querySelectorAll('.start-grid button').forEach((button) => {
    button.hidden = !button.textContent.toLowerCase().includes(query);
  });
});

function updateClock() {
  const now = new Date();
  const time = new Intl.DateTimeFormat([], { hour: '2-digit', minute: '2-digit' }).format(now);
  const date = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric' }).format(now);
  const timeElement = document.querySelector('#demo-time');
  const dateElement = document.querySelector('#demo-date');
  if (timeElement) timeElement.textContent = time;
  if (dateElement) dateElement.textContent = date;
}

updateClock();
setInterval(updateClock, 30_000);
