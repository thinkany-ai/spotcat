// 翻译服务。每个服务：
//   id / name(ctx) / badge   标识与显示
//   isConfigured(ctx)        是否可用
//   translate(req)           返回译文字符串，失败时 throw
// ctx = { ai }（spotcat.ai.info() 的结果）。新增服务只需往 SERVICES 里加一项。

const { t } = spotcat.i18n;

const SERVICES = [
  {
    id: 'system',
    name: () => t('service.system'),
    badge: { text: '文', color: '#374151' },
    isConfigured: () => true,
    async translate({ text, from, to }) {
      const result = await spotcat.translate({ text, from, to });
      return result.text;
    },
  },
  {
    id: 'google',
    name: () => t('service.google'),
    badge: { text: 'G', color: '#4285F4' },
    isConfigured: () => true,
    async translate({ text, from, to }) {
      const params = new URLSearchParams({
        client: 'gtx', dt: 't',
        sl: from === 'auto' ? 'auto' : Lang.google(from),
        tl: Lang.google(to),
        q: text,
      });
      const res = await spotcat.fetch(`https://translate.googleapis.com/translate_a/single?${params}`, { timeout: 8000 });
      if (res.status !== 200) throw new Error(`HTTP ${res.status}`);
      return JSON.parse(res.body)[0].map((segment) => segment[0]).join('');
    },
  },
  {
    id: 'ai',
    name: (ctx) => (ctx.ai?.configured ? `${t('service.ai')} · ${ctx.ai.model}` : t('service.ai')),
    badge: { text: 'AI', color: '#7C3AED' },
    // 使用 Spotcat 设置里的 AI 服务（manifest 需声明 "ai" 权限）
    isConfigured: (ctx) => Boolean(ctx.ai?.configured),
    async translate({ text, from, to }) {
      const fromPart = from === 'auto' ? '' : ` from ${Lang.ai(from)}`;
      const reply = await spotcat.ai.chat({
        messages: [
          {
            role: 'system',
            content: `You are a professional translation engine. Translate the user's text${fromPart} into ${Lang.ai(to)}. ` +
              'Output only the translation, without explanations, notes or quotes.',
          },
          { role: 'user', content: text },
        ],
      });
      return reply.trim();
    },
  },
];

const DEFAULT_SETTINGS = {
  enabled: { system: true, google: true, ai: true },
  collapsed: {},
  target: 'auto',
};
