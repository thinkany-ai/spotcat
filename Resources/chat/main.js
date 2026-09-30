const { t } = spotcat.i18n;
const $ = (id) => document.getElementById(id);

const ICONS = {
  back: '<svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>',
  newChat: '<svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
  send: '<svg viewBox="0 0 24 24"><path d="M12 19V5M5 12l7-7 7 7"/></svg>',
  stop: '<svg viewBox="0 0 24 24"><rect x="7" y="7" width="10" height="10" rx="1.5" class="fill"/></svg>',
  copy: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8"/></svg>',
  check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
  retry: '<svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v5h-5"/></svg>',
  context: '<svg viewBox="0 0 24 24"><path d="M8 4h8l4 4v12H8z M16 4v4h4 M4 8v12h4"/></svg>',
  history: '<svg viewBox="0 0 24 24"><path d="M3.5 12a8.5 8.5 0 1 0 2.5-6M3.5 4v4.5H8M12 7.5V12l3 2"/></svg>',
  search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/></svg>',
  folder: '<svg viewBox="0 0 24 24"><path d="M3.5 7.5A1.5 1.5 0 0 1 5 6h4l2 2h8a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z"/></svg>',
  file: '<svg viewBox="0 0 24 24"><path d="M7 3.5h7l4 4v13H7z M14 3.5v4h4 M9.5 12h6 M9.5 15.5h6"/></svg>',
  warning: '<svg viewBox="0 0 24 24"><path d="M12 4l9 16H3z M12 10v4 M12 17v.5"/></svg>',
  trash: '<svg viewBox="0 0 24 24"><path d="M4.5 7h15M10 11v6M14 11v6M6 7l1 12a1.5 1.5 0 0 0 1.5 1.4h7a1.5 1.5 0 0 0 1.5-1.4L18 7M9 7V4.5h6V7"/></svg>',
  chevron: '<svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg>',
  spark: '<svg viewBox="0 0 24 24"><path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z" class="fill"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z" class="fill"/></svg>',
};

const SYSTEM_PROMPT =
  'You are Spotcat, a helpful assistant built into a macOS launcher. ' +
  'Be concise and accurate, use Markdown when it helps, and reply in the same language the user writes in.';

// 原生方法（对话历史只对内置聊天面板开放，不在 window.spotcat 里）
const native = (method, args) => window.webkit.messageHandlers.spotcat.postMessage({ method, args: args || {} });

const state = {
  /** 当前对话的 id，第一次发送时生成；保存在 数据目录/Chats/<id>.json */
  chatID: null,
  createdAt: 0,
  /** 历史列表（摘要），打开历史时加载 */
  history: [],
  /** 当前对话用的模型 "服务商 id/模型名"；null 表示设置里的默认模型 */
  model: null,
  /** 打开参数：{ title, source, context: [{ title, content }], prompt, send } */
  request: {},
  /** { role: 'user' | 'assistant', content, streaming?, error?, stopped? } */
  messages: [],
  controller: null,
  ai: { configured: false },
};

// ---------- 模型信息 ----------

async function refreshInfo() {
  state.ai = await spotcat.ai.info({ model: state.model });
  $('subtitle').textContent = state.ai.configured ? state.ai.model : t('notConfigured');
  // 服务商放到悬停提示里，切换菜单里也能看到
  $('model-picker').title = state.ai.configured ? `${state.ai.provider} › ${state.ai.model}` : t('switchModel');
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
  // 带工具调用的回复存了完整过程（trace），原样带上，追问时模型还能看到之前查到的结果
  const history = state.messages.flatMap((m) => {
    if (m.role === 'assistant' && m.trace?.length) return m.trace;
    return !m.error && m.content ? [{ role: m.role, content: m.content }] : [];
  });
  return [{ role: 'system', content: system }, ...history];
}

let agentSeq = 0;
/** 正在进行的回复：agent.event 按 id 找到对应的回复消息 */
const agentReplies = new Map();

window.addEventListener('spotcat:agent.event', ({ detail: event }) => {
  const reply = agentReplies.get(event.id);
  if (!reply) return;
  const last = reply.parts.at(-1);
  if (event.type === 'text') {
    if (last?.type === 'text') last.text += event.delta;
    else reply.parts.push({ type: 'text', text: event.delta });
    reply.content += event.delta;
  } else if (event.type === 'tool_start') {
    reply.parts.push({ type: 'tool', callID: event.call_id, name: event.name, args: event.arguments || {}, running: true });
  } else if (event.type === 'tool_end') {
    const part = reply.parts.find((p) => p.type === 'tool' && p.callID === event.call_id);
    if (part) Object.assign(part, { running: false, output: event.output, isError: event.is_error });
  }
  scheduleRender();
});

async function send(text) {
  text = text.trim();
  if (!text || state.controller) return;
  await refreshInfo();

  state.messages.push({ role: 'user', content: text });
  if (!state.request.title) setTitle(text);
  if (!state.chatID) {
    state.chatID = crypto.randomUUID();
    state.createdAt = Date.now();
  }
  await generate();
}

async function generate() {
  /** parts：按顺序的文字段和工具步骤；content：所有文字（复制、搜索用）；trace：给模型的完整过程 */
  const reply = { role: 'assistant', content: '', parts: [], streaming: true };
  const messages = buildMessages();
  const id = ++agentSeq;
  state.messages.push(reply);
  agentReplies.set(id, reply);
  state.controller = new AbortController();
  state.controller.signal.addEventListener('abort', () => native('agent.cancel', { id }), { once: true });
  render();
  saveChat();

  try {
    const result = await native('agent.chat', { id, messages, model: state.model });
    reply.trace = result?.messages || [];
  } catch (error) {
    if (state.controller.signal.aborted) {
      reply.stopped = true;
    } else {
      reply.error = error?.message || String(error);
    }
  } finally {
    agentReplies.delete(id);
    reply.streaming = false;
    for (const part of reply.parts) if (part.running) part.running = false;
    state.controller = null;
    render();
    saveChat();
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

// 服务商 › 模型 的原生菜单，选中后只作用于当前对话
async function pickModel() {
  const rect = $('model-picker').getBoundingClientRect();
  const id = await native('models.pick', { x: rect.left, y: rect.bottom + 4, current: state.model || state.ai.id });
  if (!id) return refreshInfo(); // 可能刚在「管理模型」里改了设置
  state.model = id;
  await refreshInfo();
  saveChat();
  input.focus();
}

function newChat() {
  stop();
  state.chatID = null;
  state.model = null;
  state.messages = [];
  state.request = { profile: state.request.profile };
  setTitle('');
  renderContext();
  render();
  refreshInfo();
  closeHistory();
  $('input').value = '';
  $('input').focus();
}

// ---------- 对话历史 ----------

function chatTitle() {
  const first = state.messages.find((m) => m.role === 'user')?.content || '';
  return (state.request.title || first).replace(/\s+/g, ' ').trim().slice(0, 80);
}

async function saveChat() {
  if (!state.chatID || !state.messages.length) return;
  const chat = {
    id: state.chatID,
    title: chatTitle(),
    createdAt: state.createdAt,
    updatedAt: Date.now(),
    source: state.request.source || null,
    model: state.model,
    context: state.request.context || [],
    // 生成中的回复先存已有的部分，结束后再存一次
    messages: state.messages.map(({ role, content, parts, trace, error, stopped }) => ({ role, content, parts, trace, error, stopped })),
  };
  try {
    await native('history.save', { chat });
  } catch (error) {
    console.error('save chat failed', error);
  }
}

async function openChat(id) {
  const chat = await native('history.get', { id });
  if (!chat) return loadHistory();
  stop();
  state.chatID = chat.id;
  state.createdAt = chat.createdAt || Date.now();
  state.model = chat.model || null;
  state.request = { profile: state.request.profile, title: chat.title, source: chat.source, context: chat.context || [] };
  state.messages = (chat.messages || []).map((m) => ({ ...m, streaming: false }));
  setTitle(chat.title || '');
  renderContext();
  refreshInfo();
  closeHistory();
  render();
  $('scroller').scrollTop = $('scroller').scrollHeight;
  input.focus();
}

async function deleteChat(id) {
  await native('history.delete', { id });
  if (id === state.chatID) {
    state.chatID = null;
    state.model = null;
    state.messages = [];
    state.request = { profile: state.request.profile };
    setTitle('');
    renderContext();
    render();
    refreshInfo();
  }
  loadHistory();
}

async function loadHistory() {
  state.history = await native('history.list');
  renderHistory();
}

function openHistory() {
  // 抽屉从顶栏下方开始，顶栏仍可点（新对话、关闭历史）
  $('history').style.top = document.querySelector('.topbar').offsetHeight - 6 + 'px';
  $('history').hidden = false;
  $('history-toggle').classList.add('active');
  $('history-search').value = '';
  loadHistory();
  $('history-search').focus();
}

function closeHistory() {
  if ($('history').hidden) return;
  $('history').hidden = true;
  $('history-toggle').classList.remove('active');
  input.focus();
}

/** 今天 / 昨天 / 最近 7 天 / 最近 30 天 / 更早 */
function historyGroup(time) {
  const startOfToday = new Date().setHours(0, 0, 0, 0);
  const day = 86400000;
  if (time >= startOfToday) return 'today';
  if (time >= startOfToday - day) return 'yesterday';
  if (time >= startOfToday - 7 * day) return 'last7Days';
  if (time >= startOfToday - 30 * day) return 'last30Days';
  return 'older';
}

/** 今天显示时刻，其余显示月/日（跨年加年份） */
function formatTime(time, group) {
  const date = new Date(time);
  if (group === 'today') return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
  const sameYear = date.getFullYear() === new Date().getFullYear();
  return sameYear ? `${date.getMonth() + 1}/${date.getDate()}` : `${date.getFullYear() % 100}/${date.getMonth() + 1}/${date.getDate()}`;
}

function renderHistory() {
  const query = $('history-search').value.trim().toLowerCase();
  const chats = state.history.filter((c) =>
    !query || (c.title || '').toLowerCase().includes(query) || (c.text || '').toLowerCase().includes(query));

  const list = $('history-list');
  if (!chats.length) {
    const empty = document.createElement('div');
    empty.className = 'history-empty';
    empty.textContent = t(query ? 'historyNoMatch' : 'historyEmpty');
    return list.replaceChildren(empty);
  }

  const nodes = [];
  let group = null;
  for (const chat of chats) {
    const g = historyGroup(chat.updatedAt || 0);
    if (g !== group) {
      group = g;
      const header = document.createElement('div');
      header.className = 'history-group';
      header.textContent = t(`history.${g}`);
      nodes.push(header);
    }
    const item = document.createElement('div');
    item.className = 'history-item' + (chat.id === state.chatID ? ' current' : '');
    const title = document.createElement('span');
    title.className = 'history-title';
    title.textContent = chat.title || t('newChat');
    const time = document.createElement('span');
    time.className = 'history-time';
    time.textContent = formatTime(chat.updatedAt || 0, g);
    const remove = iconButton('trash', t('delete'), () => deleteChat(chat.id));
    remove.addEventListener('click', (e) => e.stopPropagation());
    item.append(title, time, remove);
    item.onclick = () => openChat(chat.id);
    nodes.push(item);
  }
  list.replaceChildren(...nodes);
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

  // 旧记录没有 parts，整段按文字渲染
  const parts = message.parts?.length ? message.parts : [{ type: 'text', text: message.content }];
  parts.forEach((part, i) => {
    if (part.type === 'tool') return el.append(renderToolStep(part));
    const body = document.createElement('div');
    body.className = 'markdown';
    body.innerHTML = Markdown.render(part.text);
    if (message.streaming && i === parts.length - 1) body.insertAdjacentHTML('beforeend', '<span class="caret"></span>');
    el.append(body);
  });
  // 等待模型开始输出或工具刚结束时，末尾显示光标
  if (message.streaming && parts.at(-1)?.type !== 'text' && !parts.at(-1)?.running) {
    el.insertAdjacentHTML('beforeend', '<div class="markdown"><span class="caret"></span></div>');
  }

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

/** 工具步骤：一行说明（运行中转圈 / 完成打勾 / 失败），点击展开结果 */
function renderToolStep(part) {
  const step = document.createElement('div');
  step.className = 'tool-step' + (part.open ? ' open' : '') + (part.isError ? ' failed' : '');
  const head = document.createElement('button');
  head.className = 'tool-head';
  const icon = document.createElement('span');
  icon.className = 'tool-icon';
  icon.innerHTML = ICONS[TOOL_ICONS[part.name] || 'search'];
  const label = document.createElement('span');
  label.className = 'tool-label';
  label.textContent = toolLabel(part);
  const status = document.createElement('span');
  status.className = 'tool-status';
  status.innerHTML = part.running ? '<span class="spinner"></span>' : part.isError ? ICONS.warning : ICONS.check;
  head.append(icon, label, status);
  if (!part.running) head.append(Object.assign(document.createElement('span'), { className: 'chevron', innerHTML: ICONS.chevron }));
  head.disabled = part.running;
  head.onclick = () => {
    part.open = !part.open;
    render();
  };
  step.append(head);
  if (part.open && part.output) {
    const output = document.createElement('pre');
    output.className = 'tool-output';
    output.textContent = part.output;
    step.append(output);
  }
  return step;
}

const TOOL_ICONS = { list_directory: 'folder', search_files: 'search', read_file: 'file' };

function toolLabel({ name, args = {} }) {
  switch (name) {
    case 'list_directory':
      return t('tool.list', { path: args.path || '~' });
    case 'search_files': {
      const what = args.query || (args.extensions || []).map((e) => '.' + e).join(' ') || '…';
      return args.directory ? t('tool.searchIn', { query: what, path: args.directory }) : t('tool.search', { query: what });
    }
    case 'read_file':
      return t('tool.read', { path: args.path || '' });
    default:
      return name;
  }
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
// 顶栏空白处（按钮以外）按下即可拖动面板
document.querySelector('.topbar').addEventListener('mousedown', (e) => {
  if (e.button !== 0 || e.target.closest('button, input, textarea, a')) return;
  e.preventDefault();
  native('window.drag');
});
$('model-picker').onclick = pickModel;
$('history-toggle').onclick = () => ($('history').hidden ? openHistory() : closeHistory());
$('history-backdrop').onclick = closeHistory;
$('history-search').addEventListener('input', renderHistory);
// Esc 由原生拦截后先问页面：历史打开时只关闭历史，返回 true 表示已处理，不退出聊天
window.__spotcatEscape = () => {
  if ($('history').hidden) return false;
  closeHistory();
  return true;
};
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
$('history-toggle').innerHTML = ICONS.history;
document.querySelector('.search-icon').innerHTML = ICONS.search;
document.querySelector('.context-icon').innerHTML = ICONS.context;
document.querySelector('.chevron').innerHTML = ICONS.chevron;
document.querySelector('.model-chevron').innerHTML = ICONS.chevron;
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
