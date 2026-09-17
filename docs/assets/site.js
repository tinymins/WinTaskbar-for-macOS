const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const revealObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add('visible');
    revealObserver.unobserve(entry.target);
  });
}, { threshold: 0.12 });

document.querySelectorAll('.reveal').forEach((element) => revealObserver.observe(element));

const demo = document.querySelector('#product-demo');
const modeButtons = [...document.querySelectorAll('[data-demo-mode]')];
const startHotspot = document.querySelector('.start-hotspot');
const appHotspots = [...document.querySelectorAll('.app-hotspot')];
const altTabTrigger = document.querySelector('#alt-tab-trigger');
const closeButton = document.querySelector('#demo-close');
const statusText = document.querySelector('#demo-status-text');
const startCapture = document.querySelector('#start-capture');
const altTabCapture = document.querySelector('#alt-tab-capture');

const statusByMode = {
  taskbar: 'Taskbar is ready — click the Start button',
  start: 'Start is open — click Start again to close it',
  'alt-tab': 'Alt+Tab is active — press Escape to return',
};

function setMode(mode) {
  if (!demo || !statusByMode[mode]) return;
  demo.dataset.mode = mode;
  modeButtons.forEach((button) => button.setAttribute('aria-pressed', String(button.dataset.demoMode === mode)));
  startCapture?.setAttribute('aria-hidden', String(mode !== 'start'));
  altTabCapture?.setAttribute('aria-hidden', String(mode !== 'alt-tab'));
  if (statusText) statusText.textContent = statusByMode[mode];
}

modeButtons.forEach((button) => button.addEventListener('click', () => setMode(button.dataset.demoMode)));
startHotspot?.addEventListener('click', () => setMode(demo?.dataset.mode === 'start' ? 'taskbar' : 'start'));
altTabTrigger?.addEventListener('click', () => setMode('alt-tab'));
closeButton?.addEventListener('click', () => setMode('taskbar'));

appHotspots.forEach((button) => {
  button.addEventListener('click', () => {
    setMode('taskbar');
    appHotspots.forEach((item) => item.classList.toggle('active', item === button));
    if (statusText) statusText.textContent = `${button.getAttribute('aria-label').replace('Activate ', '')} selected — hover labels follow the live taskbar pattern`;
    if (!reducedMotion) {
      button.animate(
        [{ transform: 'translateY(0)' }, { transform: 'translateY(-8px)' }, { transform: 'translateY(0)' }],
        { duration: 320, easing: 'cubic-bezier(.2,.8,.2,1)' },
      );
    }
  });
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && demo?.dataset.mode !== 'taskbar') setMode('taskbar');
});
