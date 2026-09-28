const { t } = spotcat.i18n;
const $ = (id) => document.getElementById(id);

const ICONS = {
  back: '<svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>',
  newChat: '<svg viewBox="0 0 24 24"><path d="M12 20h8M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
  send: '<svg viewBox="0 0 24 24"><path d="M12 19V5M5 12l7-7 7 7"/></svg>',
  stop: '<svg viewBox="0 0 24 24"><rect x="7" y="7" width="10" height="10" rx="1.5" class="fill"/></svg>',
  copy: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8"/></svg>',
  check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
  retry: '<svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v5h-5"/></svg>',
  context: '<svg viewBox="0 0 24 24"><path d="M8 4h8l4 4v12H8z M16 4v4h4 M4 8v12h4"/></svg>',
  chevron: '<svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg>',
  spark: '<svg viewBox="0 0 24 24"><path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z" class="fill"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z" class="fill"/></svg>',
};

const SYSTEM_PROMPT =
  'You are Spotcat, a helpful assistant built into a macOS launcher. ' +
  'Be concise and accurate, use Markdown when it helps, and reply in the same language the user writes in.';

const state = {
  /** 打开参数：{ title, source, context: [{ title, content }], prompt, send } */
  request: {},
  /** { role: 'user' | 'assistant', content, streaming?, error?, stopped? } */
  messages: [],
  controller: null,
  ai: { configured: false },
};

// ---------- 模型信息 ----------

async function refreshInfo() {
  state.ai = await spotcat.ai.info();
  $('subtitle').textContent = state.ai.configured ? `${state.ai.model} · ${state.ai.provider}` : t('notConfigured');
  renderEmpty();
}

// ---------- 发送 ----------

function buildMessages() {
  let system = SYSTEM_PROMPT;
  const name = state.request.profile?.name;
  if (name) system += ` The user's name is ${name}.`;
  const context = state.request.context || [];
  if (context.length) {
    const source = state.request.source ? ` from "${state.request.source}"` : '';
    system += `\n\nThe user opened this chat${source}. Use the following context to answer:\n` +
      context.map((c) => `\n### ${c.title || 'Context'}\n${c.content}`).join('\n');
  }
  const history = state.messages
    .filter((m) => !m.error && m.content)
    .map(({ role, content }) => ({ role, content }));
  return [{ role: 'system', content: system }, ...history];
}

async function send(text) {
  text = text.trim();
  if (!text || state.controller) return;
  await refreshInfo();

  state.messages.push({ role: 'user', content: text });
  if (!state.request.title) setTitle(text);
  await generate();
}

async function generate() {
  const reply = { role: 'assistant', content: '', streaming: true };
  const messages = buildMessages();
  state.messages.push(reply);
  state.controller = new AbortController();
  render();

  try {
    await spotcat.ai.chat({
      messages,
      signal: state.controller.signal,
      onDelta: (delta) => {
        reply.content += delta;
        scheduleRender();
      },
    });
  } catch (error) {
    if (state.controller.signal.aborted) {
      reply.stopped = true;
    } else {
      reply.error = error?.message || String(error);
    }
  } finally {
    reply.streaming = false;
    state.controller = null;
    render();
  }
}

function retry() {
  if (state.controller) return;
  // 去掉失败的回复，用同样的历史重新生成
  if (state.messages.at(-1)?.role === 'assistant') state.messages.pop();
  generate();
}

function stop() {
  state.controller?.abort();
}

function newChat() {
  stop();
  state.messages = [];
  state.request = { profile: state.request.profile };
  setTitle('');
  renderContext();
  render();
  $('input').value = '';
  $('input').focus();
}

// ---------- 渲染 ----------

let renderPending = false;
function scheduleRender() {
  if (renderPending) return;
  renderPending = true;
  requestAnimationFrame(() => {
    renderPending = false;
    render();
  });
}

function render() {
  const scroller = $('scroller');
  const nearBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;

  $('messages').replaceChildren(...state.messages.map(renderMessage));
  renderEmpty();
  renderComposer();

  if (nearBottom) scroller.scrollTop = scroller.scrollHeight;
}

function renderMessage(message, index) {
  const el = document.createElement('div');
  el.className = `message ${message.role}`;

  if (message.role === 'user') {
    el.textContent = message.content;
    return el;
  }

  const body = document.createElement('div');
  body.className = 'markdown';
  body.innerHTML = Markdown.render(message.content);
  if (message.streaming) body.insertAdjacentHTML('beforeend', '<span class="caret"></span>');
  el.append(body);

  if (message.error) {
    const error = document.createElement('p');
    error.className = 'error';
    error.textContent = t('error', { message: message.error });
    el.append(error);
  }
  if (message.stopped) {
    const note = document.createElement('p');
    note.className = 'note';
    note.textContent = t('stopped');
    el.append(note);
  }

  if (!message.streaming) {
    const actions = document.createElement('div');
    actions.className = 'actions';
    if (message.content) actions.append(iconButton('copy', t('copy'), (btn) => copy(message.content, btn)));
    const isLast = index === state.messages.length - 1;
    if (isLast && (message.error || message.stopped)) actions.append(iconButton('retry', t('retry'), retry));
    el.append(actions);
  }
  return el;
}

function renderEmpty() {
  const empty = state.messages.length === 0;
  $('empty').hidden = !empty;
  if (!empty) return;
  const name = state.request.profile?.name;
  $('empty-title').textContent = state.request.context?.length
    ? t('emptyWithContext')
    : name ? t('emptyTitleNamed', { name }) : t('emptyTitle');
  $('setup').hidden = state.ai.configured;
}

function renderComposer() {
  const busy = Boolean(state.controller);
  const button = $('send');
  button.innerHTML = busy ? ICONS.stop : ICONS.send;
  button.title = busy ? t('stop') : t('send');
  button.classList.toggle('busy', busy);
  button.disabled = !busy && !$('input').value.trim();
}

function renderContext() {
  const context = state.request.context || [];
  $('context').hidden = context.length === 0;
  if (!context.length) return;

  $('context-label').textContent = state.request.source
    ? t('contextFrom', { source: state.request.source })
    : t('context');
  $('context-count').textContent = context.length;
  $('context-body').replaceChildren(...context.map((item) => {
    const block = document.createElement('div');
    block.className = 'context-item';
    const title = document.createElement('div');
    title.className = 'context-title';
    title.textContent = item.title;
    const content = document.createElement('pre');
    content.textContent = item.content;
    block.append(title, content);
    return block;
  }));
}

function setTitle(text) {
  const title = text.replace(/\s+/g, ' ').trim();
  $('title').textContent = title ? (title.length > 40 ? title.slice(0, 40) + '…' : title) : t('newChat');
}

function iconButton(icon, title, onClick) {
  const button = document.createElement('button');
  button.className = 'icon-btn small';
  button.title = title;
  button.innerHTML = ICONS[icon];
  button.onclick = () => onClick(button);
  return button;
}

async function copy(text, button) {
  await spotcat.copyText(text);
  button.innerHTML = ICONS.check;
  setTimeout(() => (button.innerHTML = ICONS.copy), 1000);
}

// ---------- 事件 ----------

const input = $('input');

function autosize() {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 160) + 'px';
  renderComposer();
}

input.addEventListener('input', autosize);
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    const text = input.value;
    if (!text.trim() || state.controller) return;
    input.value = '';
    autosize();
    send(text);
  }
});

$('send').onclick = () => {
  if (state.controller) return stop();
  const text = input.value;
  input.value = '';
  autosize();
  send(text);
};

$('back').onclick = () => spotcat.exit();
$('new-chat').onclick = newChat;
$('open-settings').onclick = () => spotcat.openSettings('ai');
$('context-toggle').onclick = () => {
  const body = $('context-body');
  body.hidden = !body.hidden;
  $('context').classList.toggle('open', !body.hidden);
};
// 从设置返回后刷新模型信息
window.addEventListener('focus', refreshInfo);

// ---------- 启动 ----------

$('back').innerHTML = ICONS.back;
$('new-chat').innerHTML = ICONS.newChat;
document.querySelector('.context-icon').innerHTML = ICONS.context;
document.querySelector('.chevron').innerHTML = ICONS.chevron;
document.querySelector('.spark').innerHTML = ICONS.spark;

spotcat.onEnter(async ({ data }) => {
  state.request = data || {};
  setTitle(state.request.title || '');
  renderContext();
  render();
  await refreshInfo();

  const prompt = state.request.prompt || '';
  if (state.request.send && prompt.trim()) {
    send(prompt);
  } else {
    input.value = prompt;
    autosize();
  }
  input.focus();
});
