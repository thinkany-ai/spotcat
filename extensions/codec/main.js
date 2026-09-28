const utf8 = { encode: (s) => new TextEncoder().encode(s), decode: (b) => new TextDecoder('utf-8', { fatal: true }).decode(b) };

const bytesToBase64 = (bytes) => {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
};

const base64ToBytes = (text) => {
  // 容忍换行、URL-safe 字符和缺失的 padding
  let s = text.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
  if (s.length % 4) s += '='.repeat(4 - (s.length % 4));
  const binary = atob(s);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
};

const { t } = spotcat.i18n;

const MODES = {
  'url-encode':    { run: (s) => encodeURIComponent(s) },
  'url-decode':    { run: (s) => decodeURIComponent(s.replace(/\+/g, '%20')) },
  'base64-encode': { run: (s) => bytesToBase64(utf8.encode(s)) },
  'base64-decode': { run: (s) => utf8.decode(base64ToBytes(s)) },
};
const label = (code) => t(`tab.${code}`);

const $ = (id) => document.getElementById(id);
const input = $('input'), output = $('output'), copyBtn = $('copy'), askBtn = $('ask-ai');
let mode = 'url-encode';
let result = '';

function renderTabs() {
  $('tabs').replaceChildren(...Object.keys(MODES).map((code) => {
    const b = document.createElement('button');
    b.className = 'tab' + (code === mode ? ' active' : '');
    b.textContent = label(code);
    b.onclick = () => { mode = code; renderTabs(); convert(); input.focus(); };
    return b;
  }));
}

function convert() {
  const text = input.value;
  output.classList.remove('error');
  result = '';
  if (text) {
    try {
      result = MODES[mode].run(text);
    } catch (e) {
      output.classList.add('error');
      output.textContent = t(mode.startsWith('url') ? 'invalidUrl' : 'invalidBase64', { mode: label(mode) });
      copyBtn.disabled = askBtn.disabled = true;
      return;
    }
  }
  output.textContent = result;
  copyBtn.disabled = askBtn.disabled = !result;
}

async function copyResult(andHide) {
  if (!result) return;
  await spotcat.copyText(result);
  copyBtn.textContent = t('copied');
  setTimeout(() => (copyBtn.textContent = t('copy')), 1200);
  if (andHide) spotcat.hideWindow();
}

input.addEventListener('input', convert);
copyBtn.addEventListener('click', () => copyResult(false));

// 带着输入和结果进入 Spotcat 的 AI 对话继续追问
askBtn.addEventListener('click', () => {
  if (!result) return;
  const text = input.value.length > 30 ? input.value.slice(0, 30) + '…' : input.value;
  spotcat.chat.open({
    title: t('chatTitle', { mode: label(mode), text }),
    context: [
      { title: t('ctxInput'), content: input.value },
      { title: t('ctxOutput', { mode: label(mode) }), content: result },
    ],
  });
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); copyResult(true); }
});

spotcat.onEnter(({ code, type, payload }) => {
  if (MODES[code]) mode = code;
  // 通过内容匹配进入时带入内容；通过关键词进入时输入框留空
  input.value = type === 'match' ? payload : '';
  renderTabs();
  convert();
  input.focus();
});
