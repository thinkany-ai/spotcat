const { t, locale } = spotcat.i18n;
const $ = (id) => document.getElementById(id);
const listEl = $('list'), searchEl = $('search'), preview = $('preview');

/** @type {{ id: string, type: 'text'|'image'|'files', preview?: string, length?: number, files?: string[], size?: number[], app?: string, time: number, pinned: boolean }[]} */
let items = [];
let selectedId = null;
let detailToken = 0;
const thumbs = new Map();

// MARK: - 数据

async function load() {
  items = await spotcat.clipboard.list({ query: searchEl.value, limit: 300 });
  if (!items.some((i) => i.id === selectedId)) selectedId = items[0]?.id ?? null;
  render();
}

const selected = () => items.find((i) => i.id === selectedId) || null;

function formatTime(ts) {
  const diff = Date.now() - ts;
  if (diff < 60_000) return t('justNow');
  if (diff < 3_600_000) return t('minutesAgo', { n: Math.floor(diff / 60_000) });
  const date = new Date(ts), now = new Date();
  if (date.toDateString() === now.toDateString()) {
    return date.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' });
  }
  return date.toLocaleDateString(locale, { month: 'short', day: 'numeric' });
}

const fileName = (path) => path.split('/').filter(Boolean).pop() || path;

function titleOf(item) {
  if (item.type === 'image') return item.size ? `${t('image')} ${item.size[0]}×${item.size[1]}` : t('image');
  if (item.type === 'files') return item.files.length === 1 ? fileName(item.files[0]) : t('files', { n: item.files.length });
  return item.preview.replace(/\s+/g, ' ').trim();
}

// MARK: - 列表

function render() {
  listEl.replaceChildren(...items.map((item, index) => {
    const li = document.createElement('li');
    li.dataset.id = item.id;
    li.className = (item.id === selectedId ? 'selected ' : '') + (item.pinned ? 'pinned' : '');

    const thumb = document.createElement('div');
    thumb.className = 'thumb';
    if (item.type === 'image') {
      const cached = thumbs.get(item.id);
      if (cached) thumb.innerHTML = `<img src="${cached}">`;
      else {
        thumb.textContent = '▧';
        spotcat.clipboard.thumbnail(item.id).then((url) => {
          if (!url) return;
          thumbs.set(item.id, url);
          thumb.innerHTML = `<img src="${url}">`;
        });
      }
    } else {
      thumb.textContent = item.type === 'files' ? '⎘' : 'T';
    }

    const body = document.createElement('div');
    body.className = 'body';
    const title = document.createElement('div');
    title.className = 'title';
    title.textContent = titleOf(item);
    const sub = document.createElement('div');
    sub.className = 'sub';
    sub.textContent = [formatTime(item.time), item.app].filter(Boolean).join(' · ');
    body.append(title, sub);

    li.append(thumb, body);
    if (index < 9) {
      const key = document.createElement('span');
      key.className = 'key';
      key.textContent = `⌘${index + 1}`;
      li.append(key);
    }
    li.addEventListener('mousedown', () => select(item.id));
    li.addEventListener('dblclick', () => paste(item.id));
    return li;
  }));

  if (!items.length) {
    const empty = document.createElement('div');
    empty.className = 'list-empty';
    empty.textContent = searchEl.value.trim() ? t('noResults') : t('empty');
    listEl.append(empty);
  }
  listEl.querySelector('.selected')?.scrollIntoView({ block: 'nearest' });
  renderDetail();
}

function select(id) {
  if (id === selectedId) return;
  selectedId = id;
  listEl.querySelectorAll('li').forEach((li) => li.classList.toggle('selected', li.dataset.id === id));
  listEl.querySelector('.selected')?.scrollIntoView({ block: 'nearest' });
  renderDetail();
}

function move(step) {
  if (!items.length) return;
  const index = items.findIndex((i) => i.id === selectedId);
  select(items[Math.min(items.length - 1, Math.max(0, index + step))].id);
}

// MARK: - 预览

async function renderDetail() {
  const item = selected();
  document.body.classList.toggle('no-item', !item);
  $('empty').textContent = searchEl.value.trim() ? t('noResults') : t('empty');
  if (!item) return;

  $('pin').textContent = item.pinned ? t('unpin') : t('pin');
  const meta = [formatTime(item.time), item.app && t('from', { app: item.app })];
  if (item.type === 'text') meta.push(t('chars', { n: item.length }));
  $('meta').textContent = meta.filter(Boolean).join(' · ');

  const token = ++detailToken;
  const detail = await spotcat.clipboard.get(item.id).catch(() => null);
  if (token !== detailToken || !detail) return;

  if (detail.type === 'image') {
    preview.innerHTML = '<div class="image"><img></div>';
    preview.querySelector('img').src = detail.image || '';
  } else if (detail.type === 'files') {
    const ul = document.createElement('ul');
    ul.className = 'files';
    ul.append(...detail.files.map((path) => {
      const li = document.createElement('li');
      const dir = document.createElement('span');
      dir.textContent = path.slice(0, path.length - fileName(path).length);
      li.append(dir, fileName(path));
      return li;
    }));
    preview.replaceChildren(ul);
  } else {
    const pre = document.createElement('pre');
    pre.textContent = detail.text;
    preview.replaceChildren(pre);
  }
  preview.scrollTop = 0;
}

// MARK: - 操作

let toastTimer = null;
function toast(text, ms = 1500) {
  $('toast').textContent = text;
  $('toast').classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => $('toast').classList.remove('show'), ms);
}

async function paste(id = selectedId) {
  if (!id) return;
  // 没有辅助功能权限时只复制，面板保持打开
  const pasted = await spotcat.clipboard.paste(id);
  if (!pasted) toast(t('needAccess'), 5000);
}

async function copy() {
  if (!selectedId) return;
  await spotcat.clipboard.copy(selectedId);
  spotcat.hideWindow();
}

async function togglePin() {
  const item = selected();
  if (!item) return;
  await spotcat.clipboard.pin(item.id, !item.pinned);
}

async function remove() {
  const item = selected();
  if (!item) return;
  const index = items.indexOf(item);
  selectedId = items[index + 1]?.id ?? items[index - 1]?.id ?? null;
  await spotcat.clipboard.remove(item.id);
}

$('paste').addEventListener('click', () => paste());
$('copy').addEventListener('click', copy);
$('pin').addEventListener('click', togglePin);
$('delete').addEventListener('click', remove);
// WKWebView 里没有 confirm()：第一次点击变成确认，3 秒内再点一次才清空
let clearArmed = null;
$('clear').addEventListener('click', async () => {
  const button = $('clear');
  if (!clearArmed) {
    button.textContent = t('clearConfirm');
    clearArmed = setTimeout(() => { clearArmed = null; button.textContent = t('clear'); }, 3000);
    return;
  }
  clearTimeout(clearArmed);
  clearArmed = null;
  button.textContent = t('clear');
  await spotcat.clipboard.clear();
});

let searchTimer = null;
searchEl.addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => { selectedId = null; load(); }, 80);
});

document.addEventListener('keydown', (e) => {
  if (e.isComposing) return;
  if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
  else if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); copy(); }
  else if (e.key === 'Enter') { e.preventDefault(); paste(); }
  else if (e.metaKey && /^[1-9]$/.test(e.key)) {
    e.preventDefault();
    const item = items[Number(e.key) - 1];
    if (item) paste(item.id);
  } else if (e.metaKey && e.key.toLowerCase() === 'p') { e.preventDefault(); togglePin(); }
  else if (e.metaKey && e.key === 'Backspace' && !searchEl.value) { e.preventDefault(); remove(); }
});

// 面板开着时复制了新内容，或者置顶、删除后，刷新列表
spotcat.clipboard.onChange(() => load());

spotcat.onEnter(async () => {
  searchEl.value = '';
  searchEl.focus();
  const status = await spotcat.clipboard.status();
  $('status').textContent = status.recording ? '' : t('notRecording');
  await load();
});
