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
  'Maccabi Bnei Reineh',
  // (The UEFA Champions League used to be here. It now ships a white starball for dark mode instead
  // -- see DARK_VARIANT_LOGOS below. Leaving it here as well would trace a white outline around
  // already-white artwork.)
  // World Cup 2026 national-team crests. The flags these replaced were uniformly bright; federation
  // badges are not, and these three are dark artwork on transparency -- Cape Verde's navy shield,
  // Mexico's dark green eagle, and South Korea's "KOREA" wordmark, which is a dark blue that
  // disappears into the card entirely.
  'Cape Verde',
  'Mexico',
  'South Korea',
  // Sparta Prague's crest is a black disc on transparency: without the outline the disc vanishes
  // into the card and only the white S and the three gold stars float there. Its Europa League
  // neighbours Stade Rennais and Sturm Graz are deliberately NOT here -- a gold shield border and a
  // white ring respectively already separate them from the card, so an outline only thickens them.
  'Sparta Prague',
  // Lugano is the same shape: a black disc on transparency carrying a white LFC monogram. Measured
  // against the dark card (#161B22) the disc is 1.2:1 -- effectively invisible -- so without the
  // outline the monogram floats with nothing behind it. Its Conference League neighbours are
  // deliberately NOT here: KuPS's black shield carries a yellow border that already separates it
  // (the same reason Stade Rennais is excluded), and Iberia 1999's crimson eagle measures 2.75:1,
  // dim but plainly a shape.
  'Lugano',
  // The 2026-08-28 Europa/Conference League intake, measured against the dark card (#161B22) rather
  // than eyeballed. Each of these four is a dark CONTAINER holding a legible mark -- a disc, an oval
  // or a shield -- so the outline restores the boundary the card swallowed and the mark inside was
  // never the problem: OFI a black disc under white rings (1.21:1), Lillestrøm a black disc under a
  // yellow LSK lens (1.12:1), Trabzonspor a #5a0e27 shield (1.26:1), Mjällby a black oval inside a
  // yellow wreath (1.13:1). The other 31 crests in that intake measured 2.1:1 or better and are
  // deliberately absent -- Copenhagen at 2.30 and Riga at 2.13 are the closest, both dim but plainly
  // shapes, the same call that keeps Iberia 1999 out.
  'OFI',
  'Lillestrøm SK',
  'Trabzonspor',
  'Mjällby',
]);

// Clubs/leagues (by name_en) that ship a SECOND artwork file for the dark theme, rather than being
// derived from the light one. The light file is what logo_url points at; the value here is the dark
// one. Both render, and the same four CSS rules that switch the party canvases pick which is visible
// (.logo-orig in light, .logo-recolored in dark), so this needs no theme logic of its own and
// follows the manual toggle as well as the OS preference.
//
// This exists for artwork where neither existing treatment works. The Europa League mark is a large
// solid black trophy: OUTLINE_CLUBS traces a silhouette without lifting it, so the trophy would stay
// black; and the canvas recolour -- which would produce roughly the right result -- derives the dark
// version at runtime, so it can't be reviewed by looking at a file and drags in crossOrigin, pixel
// reads and the tainted-canvas fallback for what is a two-colour flat asset. A hand-made file is
// both cheaper and inspectable. See docs/design/2026-08-12-europa-league-design.md decision 5.
const DARK_VARIANT_LOGOS = new Map([
  ['UEFA Europa League', '/logos/uefa-europa-league-dark.svg'],
  // The starball is one navy silhouette, so the outline treatment it used to get traced its edge
  // without lifting it -- the same reason the Europa League trophy needed a real second file.
  ['UEFA Champions League', '/logos/uefa-champions-league-dark.svg'],
  // UEFA ships the Conference League mark as two files of its own -- a black trophy for light
  // backgrounds and a white one for dark, both with the same #00BE14 brackets. They are used as
  // downloaded except for the trademark glyph, which was a separate <path> and is dropped, and a
  // viewBox cropped to the artwork's measured bounding box so it fills the logo box like its
  // neighbours instead of rendering small inside its own padding.
  ['UEFA Conference League', '/logos/uefa-conference-league-dark.svg'],
  // A CLUB rather than a competition, and the first one here. Ararat-Armenia's crest is dark line
  // art -- a #231f20 ring and mountains over a white field, above a solid "ARARAT ARMENIA"
  // wordmark. The roundel survives the dark card on its own but the wordmark does not, and an
  // OUTLINE_CLUBS halo cannot lift it for the reason the Europa League trophy needed a real file:
  // outlining a solid mass traces its edge and leaves the middle dark. The file here is the
  // upstream artwork with its two flat colours swapped, so it stays inspectable as a file.
  ['Ararat-Armenia', '/logos/fc-ararat-armenia-dark.svg'],
  // Jablonec is the one crest in the 2026-08-28 intake an outline could not have saved, and the
  // colour census is what says so rather than how it looks: all seven of its paths are #01311F and
  // nothing else. There is no container to bound -- the dark IS the mark -- which is the same test
  // that separated Ararat-Armenia's wordmark from Lugano's disc. Single flat colour, so the dark
  // file is that one fill swapped to white and stays reviewable as a file.
  ['Jablonec', '/logos/fk-jablonec-dark.svg'],
]);

// Entities (by name_en) whose artwork file carries transparent padding, and the factor that
// cancels it out. Clubs, leagues and parties alike -- padding is a property of the FILE, so it is
// independent of which of the other sets above an entity does or does not belong to. Every logo
// renders object-fit: contain inside a fixed 3.4rem box, so a file that pads itself renders a
// visibly smaller crest than its neighbours -- the box is identical, the file is the variable.
//
// The factor is a MEASUREMENT, not a taste setting: it is 1 / (fraction of the file's own canvas the
// artwork actually spans), so the crest ends up filling the box like an unpadded one. Measure it,
// don't estimate it -- rasterize the file and take the alpha bounding box:
//
//   rsvg-convert -w 256 -h 256 -a -b none crest.svg -o /tmp/c.png
//   python3 -c "from PIL import Image; im=Image.open('/tmp/c.png'); b=im.split()[3].getbbox(); \
//               print(max(b[2]-b[0], b[3]-b[1]) / 256)"
//
// Brighton's crest spans 0.715 of its 2084x2084 canvas (alpha bbox 300,310 -> 1783,1774) while every
// other Premier League crest spans 1.000, which is the whole reason it looked small. The file is a
// PNG wrapped in <svg><image>, so the padding is baked into the raster and no viewBox change to the
// upstream URL can reach it; scaling at render time is the cheapest fix that keeps Wikimedia as the
// source of truth. If a padded crest is ever self-hosted pre-cropped instead, remove its entry here
// or the two corrections multiply.
const PADDED_CRESTS = new Map([
  ['Brighton & Hove Albion', 1.4],
  // The first PARTY here, and the reason the factor has to be measured rather than eyeballed: every
  // other party wordmark in the grid spans 1.000 of its own canvas (Shas 0.984 and El HaDegel 0.937
  // are the only ones under it), so ביחד's file at 0.906 wide x 0.781 tall would have been the one
  // logo rendering visibly smaller than all fourteen of its neighbours. .logo-wide is far wider than
  // it is tall and this wordmark is wider still (3.11:1 file, 3.61:1 artwork), so object-fit fits it
  // by WIDTH -- which is why the horizontal span is the one that decides the factor here and the
  // vertical padding rides along. Same formula as Brighton's, same way of measuring it.
  ['Together', 1.1],
]);

// Parties (by name_en) whose artwork is dark ink on a TRANSPARENT interior, which the recolour below
// cannot handle: it lifts the ink to white, and every enclosed gap -- the counter inside Shas's ס,
// the slits between the three strokes of its ש -- then shows the dark card through it, reading as
// black specks punched into white letters. No colour operation can fix that, because the interior
// and those gaps are the same colour in the file (both fully transparent), so invert, negative and
// recolour all map them to the same output. They differ only by which side of the outline they sit
// on, which is why fillLogoInteriorForDark() below is a flood fill rather than a pixel rule.
// Keyed by name_en, so a party is covered in both previous_parties and upcoming_parties.
const FILL_INTERIOR_PARTIES = new Set([
  'Shas',
]);

// Parties whose wordmark is shown UNCHANGED on a near-white plate in dark mode, instead of being
// recoloured (logos.js draws it as .logo-recolored; .logo-plate in style.css paints the plate, and
// it rides the existing light/dark switch rather than adding a second pair of theme rules).
//
// This is for artwork the canvas recolour cannot render cleanly ON A REAL BROWSER. The 2019 Joint
// List mark is a dense two-line Arabic/Hebrew wordmark: every ink pixel does lift to white, and the
// canvas this repo produces measures clean, but on the repo owner's browser the recoloured canvas
// comes back speckled with black dots through the glyph bodies -- a rasterisation artefact that
// headless Chromium does not reproduce, so it cannot be caught here. Two earlier attempts (a plain
// recolour, then a recolour composed with the Shas flood fill) both verified clean in automation and
// both still looked wrong on the actual site.
//
// The plate sidesteps the whole class of problem rather than tuning against it: no canvas, no
// getImageData, no crossOrigin, no per-logo pixel thresholds. The browser just renders the original
// SVG -- which is clean at any size -- on a light ground, so dark mode reproduces exactly what light
// mode already shows. Note this deliberately reopens the no-plate rule for parties (parties
// recolour, clubs get an outline): the repo owner chose it on 2026-08-20 after seeing all three
// options rendered, because no recolour-based option could be made to look right on their machine.
// Keyed by name_en like the sets above.
const PLATE_PARTIES = new Set([
  'The Joint List',
]);

// Parties whose artwork is used UNCHANGED in both themes -- the recolour is skipped entirely.
//
// This exists for logos built around a KNOCKOUT. בית ציוני's Star of David is not drawn: it is a
// hole in the swoosh that lets the background show through, so in the file the star's interior and
// the empty space outside the artwork are the same transparent pixels. That is the defect
// fillLogoInteriorForDark() documents for Shas above, and it has the same consequence here --
// recolouring lifts the swoosh but cannot lift a hole, so the dark card shows through the star as
// black triangles. A knockout can only be correct against the background it is actually drawn on,
// and it is: white shows through on the light card, the card colour on the dark one.
//
// So the artwork is left alone and its colours are chosen to clear WCAG's 3:1 graphical-object
// minimum on BOTH grounds -- the secondary elements use the brighter of the logo's own two blues
// (#418AB8: 4.57:1 on the dark card, 3.78:1 on white). The darker #326B9F reads better on white but
// falls to 3.08:1 on the dark card, which is the floor with nothing spare; the small
// בראשות טרופר והנדל line is what pays for that first. This was a visual call by the repo owner
// after seeing all three options rendered, not only a contrast calculation.
//
// Skipping the recolour is what makes dark match light. Without this the blues would be lifted and
// the two themes would drift apart again.
//
// Keyed by name_en so one entry covers a party in both previous_parties and upcoming_parties.
const SKIP_RECOLOR_PARTIES = new Set([
  'Zionist Home – The Reservists',
]);

// Near-white, close to the theme's --ink (#F5F7FA). This started at the dark theme's --muted
// (#8B95A3) to keep the filled tablet from outweighing the thin wordmarks on the neighbouring cards,
// but that reads as a grey slab once it's on a real card next to them -- the user's call after seeing
// it live, so the tablet is paper-white and simply is the brightest logo in the grid. Black lettering
// sits at 20:1 on it. Deliberately a literal rather than a read of the custom property: the canvas is
// built once when the image loads and CSS only ever displays it in the dark theme (see
// .logo-recolored in style.css), so reading the property on a page that loaded in LIGHT mode would
// bake the light value in -- which for a --muted-derived tone dropped the lettering to 3.6:1.
const INTERIOR_FILL_RGB = [250, 250, 250];

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

// Fill the enclosed transparent interior of a dark-ink logo (FILL_INTERIOR_PARTIES) with a muted
// light tone, leaving the ink itself untouched, so it reads on a dark card the way the original
// reads on paper. "Enclosed" is decided by reachability, not colour: flood the transparent pixels
// inward from all four canvas edges, and whatever transparency that flood could NOT reach is inside
// the artwork's outline. Returns a <canvas> if anything was filled, else null (nothing enclosed --
// e.g. an open-sided logo, which would otherwise be silently turned into a solid block).
function fillLogoInteriorForDark(img) {
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
  const isClear = (i) => d[i * 4 + 3] < 20;

  const outside = new Uint8Array(w * h);
  const stack = [];
  for (let x = 0; x < w; x++) { stack.push(x, (h - 1) * w + x); }
  for (let y = 0; y < h; y++) { stack.push(y * w, y * w + w - 1); }
  while (stack.length) {
    const i = stack.pop();
    if (outside[i] || !isClear(i)) continue;
    outside[i] = 1;
    const x = i % w;
    const y = (i - x) / w;
    if (x > 0) stack.push(i - 1);
    if (x < w - 1) stack.push(i + 1);
    if (y > 0) stack.push(i - w);
    if (y < h - 1) stack.push(i + w);
  }

  let filled = 0;
  for (let i = 0; i < w * h; i++) {
    if (!isClear(i) || outside[i]) continue;
    d[i * 4] = INTERIOR_FILL_RGB[0];
    d[i * 4 + 1] = INTERIOR_FILL_RGB[1];
    d[i * 4 + 2] = INTERIOR_FILL_RGB[2];
    d[i * 4 + 3] = 255;
    filled++;
  }
  if (!filled) return null;
  ctx.putImageData(imageData, 0, 0);
  return canvas;
}

// Recoloured party artwork, keyed by treatment + URL. Both operations above are pure functions of
// the source pixels, so the same artwork always yields the same canvas -- but they were being redone
// from scratch on every re-render, and only AFTER each new <img> fired its load event. In dark mode
// that ordering is what shows: the un-recoloured artwork is dark ink on a dark card, so it paints
// first as a near-invisible smudge and then visibly flips to the light recoloured version. Every
// rebuild replayed that flip -- a results-page filter change, a language change, a league-tab switch.
//
// A cache hit applies the canvas synchronously, before the image loads at all, so a re-render shows
// the finished logo with no intermediate state. null is cached as well as a canvas: it means "this
// artwork needs no recolour" (a solid tile, or a flood fill that found nothing enclosed), which is
// just as worth not recomputing.
const RECOLOR_CACHE = new Map();

// A canvas element can only be in one place in the DOM, so each card gets its own copy of the cached
// one. drawImage is a straight bitmap blit -- not the per-pixel JS pass with an HSL round-trip that
// produced it in the first place.
function copyCanvas(src) {
  const canvas = document.createElement('canvas');
  canvas.width = src.width;
  canvas.height = src.height;
  canvas.getContext('2d').drawImage(src, 0, 0);
  return canvas;
}

// Shared by both recolour paths: a host without CORS headers makes the crossOrigin attempt error (it
// does not taint), so retry once without it -- keeping the logo (no recolour possible) and only
// falling back to a monogram if that plain load also fails.
function attachPlainImageFallback(img, wrap, entity, displayName, url) {
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

  // A crest that pads itself in the file gets scaled back up to its neighbours' size. Set as a
  // custom property rather than a per-club class so the measured factor lives in PADDED_CRESTS
  // (next to how it was measured) instead of being split across two files -- see .logo-padded.
  if (entity && PADDED_CRESTS.has(entity.name_en)) {
    wrap.classList.add('logo-padded');
    wrap.style.setProperty('--logo-scale', PADDED_CRESTS.get(entity.name_en));
  }

  // A hand-made dark-theme artwork file: append both images and let CSS choose. Deliberately no
  // canvas and no crossOrigin -- both files are same-origin static assets, so there is nothing to
  // taint and nothing to compute. Each carries its own error handler, so a missing file falls back
  // to the monogram exactly like a single image would.
  if (!opts.recolor && entity && DARK_VARIANT_LOGOS.has(entity.name_en)) {
    const light = document.createElement('img');
    light.alt = '';
    light.loading = 'lazy';
    light.className = 'logo-orig';
    light.addEventListener('error', () => {
      wrap.innerHTML = '';
      wrap.appendChild(buildMonogram(entity.id, displayName));
    }, { once: true });
    light.src = url;

    const dark = document.createElement('img');
    dark.alt = '';
    dark.loading = 'lazy';
    dark.className = 'logo-recolored';
    dark.addEventListener('error', () => {
      wrap.innerHTML = '';
      wrap.appendChild(buildMonogram(entity.id, displayName));
    }, { once: true });
    dark.src = DARK_VARIANT_LOGOS.get(entity.name_en);

    wrap.appendChild(light);
    wrap.appendChild(dark);
    return wrap;
  }

  // SKIP_RECOLOR_PARTIES: a plain image shown in both themes. It deliberately does NOT get the
  // .logo-orig class -- that class is what the dark theme hides, so leaving it off is precisely what
  // makes the same artwork render in both. No canvas also means no crossOrigin and no pixel reads,
  // so this path cannot be defeated by a tainted canvas.
  // PLATE_PARTIES: the untouched artwork twice -- once bare for light, once inside a .logo-plate
  // span for dark. Both carry the classes the existing theme switch already keys on, so no new
  // theme rule is needed and the manual toggle and prefers-color-scheme cannot drift apart. No
  // canvas on either path, which is the entire point (see PLATE_PARTIES above).
  if (opts.recolor && entity && PLATE_PARTIES.has(entity.name_en)) {
    const light = document.createElement('img');
    light.alt = '';
    light.loading = 'lazy';
    light.className = 'logo-orig';
    light.addEventListener('error', () => {
      wrap.innerHTML = '';
      wrap.appendChild(buildMonogram(entity.id, displayName));
    }, { once: true });
    light.src = url;

    const plate = document.createElement('span');
    plate.className = 'logo-recolored logo-plate';
    const dark = document.createElement('img');
    dark.alt = '';
    dark.loading = 'lazy';
    dark.addEventListener('error', () => {
      wrap.innerHTML = '';
      wrap.appendChild(buildMonogram(entity.id, displayName));
    }, { once: true });
    dark.src = url;
    plate.appendChild(dark);

    wrap.appendChild(light);
    wrap.appendChild(plate);
    return wrap;
  }

  if (opts.recolor && entity && SKIP_RECOLOR_PARTIES.has(entity.name_en)) {
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

  if (opts.recolor) {
    // Party logos: load with crossOrigin so we can read the pixels and build a dark-mode-recoloured
    // canvas. CSS shows that canvas in the dark theme and the untouched original <img> in light (see
    // .logo-recolored / .logo-orig).
    const mode = FILL_INTERIOR_PARTIES.has(entity && entity.name_en) ? 'fill' : 'recolor';
    const cacheKey = `${mode}|${url}`;

    const img = document.createElement('img');
    img.alt = '';
    img.loading = 'lazy';
    img.crossOrigin = 'anonymous';
    attachPlainImageFallback(img, wrap, entity, displayName, url);

    // Already computed for this artwork -- apply it now rather than waiting on this element's load
    // event, which is the wait that let the un-recoloured logo paint first (see RECOLOR_CACHE).
    if (RECOLOR_CACHE.has(cacheKey)) {
      const cached = RECOLOR_CACHE.get(cacheKey);
      if (cached) img.classList.add('logo-orig');
      img.src = url;
      wrap.appendChild(img);
      if (cached) {
        const canvas = copyCanvas(cached);
        canvas.className = 'logo-recolored';
        wrap.appendChild(canvas);
      }
      return wrap;
    }

    img.addEventListener('load', () => {
      try {
        const canvas = mode === 'fill' ? fillLogoInteriorForDark(img) : recolorLogoForDark(img);
        // Cached even when null -- "needs no recolour" is a result worth keeping too.
        RECOLOR_CACHE.set(cacheKey, canvas);
        if (canvas) {
          canvas.className = 'logo-recolored';
          img.classList.add('logo-orig');
          wrap.appendChild(canvas);
        }
      } catch (e) {
        /* tainted canvas / read error -- leave the original logo untouched, and don't cache it:
           a taint is a property of this load, not of the artwork. */
      }
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
