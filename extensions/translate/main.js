const ICONS = {
  speak: '<svg viewBox="0 0 24 24"><path d="M4 9v6h4l5 4V5L8 9H4z"/><path d="M16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12" fill="none"/></svg>',
  copy: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="12" rx="2.5" fill="none"/><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8" fill="none"/></svg>',
  check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none"/></svg>',
  swap: '<svg viewBox="0 0 24 24"><path d="M4 8h15l-4-4M20 16H5l4 4" fill="none"/></svg>',
  chevron: '<svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6" fill="none"/></svg>',
  retry: '<svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v5h-5" fill="none"/></svg>',
  settings: '<svg viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h2M10 17h10" fill="none"/><circle cx="16" cy="7" r="2" fill="none"/><circle cx="8" cy="17" r="2" fill="none"/></svg>',
  close: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18" fill="none"/></svg>',
  chat: '<svg viewBox="0 0 24 24"><path d="M5 5h14v10H10l-4 4v-4H5z" fill="none"/><path d="M9 10h6" fill="none"/></svg>',
};

const $ = (id) => document.getElementById(id);
const input = $('input');

const state = {
  settings: structuredClone(DEFAULT_SETTINGS),
  /** 传给服务的上下文：{ ai: spotcat.ai.info() } */
  ctx: { ai: null },
  source: 'auto',
  detected: null,
  runId: 0,
  /** serviceId -> { status: 'loading' | 'ok' | 'error' | 'unconfigured', text, to } */
  results: {},
};

// ---------- 设置 ----------

async function loadSettings() {
  const saved = (await spotcat.storage.get('settings')) || {};
  const d = DEFAULT_SETTINGS;
  state.settings = {
    ...d,
    target: saved.target ?? d.target,
    enabled: { ...d.enabled, ...saved.enabled },
    collapsed: { ...d.collapsed, ...saved.collapsed },
  };
}

const saveSettings = () => spotcat.storage.set('settings', state.settings);

async function refreshAIInfo() {
  state.ctx.ai = await spotcat.ai.info();
}

// ---------- 语言栏 ----------

function renderLanguageSelects() {
  const options = (autoLabel) =>
    [`<option value="auto">${autoLabel}</option>`]
      .concat(LANGUAGES.map((l) => `<option value="${l.code}">${Lang.name(l.code)}</option>`))
      .join('');
  $('source').innerHTML = options(t('autoDetect'));
  $('target').innerHTML = options(t('autoTarget'));
  $('source').value = state.source;
  $('target').value = state.settings.target;
}

function currentLanguages() {
  const from = state.source === 'auto' ? state.detected || 'auto' : state.source;
  const to = state.settings.target === 'auto' ? Lang.autoTarget(from) : state.settings.target;
  return { from, to };
}

function renderDetected() {
  const chip = $('detected');
  chip.hidden = !(state.source === 'auto' && state.detected);
  chip.innerHTML = t('detected', { lang: `<b>${Lang.name(state.detected)}</b>` });
}

// ---------- 翻译 ----------

const enabledServices = () => SERVICES.filter((s) => state.settings.enabled[s.id]);

function runService(service, request, runId) {
  if (!service.isConfigured(state.ctx)) {
    state.results[service.id] = { status: 'unconfigured' };
    return;
  }
  state.results[service.id] = { status: 'loading' };
  service
    .translate(request)
    .then((text) => ({ status: 'ok', text, to: request.to }))
    .catch((error) => ({ status: 'error', text: error?.message || String(error) }))
    .then((result) => {
      if (runId !== state.runId) return; // 已有更新的翻译请求
      state.results[service.id] = result;
      renderCard(service);
    });
}

async function translateAll() {
  const text = input.value.trim();
  const runId = ++state.runId;
  spotcat.stopSpeaking();

  if (!text) {
    state.detected = null;
    state.results = {};
    renderDetected();
    renderResults();
    return;
  }

  if (state.source === 'auto') {
    state.detected = Lang.normalize(await spotcat.detectLanguage(text));
    if (runId !== state.runId) return;
  }
  renderDetected();

  const { from, to } = currentLanguages();
  for (const service of enabledServices()) runService(service, { text, from, to }, runId);
  renderResults();
}

function retry(service) {
  const text = input.value.trim();
  if (!text) return;
  runService(service, { text, ...currentLanguages() }, state.runId);
  renderCard(service);
}

let debounceTimer;
function scheduleTranslate() {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(translateAll, 500);
}

function translateNow() {
  clearTimeout(debounceTimer);
  translateAll();
}

// ---------- 结果卡片 ----------

function renderResults() {
  $('results').replaceChildren(...enabledServices().map((service) => {
    const card = document.createElement('section');
    card.className = 'card result';
    card.dataset.service = service.id;
    card.innerHTML = `
      <header>
        <span class="badge" style="background:${service.badge.color}">${service.badge.text}</span>
        <span class="name"></span>
        <span class="spacer"></span>
        <button class="icon-btn retry" title="${t('retry')}">${ICONS.retry}</button>
        <button class="icon-btn toggle" title="${t('toggle')}">${ICONS.chevron}</button>
      </header>
      <div class="body"></div>`;
    card.querySelector('.retry').onclick = () => retry(service);
    card.querySelector('.toggle').onclick = () => {
      state.settings.collapsed[service.id] = !state.settings.collapsed[service.id];
      saveSettings();
      renderCard(service);
    };
    renderCard(service, card);
    return card;
  }));
}

function renderCard(service, card = document.querySelector(`[data-service="${service.id}"]`)) {
  if (!card) return;
  const result = state.results[service.id];
  const collapsed = Boolean(state.settings.collapsed[service.id]);
  card.classList.toggle('collapsed', collapsed);
  card.querySelector('.name').textContent = service.name(state.ctx);
  card.querySelector('.retry').hidden = result?.status !== 'error';

  const body = card.querySelector('.body');
  body.hidden = collapsed || !result;
  if (body.hidden) return;

  switch (result.status) {
    case 'loading':
      body.innerHTML = `<p class="loading">${t('translating')}</p>`;
      break;
    case 'unconfigured':
      body.innerHTML = `<p class="muted">${t('aiNotConfigured')} <a href="#">${t('goToSettings')}</a></p>`;
      body.querySelector('a').onclick = (e) => { e.preventDefault(); spotcat.openSettings('ai'); };
      break;
    case 'error':
      body.innerHTML = '<p class="error"></p>';
      body.querySelector('p').textContent = t('failed', { message: result.text });
      break;
    case 'ok': {
      body.innerHTML = `
        <p class="text"></p>
        <div class="actions">
          <button class="icon-btn speak" title="${t('speak')}">${ICONS.speak}</button>
          <button class="icon-btn copy" title="${t('copy')}">${ICONS.copy}</button>
          <button class="icon-btn ask" title="${t('askAI')}">${ICONS.chat}</button>
        </div>`;
      body.querySelector('.text').textContent = result.text;
      body.querySelector('.speak').onclick = () => result.text && spotcat.speak(result.text, result.to);
      body.querySelector('.copy').onclick = (e) => copy(result.text, e.currentTarget);
      body.querySelector('.ask').onclick = () => askAI(service, result);
      break;
    }
  }
}

// ---------- 追问 AI ----------

/** 带着原文和译文进入 Spotcat 的 AI 对话 */
function askAI(service, result) {
  const source = input.value.trim();
  const { from } = currentLanguages();
  const short = source.length > 30 ? source.slice(0, 30) + '…' : source;
  spotcat.chat.open({
    title: t('chatTitle', { text: short }),
    context: [
      { title: t('ctxSource', { lang: from === 'auto' ? t('autoDetect') : Lang.name(from) }), content: source },
      { title: t('ctxTranslation', { service: service.name(state.ctx), lang: Lang.name(result.to) }), content: result.text },
    ],
  });
}

// ---------- 通用动作 ----------

async function copy(text, button) {
  if (!text) return;
  await spotcat.copyText(text);
  if (button) {
    button.innerHTML = ICONS.check;
    setTimeout(() => (button.innerHTML = ICONS.copy), 1000);
  }
}

function firstResult() {
  return enabledServices().map((s) => state.results[s.id]).find((r) => r?.status === 'ok')?.text;
}

// ---------- 设置面板 ----------

function openSettings() {
  $('service-toggles').innerHTML = SERVICES.map((service) => `
    <label class="row">
      <span class="badge" style="background:${service.badge.color}">${service.badge.text}</span>
      <span>${service.name(state.ctx)}</span>
      <input type="checkbox" data-id="${service.id}" ${state.settings.enabled[service.id] ? 'checked' : ''}>
    </label>`).join('');
  $('settings').hidden = false;
  $('main').inert = true;
}

function closeSettings() {
  $('settings').hidden = true;
  $('main').inert = false;
  input.focus();
}

$('save-settings').onclick = async () => {
  document.querySelectorAll('#service-toggles input').forEach((box) => (state.settings.enabled[box.dataset.id] = box.checked));
  await saveSettings();
  closeSettings();
  translateNow();
};

$('close-settings').onclick = closeSettings;
$('open-settings').onclick = openSettings;
$('open-spotcat-settings').onclick = (e) => { e.preventDefault(); spotcat.openSettings('ai'); };
$('open-language-settings').onclick = (e) => {
  e.preventDefault();
  spotcat.openURL('x-apple.systempreferences:com.apple.Localization-Settings.extension');
};

// ---------- 事件 ----------

input.addEventListener('input', scheduleTranslate);
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.metaKey && !e.isComposing) {
    e.preventDefault();
    translateNow();
  }
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && e.metaKey) {
    e.preventDefault();
    const text = firstResult();
    if (text) copy(text).then(() => spotcat.hideWindow());
  }
});

$('source').onchange = () => { state.source = $('source').value; translateNow(); };
$('target').onchange = () => { state.settings.target = $('target').value; saveSettings(); translateNow(); };
$('swap').onclick = () => {
  const { from, to } = currentLanguages();
  if (from === 'auto') return;
  state.source = to;
  state.settings.target = from;
  $('source').value = state.source;
  $('target').value = state.settings.target;
  saveSettings();
  translateNow();
};

$('speak-input').onclick = () => input.value.trim() && spotcat.speak(input.value.trim(), state.detected);
$('copy-input').onclick = (e) => copy(input.value.trim(), e.currentTarget);

// 在 Spotcat 设置里配置好 AI 后回到这里，刷新 AI 卡片
window.addEventListener('focus', async () => {
  const wasConfigured = state.ctx.ai?.configured;
  await refreshAIInfo();
  if (!wasConfigured && state.ctx.ai?.configured && state.results.ai?.status === 'unconfigured') {
    retry(SERVICES.find((s) => s.id === 'ai'));
  }
});

// ---------- 启动 ----------

$('speak-input').innerHTML = ICONS.speak;
$('copy-input').innerHTML = ICONS.copy;
$('swap').innerHTML = ICONS.swap;
$('open-settings').innerHTML = ICONS.settings;
$('close-settings').innerHTML = ICONS.close;

const ready = Promise.all([loadSettings(), refreshAIInfo()]).then(renderLanguageSelects);

spotcat.onEnter(async ({ type, payload }) => {
  await ready;
  // 内容匹配进入时直接翻译带入的文字；关键词进入时等待输入
  input.value = type === 'match' ? payload : '';
  input.focus();
  translateNow();
});
