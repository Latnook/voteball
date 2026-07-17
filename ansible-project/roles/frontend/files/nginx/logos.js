// Shared logo rendering: real logo_url image with a deterministic monogram fallback for
// entities that have none set yet, or whose URL fails to load. Every league/club/party from
// /api/options can be passed straight in — id is used to seed a stable color per entity.

function hashStringToHue(str) {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = (hash * 31 + str.charCodeAt(i)) >>> 0;
  }
  return hash % 360;
}

function initialsFromName(name) {
  const words = (name || '').trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return '?';
  if (words.length === 1) return words[0].slice(0, 3).toUpperCase();
  return (words[0][0] + words[1][0]).toUpperCase();
}

function buildMonogram(entityId, displayName) {
  const mono = document.createElement('div');
  mono.className = 'logo-mono';
  mono.style.setProperty('--mono-hue', String(hashStringToHue(String(entityId) + displayName)));
  mono.textContent = initialsFromName(displayName);
  return mono;
}

// Clubs/leagues (by name_en) that get a thin white outline in dark mode (see .logo-dark in
// style.css) so they read on the dark cards. This is a hand-picked list, not a luminance rule --
// the user's choices don't follow brightness (Paderborn is bright yet wants one; Nott'm Forest is
// darker yet doesn't), so which crests get an outline is a per-club visual call. Parties are handled
// separately by the recolour below and are never in here. Add clubs here as they're requested.
const OUTLINE_CLUBS = new Set([
  'Juventus',
  'Tottenham Hotspur',
  'Maccabi Petah Tikva',
  'SC Paderborn 07',
  'Hapoel Akko',
  "Ironi Modi'in",
  'Hapoel Petah Tikva',
  'UEFA Champions League',
]);

// --- HSL conversion (used by the party-logo dark-mode recolour below) ---
function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  let h, s; const l = (max + min) / 2;
  if (max === min) {
    h = s = 0;
  } else {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    switch (max) {
      case r: h = (g - b) / d + (g < b ? 6 : 0); break;
      case g: h = (b - r) / d + 2; break;
      default: h = (r - g) / d + 4;
    }
    h /= 6;
  }
  return [h, s, l];
}

function hueToRgb(p, q, t) {
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  if (t < 1 / 6) return p + (q - p) * 6 * t;
  if (t < 1 / 2) return q;
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
  return p;
}

function hslToRgb(h, s, l) {
  let r, g, b;
  if (s === 0) {
    r = g = b = l;
  } else {
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const p = 2 * l - q;
    r = hueToRgb(p, q, h + 1 / 3);
    g = hueToRgb(p, q, h);
    b = hueToRgb(p, q, h - 1 / 3);
  }
  return [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)];
}

// Recolour a loaded (CORS-clean) party logo for dark backgrounds: lift every perceptually dark pixel
// to a light version of the same hue+saturation, so dark artwork and Hebrew wordmarks read on the
// dark cards (black -> white, dark navy -> light blue, dark green -> lighter green). The decision
// uses perceptual luminance, not HSL lightness, so it also catches saturated-but-dark colours like
// The Democrats' vivid blue (#2639e0), whose HSL lightness sits just above the midpoint. Warm vivid
// colours (saturated red/orange/yellow) read fine on the dark cards even when dark and are left
// alone (Otzma's red star, Balad's orange, Labor's red flag). Solid opaque-tile logos (Hadash-Ta'al's
// yellow block) carry their own contrast and are skipped. Returns a <canvas> if anything changed,
// else null. Parties only -- club crests/flags keep their real colours (they use the outline).
function recolorLogoForDark(img) {
  const MAX = 400;
  const scale = Math.min(1, MAX / Math.max(img.naturalWidth, img.naturalHeight));
  const w = Math.max(1, Math.round(img.naturalWidth * scale));
  const h = Math.max(1, Math.round(img.naturalHeight * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(img, 0, 0, w, h);
  const imageData = ctx.getImageData(0, 0, w, h);
  const d = imageData.data;

  let opaque = 0, total = 0;
  for (let i = 0; i < d.length; i += 4) {
    total++;
    if (d[i + 3] > 200) opaque++;
  }
  if (total === 0 || opaque / total > 0.9) return null; // solid-tile logo -- leave as-is

  let changed = false;
  for (let i = 0; i < d.length; i += 4) {
    if (d[i + 3] < 20) continue;
    const r = d[i], g = d[i + 1], b = d[i + 2];
    const hsl = rgbToHsl(r, g, b);
    const y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    const warmVivid = hsl[1] > 0.45 && (hsl[0] <= 0.15 || hsl[0] >= 0.95);
    if (y < 0.5 && !warmVivid) {
      const rgb = hslToRgb(hsl[0], hsl[1], Math.max(1 - y, 0.6));
      d[i] = rgb[0]; d[i + 1] = rgb[1]; d[i + 2] = rgb[2];
      changed = true;
    }
  }
  if (!changed) return null;
  ctx.putImageData(imageData, 0, 0);
  return canvas;
}

// entity: {id, logo_url} (any /api/options entity). displayName: the localized name to render
// as an image alt/monogram initials. Returns a <span class="logo"> ready to append.
function logoEl(entity, displayName, opts) {
  opts = opts || {};
  const wrap = document.createElement('span');
  wrap.className = opts.extraClass ? `logo ${opts.extraClass}` : 'logo';

  const url = entity && entity.logo_url;
  if (!url) {
    wrap.appendChild(buildMonogram(entity ? entity.id : displayName, displayName));
    return wrap;
  }

  // Clubs/leagues in the hand-picked outline set get their thin white outline immediately (no pixel
  // work, no CORS needed) -- see OUTLINE_CLUBS / .logo-dark.
  if (!opts.recolor && entity && OUTLINE_CLUBS.has(entity.name_en)) {
    wrap.classList.add('logo-dark');
  }

  if (opts.recolor) {
    // Party logos: load with crossOrigin so we can read the pixels and build a dark-mode-recoloured
    // canvas. CSS shows that canvas in the dark theme and the untouched original <img> in light (see
    // .logo-recolored / .logo-orig). A host without CORS headers makes this attempt error (it does
    // not taint), so on error we retry once without crossOrigin -- keeping the logo (no recolour
    // possible) and only falling back to a monogram if that plain load also fails.
    const img = document.createElement('img');
    img.alt = '';
    img.loading = 'lazy';
    img.crossOrigin = 'anonymous';
    img.addEventListener('load', () => {
      try {
        const canvas = recolorLogoForDark(img);
        if (canvas) {
          canvas.className = 'logo-recolored';
          img.classList.add('logo-orig');
          wrap.appendChild(canvas);
        }
      } catch (e) {
        /* tainted canvas / read error -- leave the original logo untouched */
      }
    }, { once: true });
    img.addEventListener('error', () => {
      const plain = document.createElement('img');
      plain.alt = '';
      plain.loading = 'lazy';
      plain.addEventListener('error', () => {
        wrap.innerHTML = '';
        wrap.appendChild(buildMonogram(entity.id, displayName));
      }, { once: true });
      plain.src = url;
      wrap.innerHTML = '';
      wrap.appendChild(plain);
    }, { once: true });
    img.src = url;
    wrap.appendChild(img);
    return wrap;
  }

  // Clubs/leagues/flags: a plain image load (no CORS needed), monogram fallback on failure.
  const img = document.createElement('img');
  img.alt = '';
  img.loading = 'lazy';
  img.addEventListener('error', () => {
    wrap.innerHTML = '';
    wrap.appendChild(buildMonogram(entity.id, displayName));
  }, { once: true });
  img.src = url;
  wrap.appendChild(img);

  return wrap;
}
