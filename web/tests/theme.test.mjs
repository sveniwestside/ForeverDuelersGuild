import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../public/theme.js', import.meta.url), 'utf8');
function page({ saved = null, dark = false, blocked = false } = {}) {
  const callbacks = {}, attributes = {}, root = { dataset: {} }, meta = {};
  const button = { setAttribute: (key, value) => { attributes[key] = value; },
    addEventListener: (name, callback) => { callbacks[`button:${name}`] = callback; } };
  const system = { matches: dark, addEventListener: (name, callback) => { callbacks[`system:${name}`] = callback; } };
  const document = { documentElement: root, querySelector: () => meta, getElementById: () => button,
    addEventListener: (name, callback) => { callbacks[`document:${name}`] = callback; } };
  const storage = { getItem: () => { if (blocked) throw new Error('Unavailable'); return saved; },
    setItem: (_key, value) => { if (blocked) throw new Error('Unavailable'); saved = value; } };
  vm.runInNewContext(source, { document, localStorage: storage,
    window: { matchMedia: () => system, addEventListener: (name, callback) => { callbacks[`window:${name}`] = callback; } } });
  return { root, meta, button, attributes, callbacks, saved: () => saved,
    setSaved: value => { saved = value; }, system };
}

test('theme follows the system initially and applies accessible state before CSS', () => {
  for (const dark of [false, true]) {
    const p = page({ dark });
    assert.equal(p.root.dataset.theme, dark ? 'dark' : 'light');
    assert.equal(p.attributes['aria-pressed'], String(dark));
    assert.match(p.button.title, dark ? /light/ : /dark/);
    p.callbacks['document:DOMContentLoaded']();
    p.callbacks['system:change']({ matches: !dark });
    assert.equal(p.root.dataset.theme, dark ? 'light' : 'dark');
  }
});

test('an explicit toggle survives reload and takes precedence over system changes', () => {
  const p = page({ dark: false });
  p.callbacks['document:DOMContentLoaded']();
  p.callbacks['button:click']();
  assert.equal(p.saved(), 'dark');
  p.callbacks['system:change']({ matches: false });
  assert.equal(p.root.dataset.theme, 'dark');
  assert.equal(page({ saved: p.saved(), dark: false }).root.dataset.theme, 'dark');
  p.callbacks['button:click']();
  assert.equal(p.saved(), 'light');
  assert.equal(p.attributes['aria-pressed'], 'false');
});

test('theme toggle works with unavailable storage and invalid preferences', () => {
  assert.equal(page({ saved: 'invalid', dark: true }).root.dataset.theme, 'dark');
  const p = page({ dark: false, blocked: true });
  p.callbacks['document:DOMContentLoaded']();
  assert.doesNotThrow(() => p.callbacks['button:click']());
  assert.equal(p.root.dataset.theme, 'dark');
  assert.doesNotThrow(() => p.callbacks['window:storage']({ key: 'fdg-theme' }));
});

test('cross-tab preference changes and removal resynchronize the theme', () => {
  const p = page({ saved: 'light', dark: true });
  p.setSaved('dark');
  p.callbacks['window:storage']({ key: 'fdg-theme' });
  assert.equal(p.root.dataset.theme, 'dark');
  p.setSaved('light');
  p.callbacks['window:storage']({ key: 'unrelated' });
  assert.equal(p.root.dataset.theme, 'dark');
  p.callbacks['window:storage']({ key: null });
  assert.equal(p.root.dataset.theme, 'light');
  p.setSaved(null);
  p.callbacks['window:storage']({ key: 'fdg-theme' });
  assert.equal(p.root.dataset.theme, 'dark');
});
