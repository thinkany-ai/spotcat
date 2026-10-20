// Synthetic test data only. Never accesses NSPasteboard, production storage or a network.
const fixtureImage = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="480" height="240"><rect width="480" height="240" fill="#d6e9e5"/><text x="240" y="130" text-anchor="middle" fill="#277b70" font-family="sans-serif" font-size="30">Image preview · 480 × 240</text></svg>');
const fixtureNow = Date.now();
const fixtures = [
  { id: 'note', type: 'text', preview: '周五产品评审\n\n1. 确认新版界面\n2. 整理用户反馈\n3. 发布前回归测试', text: '周五产品评审\n\n1. 确认新版界面\n2. 整理用户反馈\n3. 发布前回归测试\n\n这段只出现在完整预览中。', length: 68, app: '备忘录', time: fixtureNow - 60000, pinned: true },
  { id: 'url', type: 'text', preview: 'https://github.com/thinkany-ai/spotcat', text: 'https://github.com/thinkany-ai/spotcat', length: 38, app: 'Safari', time: fixtureNow - 120000, pinned: false },
  { id: 'pic', type: 'image', image: fixtureImage, size: [480, 240], app: '预览', time: fixtureNow - 180000, pinned: false },
  { id: 'files', type: 'files', files: ['/demo/设计方案.pdf', '/demo/界面草稿.fig'], app: 'Finder', time: fixtureNow - 240000, pinned: false },
  { id: 'code', type: 'text', preview: 'const view = "cards";\n\n// 更直观地浏览复制内容\nclipboard.show(view);', text: 'const view = "cards";', length: 80, app: 'Code', time: fixtureNow - 300000, pinned: false },
  { id: 'unsafe', type: 'text', preview: '<img src=x onerror="window.__injected=true">', text: '<script>window.__injected=true</script>', length: 48, app: 'TextEdit', time: fixtureNow - 360000, pinned: false },
];
let fakeItems = fixtures.map((i) => ({ ...i }));
let fakeStorage = {}, fakeChange = () => {}, fakeListHook = null, fakeGetHook = null;
let fakeSavedError = false, fakeGetCalls = 0, fakePasteOK = true, fakeCopyOK = true, fakeCopyHook = null;
const fakeCalls = [];
const messages = window.fixtureMessages;
const tr = (key, vars) => (messages[key] || key).replace(/\{(\w+)\}/g, (m, k) => vars?.[k] ?? m);
window.spotcat = {
  i18n: { locale: 'zh-Hans', t: tr },
  onEnter: (cb) => { window.fixtureEnter = cb; cb(); },
  hideWindow: async () => { fakeCalls.push(['hide']); },
  storage: {
    get: async (key) => fakeStorage[key] ?? null,
    set: async (key, value) => { if (fakeSavedError) throw Error('storage'); fakeStorage[key] = value; },
  },
  clipboard: {
    list: async (o) => {
      if (fakeListHook) return fakeListHook(o);
      const result = fakeItems.filter((i) => !o.query || [i.text, i.preview, i.app, ...(i.files || [])].join(' ').toLowerCase().includes(o.query.toLowerCase()));
      return [...result.filter((i) => i.pinned), ...result.filter((i) => !i.pinned)].slice(0, o.limit);
    },
    get: async (id) => { fakeGetCalls++; if (fakeGetHook) return fakeGetHook(id); return fakeItems.find((i) => i.id === id); },
    thumbnail: async (id, size) => { fakeCalls.push(['thumbnail', id, size]); return fixtureImage; },
    setView: async (mode) => { fakeCalls.push(['view', mode]); },
    status: async () => ({ recording: true }),
    onChange: (cb) => { fakeChange = cb; },
    pin: async (id, pinned) => { fakeItems.find((i) => i.id === id).pinned = pinned; fakeChange(); },
    remove: async (id) => { fakeItems = fakeItems.filter((i) => i.id !== id); fakeChange(); },
    clear: async () => { fakeItems = fakeItems.filter((i) => i.pinned); fakeChange(); },
    paste: async (id) => { fakeCalls.push(['paste', id]); return fakePasteOK; },
    copy: async (id) => { fakeCalls.push(['copy', id]); if (fakeCopyHook) return fakeCopyHook(id); return fakeCopyOK; },
  },
};
document.addEventListener('DOMContentLoaded', () => {
  document.documentElement.lang = 'zh-Hans';
  document.querySelectorAll('[data-i18n]').forEach((el) => el.textContent = tr(el.dataset.i18n));
  document.querySelectorAll('[data-i18n-placeholder]').forEach((el) => el.placeholder = tr(el.dataset.i18nPlaceholder));
});
