const { t, locale } = spotcat.i18n;
const $ = (id) => document.getElementById(id);
const listEl = $('list'), searchEl = $('search'), preview = $('preview');
let sourceItems = [], items = [], selectedId = null;
let viewMode = 'cards', filter = 'all', previewOpen = false, recording = true;
let detailToken = 0, loadToken = 0, ready = false;
const thumbs = new Map(), thumbnailRequests = new Map();
const selected = () => items.find((item) => item.id === selectedId) || null;
const fileName = (path) => path.split('/').filter(Boolean).pop() || path;
const element = (tag, className, text) => {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text != null) el.textContent = text;
  return el;
};
function kindOf(item) {
  return item.type === 'text' && /^https?:\/\/\S+$/i.test((item.preview || '').trim()) ? 'link' : item.type;
}
function formatTime(ts) {
  const diff = Math.max(0, Date.now() - ts);
  if (diff < 60_000) return t('justNow');
  if (diff < 3_600_000) return t('minutesAgo', { n: Math.floor(diff / 60_000) });
  const date = new Date(ts);
  return date.toDateString() === new Date().toDateString()
    ? date.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' })
    : date.toLocaleDateString(locale, { month: 'short', day: 'numeric' });
}
function titleOf(item) {
  if (item.type === 'image') return item.size ? `${t('image')} ${item.size[0]}×${item.size[1]}` : t('image');
  if (item.type === 'files') return item.files?.length === 1 ? fileName(item.files[0]) : t('files', { n: item.files?.length || 0 });
  return (item.preview || '').replace(/\s+/g, ' ').trim();
}
function emptyMessage() {
  return searchEl.value.trim() || filter !== 'all' ? t('noResults') : t('empty');
}
async function load() {
  const token = ++loadToken;
  try {
    // Filter after search, before rendering; include the full normal history cap, not only the first 300 items.
    const result = await spotcat.clipboard.list({ query: searchEl.value, limit: 10000 });
    if (token !== loadToken) return;
    sourceItems = result || [];
    applyFilter();
  } catch (_) {
    if (token === loadToken) toast(t('loadError'));
  }
}
function applyFilter() {
  items = sourceItems.filter((item) => filter === 'all' || (filter === 'pinned' ? item.pinned : kindOf(item) === filter));
  if (!items.some((item) => item.id === selectedId)) selectedId = items[0]?.id ?? null;
  render();
}
async function setView(mode, persist = true) {
  viewMode = mode === 'list' ? 'list' : 'cards';
  previewOpen = false;
  document.body.dataset.view = viewMode;
  document.body.classList.remove('preview-open');
  $('view-cards').setAttribute('aria-pressed', String(viewMode === 'cards'));
  $('view-list').setAttribute('aria-pressed', String(viewMode === 'list'));
  $('hint').textContent = t(viewMode === 'cards' ? 'cardsHint' : 'hint');
  render();
  // A failed preference write must not prevent the active window from changing layout.
  try { await spotcat.clipboard.setView?.(viewMode); } catch (_) { toast(t('layoutError')); }
  if (persist) {
    try { await spotcat.storage.set('viewMode', viewMode); } catch (_) { toast(t('saveError')); }
  }
}

// Only request thumbnails close to the viewport. Clipboard contents are always rendered as text, never HTML.
const imageObserver = new IntersectionObserver((entries) => {
  for (const entry of entries) if (entry.isIntersecting) {
    imageObserver.unobserve(entry.target);
    fillThumbnail(entry.target);
  }
}, { root: listEl, rootMargin: '240px' });
async function fillThumbnail(target) {
  const id = target.dataset.imageId, size = viewMode === 'cards' ? 768 : 96;
  const key = `${id}:${size}`;
  try {
    let url = thumbs.get(key);
    if (!url) {
      let request = thumbnailRequests.get(key);
      if (!request) {
        request = spotcat.clipboard.thumbnail(id, size);
        thumbnailRequests.set(key, request);
      }
      try { url = await request; } finally { thumbnailRequests.delete(key); }
      if (url) {
        thumbs.set(key, url);
        if (thumbs.size > 64) thumbs.delete(thumbs.keys().next().value);
      }
    }
    if (url && /^data:image\//.test(url) && target.isConnected) {
      const img = element('img');
      img.src = url;
      img.alt = t('image');
      img.draggable = false;
      target.replaceChildren(img);
    }
  } catch (_) { /* Keep the image placeholder if its entry disappeared. */ }
}
// Actions always capture the card ID, never whichever card happens to be selected.
function cardAction(item, action) {
  const button = element('button', `card-action card-${action}`);
  button.type = 'button';
  button.dataset.action = action;
  const label = t(action === 'paste' ? 'send' : 'copy');
  button.title = t(action === 'paste' ? 'sendHint' : 'copyHint');
  button.setAttribute('aria-label', label);
  const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  icon.setAttribute('viewBox', '0 0 24 24');
  icon.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', action === 'paste'
    ? 'M9 5 3 11l6 6M3 11h12a5 5 0 0 0 5-5V4'
    : 'M9 9h11v12H9zM15 9V3H4v12h5');
  icon.append(path);
  button.append(icon, element('span', '', label));
  button.addEventListener('click', (event) => {
    event.stopPropagation();
    // The second click of a double-click must not repeat an action or paste via the card.
    if (event.detail > 1) return;
    perform(() => action === 'paste' ? paste(item.id) : copy(item.id, { keepOpen: true }));
  });
  button.addEventListener('dblclick', (event) => { event.preventDefault(); event.stopPropagation(); });
  return button;
}
function makeCard(item, index) {
  const kind = kindOf(item), li = element('li', item.id === selectedId ? 'selected' : '');
  li.dataset.id = item.id;
  li.dataset.kind = kind;
  li.id = `entry-${index}`;
  li.setAttribute('role', 'option');
  li.setAttribute('aria-selected', String(item.id === selectedId));
  li.setAttribute('aria-label', [titleOf(item), item.app, item.pinned ? t('pinnedOnly') : ''].filter(Boolean).join(', '));
  const header = element('div', 'card-head');
  header.append(element('span', 'type-symbol', { text: 'T', link: '↗', image: '▧', files: '▱' }[kind]));
  const heading = element('div', 'card-heading');
  heading.append(element('span', 'kind-label', t(kind === 'files' ? 'fileType' : kind)), element('span', 'time', formatTime(item.time)));
  const source = element('span', 'source', item.app || t('unknownApp'));
  source.title = source.textContent;
  header.append(heading, source);
  if (item.pinned) {
    const pin = element('span', 'pin-mark', '●');
    pin.title = t('pinnedOnly');
    header.append(pin);
  }
  const content = element('div', 'card-content');
  if (item.type === 'image') {
    const image = element('div', 'thumbnail', '▧');
    image.dataset.imageId = item.id;
    content.append(image);
  } else if (item.type === 'files') {
    const files = element('div', 'file-names');
    for (const path of (item.files || []).slice(0, 4)) files.append(element('div', 'file-name', '▱  ' + fileName(path)));
    content.append(files);
  } else {
    if (kind === 'link') {
      let host = '';
      try { host = new URL(item.preview.trim()).hostname; } catch (_) { /* Truncated URL. */ }
      content.append(element('div', 'link-host', host));
    }
    content.append(element('div', 'text-content', item.preview || ''));
  }
  const body = element('div', 'list-body');
  body.append(element('div', 'title', (item.pinned ? '● ' : '') + titleOf(item)));
  body.append(element('div', 'sub', [item.app, formatTime(item.time)].filter(Boolean).join(' · ')));
  const stats = element('div', 'card-stats');
  const key = element('span', 'key', index < 9 ? `⌘${index + 1}` : `${index + 1}`);
  const summary = item.type === 'text' ? t('chars', { n: item.length || 0 })
    : item.type === 'image' && item.size ? `${item.size[0]}×${item.size[1]}` : titleOf(item);
  const info = element('span', 'card-summary', summary);
  info.title = summary;
  const actions = element('div', 'card-actions');
  actions.setAttribute('role', 'group');
  actions.setAttribute('aria-label', t('cardActions'));
  actions.append(cardAction(item, 'paste'), cardAction(item, 'copy'));
  stats.append(key, info, actions);
  li.append(header, content, body, stats);
  li.addEventListener('click', () => { select(item.id); listEl.focus({ preventScroll: true }); });
  li.addEventListener('dblclick', () => perform(() => paste(item.id)));
  return li;
}
function render() {
  imageObserver.disconnect();
  listEl.replaceChildren(...items.map(makeCard));
  if (!items.length) {
    const empty = element('li', 'list-empty', emptyMessage());
    empty.setAttribute('role', 'presentation');
    listEl.append(empty);
  }
  listEl.querySelectorAll('[data-image-id]').forEach((el) => imageObserver.observe(el));
  updateSelection();
  $('count').textContent = t('itemCount', { n: items.length });
  $('status').textContent = recording ? '' : t('notRecording');
  renderDetail();
}
function updateSelection() {
  let active = null;
  listEl.querySelectorAll('[data-id]').forEach((li) => {
    const isSelected = li.dataset.id === selectedId;
    li.classList.toggle('selected', isSelected);
    li.setAttribute('aria-selected', String(isSelected));
    if (isSelected) active = li;
  });
  if (active) {
    listEl.setAttribute('aria-activedescendant', active.id);
    active.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  } else listEl.removeAttribute('aria-activedescendant');
}
function select(id) {
  if (id === selectedId) return;
  selectedId = id;
  updateSelection();
  renderDetail();
}
function move(step) {
  if (!items.length) return;
  const index = items.findIndex((item) => item.id === selectedId);
  select(items[Math.min(items.length - 1, Math.max(0, index + step))].id);
}
function togglePreview(open = !previewOpen) {
  previewOpen = open;
  document.body.classList.toggle('preview-open', open);
  renderDetail();
}
async function renderDetail() {
  const token = ++detailToken, item = selected();
  document.body.classList.toggle('no-item', !item);
  $('empty').textContent = emptyMessage();
  $('pin').textContent = item?.pinned ? t('unpin') : t('pin');
  $('show-preview').setAttribute('aria-expanded', String(previewOpen));
  for (const id of ['pin', 'copy', 'delete', 'paste', 'show-preview']) $(id).disabled = !item;
  preview.replaceChildren();
  if (!item) return;
  $('meta').textContent = [formatTime(item.time), item.app && t('from', { app: item.app }), item.type === 'text' && t('chars', { n: item.length })].filter(Boolean).join(' · ');
  if (viewMode === 'cards' && !previewOpen) return;
  preview.append(element('div', 'loading', t('loading')));
  try {
    const detail = await spotcat.clipboard.get(item.id);
    if (token !== detailToken) return;
    if (!detail) throw new Error('missing');
    if (detail.type === 'image') {
      const wrapper = element('div', 'image'), img = element('img');
      img.alt = t('image');
      if (detail.image && /^data:image\//.test(detail.image)) img.src = detail.image;
      wrapper.append(img);
      preview.replaceChildren(wrapper);
    } else if (detail.type === 'files') {
      const ul = element('ul', 'files');
      ul.append(...(detail.files || []).map((path) => element('li', '', path)));
      preview.replaceChildren(ul);
    } else preview.replaceChildren(element('pre', '', detail.text || ''));
    preview.scrollTop = 0;
  } catch (_) {
    if (token === detailToken) preview.replaceChildren(element('div', 'loading', t('loadError')));
  }
}
let toastTimer;
function toast(text, ms = 2500) {
  $('toast').textContent = text;
  $('toast').classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => $('toast').classList.remove('show'), ms);
}
let busy = false;
async function perform(action) {
  if (busy) return;
  busy = true;
  try { await action(); } catch (_) { toast(t('actionError')); }
  finally { busy = false; }
}
async function paste(id = selectedId) {
  if (id && !(await spotcat.clipboard.paste(id))) toast(t('needAccess'), 5000);
}
async function copy(id = selectedId, { keepOpen = false } = {}) {
  if (!id) return;
  if (!(await spotcat.clipboard.copy(id))) throw new Error('copy');
  if (keepOpen) toast(t('copied'));
  else await spotcat.hideWindow();
}
async function togglePin() {
  const item = selected();
  if (item) { await spotcat.clipboard.pin(item.id, !item.pinned); await load(); }
}
async function remove() {
  const item = selected();
  if (!item) return;
  const index = items.indexOf(item);
  await spotcat.clipboard.remove(item.id);
  selectedId = items[index + 1]?.id ?? items[index - 1]?.id ?? null;
  await load();
}
$('view-cards').addEventListener('click', () => setView('cards'));
$('view-list').addEventListener('click', () => setView('list'));
for (const button of document.querySelectorAll('[data-filter]')) button.addEventListener('click', () => {
  filter = button.dataset.filter;
  document.querySelectorAll('[data-filter]').forEach((el) => el.setAttribute('aria-pressed', String(el === button)));
  previewOpen = false;
  document.body.classList.remove('preview-open');
  applyFilter();
});
$('paste').addEventListener('click', () => perform(() => paste()));
$('copy').addEventListener('click', () => perform(copy));
$('pin').addEventListener('click', () => perform(togglePin));
$('delete').addEventListener('click', () => perform(remove));
$('show-preview').addEventListener('click', () => togglePreview());
$('close-preview').addEventListener('click', () => { togglePreview(false); listEl.focus(); });
let clearArmed = null;
$('clear').addEventListener('click', () => {
  if (!clearArmed) {
    $('clear').textContent = t('clearConfirm');
    clearArmed = setTimeout(() => { clearArmed = null; $('clear').textContent = t('clear'); }, 3000);
    return;
  }
  clearTimeout(clearArmed);
  clearArmed = null;
  $('clear').textContent = t('clear');
  perform(async () => { await spotcat.clipboard.clear(); await load(); });
});
let searchTimer = null;
searchEl.addEventListener('input', () => {
  ++loadToken; // Invalidate an older request immediately, including during debounce.
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => { selectedId = null; load(); }, 80);
});
listEl.addEventListener('wheel', (e) => {
  if (viewMode !== 'cards' || e.ctrlKey || Math.abs(e.deltaX) >= Math.abs(e.deltaY)) return;
  if (listEl.scrollWidth <= listEl.clientWidth) return;
  e.preventDefault();
  listEl.scrollLeft += e.deltaY * (e.deltaMode === 1 ? 24 : e.deltaMode === 2 ? listEl.clientWidth : 1);
}, { passive: false });
document.addEventListener('keydown', (e) => {
  if (e.isComposing || e.altKey || e.ctrlKey) return;
  const editing = e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target.isContentEditable;
  if (e.metaKey && e.key.toLowerCase() === 'f') { e.preventDefault(); searchEl.focus(); searchEl.select(); return; }
  if (e.target.closest('button') && (e.key === 'Enter' || e.key === ' ')) return;
  if (e.key === 'ArrowDown' && !e.metaKey) { e.preventDefault(); move(1); }
  else if (e.key === 'ArrowUp' && !e.metaKey) { e.preventDefault(); move(-1); }
  else if (viewMode === 'cards' && !e.metaKey && (!editing || !searchEl.value) && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) {
    e.preventDefault(); move(e.key === 'ArrowRight' ? 1 : -1);
  } else if (e.key === ' ' && !editing && viewMode === 'cards') { e.preventDefault(); if (selected()) togglePreview(); }
  else if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); perform(copy); }
  else if (e.key === 'Enter') { e.preventDefault(); perform(() => paste()); }
  else if (e.metaKey && /^[1-9]$/.test(e.key)) {
    e.preventDefault(); const item = items[Number(e.key) - 1]; if (item) perform(() => paste(item.id));
  } else if (e.metaKey && e.key.toLowerCase() === 'p') { e.preventDefault(); perform(togglePin); }
  else if (e.metaKey && e.key === 'Backspace' && !searchEl.value) { e.preventDefault(); perform(remove); }
});
spotcat.clipboard.onChange(() => { if (ready) load(); });
spotcat.onEnter(async () => {
  searchEl.value = '';
  let saved = null;
  try { saved = await spotcat.storage.get('viewMode'); } catch (_) { /* Default to cards. */ }
  await setView(saved === 'list' ? 'list' : 'cards', false);
  try { recording = (await spotcat.clipboard.status()).recording; } catch (_) { recording = false; }
  ready = true;
  await load();
  searchEl.focus();
});
