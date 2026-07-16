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

// entity: {id, logo_url} (any /api/options entity). displayName: the localized name to render
// as an image alt/monogram initials. Returns a <span class="logo"> ready to append.
function logoEl(entity, displayName, opts) {
  opts = opts || {};
  const wrap = document.createElement('span');
  wrap.className = opts.extraClass ? `logo ${opts.extraClass}` : 'logo';

  const url = entity && entity.logo_url;
  if (url) {
    const img = document.createElement('img');
    img.src = url;
    img.alt = '';
    img.loading = 'lazy';
    img.addEventListener('error', () => {
      wrap.innerHTML = '';
      wrap.appendChild(buildMonogram(entity.id, displayName));
    }, { once: true });
    wrap.appendChild(img);
  } else {
    wrap.appendChild(buildMonogram(entity ? entity.id : displayName, displayName));
  }

  return wrap;
}
