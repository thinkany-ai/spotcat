// 语言表：code 使用 BCP-47（与 spotcat.detectLanguage / spotcat.translate 一致），
// google / ai 为各服务需要的写法。显示名称用 Intl.DisplayNames 按界面语言生成。
const LANGUAGES = [
  { code: 'zh-Hans', google: 'zh-CN', ai: 'Simplified Chinese' },
  { code: 'zh-Hant', google: 'zh-TW', ai: 'Traditional Chinese' },
  { code: 'en', ai: 'English' },
  { code: 'ja', ai: 'Japanese' },
  { code: 'ko', ai: 'Korean' },
  { code: 'fr', ai: 'French' },
  { code: 'de', ai: 'German' },
  { code: 'es', ai: 'Spanish' },
  { code: 'it', ai: 'Italian' },
  { code: 'pt', ai: 'Portuguese' },
  { code: 'ru', ai: 'Russian' },
  { code: 'vi', ai: 'Vietnamese' },
  { code: 'th', ai: 'Thai' },
  { code: 'ar', ai: 'Arabic' },
];

const displayNames = new Intl.DisplayNames([spotcat.i18n.locale], { type: 'language' });

const Lang = {
  find: (code) => LANGUAGES.find((l) => l.code === code),
  name: (code) => {
    try { return displayNames.of(code) || code; } catch { return code; }
  },
  google: (code) => Lang.find(code)?.google ?? code,
  ai: (code) => Lang.find(code)?.ai ?? code,

  /** 把识别结果（如 'zh-Hans'、'en'、'pt-BR'）归一到语言表里的 code */
  normalize(code) {
    if (!code) return null;
    if (Lang.find(code)) return code;
    if (code.startsWith('zh')) return /Hant|TW|HK/.test(code) ? 'zh-Hant' : 'zh-Hans';
    return code.split('-')[0];
  },

  /** 目标语言选「自动」时：中文译成英语，其他译成简体中文 */
  autoTarget: (from) => (from && from.startsWith('zh') ? 'en' : 'zh-Hans'),
};
