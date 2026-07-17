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

// Alpha-weighted mean luminance (0=black .. 1=white) of a loaded image's opaque pixels, sampled on
// a small offscreen canvas. Requires the image to be CORS-clean (crossOrigin set + host sends an
// Access-Control-Allow-Origin header), otherwise getImageData throws on the tainted canvas.
function logoLuminance(img) {
  const S = 40;
  const canvas = document.createElement('canvas');
  canvas.width = S;
  canvas.height = S;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  const r = Math.min(S / img.naturalWidth, S / img.naturalHeight);
  const w = img.naturalWidth * r, h = img.naturalHeight * r;
  ctx.drawImage(img, (S - w) / 2, (S - h) / 2, w, h);
  const d = ctx.getImageData(0, 0, S, S).data;
  let lumSum = 0, alphaSum = 0;
  for (let i = 0; i < d.length; i += 4) {
    const a = d[i + 3] / 255;
    if (a < 0.1) continue;
    lumSum += (0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2]) / 255 * a;
    alphaSum += a;
  }
  return alphaSum ? lumSum / alphaSum : 1;
}

// Below this mean luminance a logo is "dark" and gets a white outline (see .logo-dark in style.css)
// so it stays legible on the dark theme's dark cards. Calibrated 2026-07-17 against the real logos:
// genuinely dark marks land ~0.0-0.37 (Juventus/Shas black, dark Hebrew wordmarks), colourful ones
// ~0.48+ (Balad, Yashar, club crests) -- 0.43 sits in the clean gap between the two clusters.
const DARK_LOGO_THRESHOLD = 0.43;

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

// Recolour a loaded (CORS-clean) party logo for dark backgrounds: lift only the pixels darker than
// mid-lightness to their lightness-inverse, preserving hue+saturation -- so dark artwork and Hebrew
// wordmarks (black -> white, dark navy -> light blue, dark green -> lighter green) read on the dark
// cards, while already-bright colours (Otzma's red star, Balad's orange) are left untouched. Logos
// that are a solid opaque tile (e.g. Hadash-Ta'al's yellow block) carry their own contrast, so they
// are skipped. Returns a <canvas> if anything changed, else null. Scoped to parties only (club
// crests and national flags must keep their real colours -- they use the .logo-dark outline instead).
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
    const hsl = rgbToHsl(d[i], d[i + 1], d[i + 2]);
    if (hsl[2] < 0.5) {
      const rgb = hslToRgb(hsl[0], hsl[1], 1 - hsl[2]);
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

  // First attempt loads with crossOrigin so we can sample the logo's luminance once it's decoded and
  // flag dark ones for the outline. A host without CORS headers makes this attempt error (it does
  // not taint), so on error we retry once without crossOrigin -- keeping the logo (no luminance
  // check possible) and only falling back to a monogram if that plain load also fails.
  const img = document.createElement('img');
  img.alt = '';
  img.loading = 'lazy';
  img.crossOrigin = 'anonymous';
  img.addEventListener('load', () => {
    try {
      if (opts.recolor) {
        // Party logos: build a dark-mode-recoloured canvas. CSS shows the canvas in the dark theme
        // and the untouched original <img> in light (see .logo-recolored / .logo-orig in style.css).
        const canvas = recolorLogoForDark(img);
        if (canvas) {
          canvas.className = 'logo-recolored';
          img.classList.add('logo-orig');
          wrap.appendChild(canvas);
        }
      } else if (logoLuminance(img) < DARK_LOGO_THRESHOLD) {
        // Clubs/leagues/flags: a thin white outline for dark ones (keeps their real colours).
        wrap.classList.add('logo-dark');
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
