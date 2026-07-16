const THEME_STORAGE_KEY = 'voteballTheme';

function detectInitialTheme() {
  const stored = localStorage.getItem(THEME_STORAGE_KEY);
  if (stored === 'light' || stored === 'dark') return stored;
  return window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
}

let currentTheme = detectInitialTheme();

function applyDocumentTheme() {
  document.documentElement.setAttribute('data-theme', currentTheme);
}

function getTheme() {
  return currentTheme;
}

function updateThemeToggleButton() {
  const btn = document.getElementById('theme-toggle');
  if (!btn) return;
  btn.setAttribute('aria-pressed', String(currentTheme === 'light'));
  btn.textContent = currentTheme === 'dark' ? '☀️' : '🌙';
  btn.setAttribute('aria-label', currentTheme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode');
}

function setTheme(theme) {
  if (theme !== 'light' && theme !== 'dark') return;
  currentTheme = theme;
  localStorage.setItem(THEME_STORAGE_KEY, theme);
  applyDocumentTheme();
  updateThemeToggleButton();
}

function toggleTheme() {
  setTheme(currentTheme === 'dark' ? 'light' : 'dark');
}

function initThemeToggle() {
  const btn = document.getElementById('theme-toggle');
  if (!btn) return;
  btn.addEventListener('click', toggleTheme);
  updateThemeToggleButton();
}

// Runs immediately, in <head>, before <body> is parsed — sets data-theme before first paint,
// mirroring i18n.js's applyDocumentDirection() pattern for dir.
applyDocumentTheme();

document.addEventListener('DOMContentLoaded', initThemeToggle);
