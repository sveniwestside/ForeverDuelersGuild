(() => {
  const root = document.documentElement;
  const storageKey = 'fdg-theme';
  const system = window.matchMedia('(prefers-color-scheme: dark)');
  const validTheme = value => value === 'dark' || value === 'light' ? value : null;
  let preference = null;
  try { preference = validTheme(localStorage.getItem(storageKey)); } catch {}

  function applyTheme(theme) {
    root.dataset.theme = theme;
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = theme === 'dark' ? '#131b17' : '#202824';
    const button = document.getElementById('theme-toggle');
    if (button) {
      button.setAttribute('aria-pressed', String(theme === 'dark'));
      button.title = `Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`;
    }
  }

  // This head script applies the preference before the stylesheet is loaded.
  applyTheme(preference ?? (system.matches ? 'dark' : 'light'));
  document.addEventListener('DOMContentLoaded', () => {
    const button = document.getElementById('theme-toggle');
    if (!button) return;
    applyTheme(root.dataset.theme);
    button.addEventListener('click', () => {
      preference = root.dataset.theme === 'dark' ? 'light' : 'dark';
      applyTheme(preference);
      try { localStorage.setItem(storageKey, preference); } catch {}
    });
  });
  system.addEventListener('change', event => {
    if (preference === null) applyTheme(event.matches ? 'dark' : 'light');
  });
  window.addEventListener('storage', event => {
    if (event.key !== storageKey && event.key !== null) return;
    try { preference = validTheme(localStorage.getItem(storageKey)); } catch { return; }
    applyTheme(preference ?? (system.matches ? 'dark' : 'light'));
  });
})();
