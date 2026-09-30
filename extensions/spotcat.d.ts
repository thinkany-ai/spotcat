// Spotcat 扩展页面 API（window.spotcat）类型声明。
// 在扩展的 JS 顶部加 `/// <reference path="../spotcat.d.ts" />` 即可在编辑器里获得补全。

interface SpotcatEnterAction {
  /** manifest 中功能的 code */
  code: string;
  /** keyword：通过关键词进入；match：通过内容匹配进入 */
  type: 'keyword' | 'match';
  /** keyword 时为输入的关键词，match 时为匹配到的内容 */
  payload: string;
}

interface SpotcatChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

interface SpotcatChatOpenOptions {
  /** 聊天标题，省略时用第一条提问 */
  title?: string;
  /** 附带的上下文，会作为系统提示发给模型，并在聊天顶部显示 */
  context?: { title: string; content: string }[];
  /** 预填到输入框的内容 */
  prompt?: string;
  /** 为 true 时直接发送 prompt */
  send?: boolean;
}

interface SpotcatFetchOptions {
  method?: string;
  headers?: Record<string, string>;
  /** 请求体，需自行序列化（如 JSON.stringify） */
  body?: string;
  /** 超时毫秒数，默认 30000 */
  timeout?: number;
}

interface SpotcatFetchResponse {
  status: number;
  /** header 名均为小写 */
  headers: Record<string, string>;
  /** 响应文本（UTF-8） */
  body: string;
}

interface Spotcat {
  /** 进入功能时回调；页面加载后立即触发一次 */
  onEnter(callback: (action: SpotcatEnterAction) => void): void;

  copyText(text: string): Promise<true>;
  /** 隐藏窗口，扩展保持打开（90 秒内再呼出会回到扩展） */
  hideWindow(): Promise<true>;
  /** 退出扩展，回到搜索 */
  exit(): Promise<true>;
  /** 打开 http(s) 网页或 x-apple.systempreferences: 设置页 */
  openURL(url: string): Promise<true>;
  /** 打开 Spotcat 设置窗口，可指定标签页（如引导用户配置 AI：openSettings('ai')） */
  openSettings(tab?: 'general' | 'profile' | 'ai' | 'about'): Promise<true>;

  /** 由 App 代发请求，不受 CORS 限制。需要 manifest 声明 "permissions": ["network"] */
  fetch(url: string, options?: SpotcatFetchOptions): Promise<SpotcatFetchResponse>;

  /** 识别语言，返回 BCP-47 代码（'en'、'zh-Hans'、'ja'…），无法识别时为 null */
  detectLanguage(text: string): Promise<string | null>;
  /** 系统离线翻译（macOS 26+，需要已下载语言包）。from 默认自动识别 */
  translate(request: { text: string; from?: string; to: string }): Promise<{ text: string; from: string; to: string }>;
  /** 朗读文本，lang 省略时自动识别 */
  speak(text: string, lang?: string | null): Promise<true>;
  stopSpeaking(): Promise<true>;

  /** 多语言：locale 为当前界面语言；t 从 locales/<语言>.json 取文案，{name} 为占位符 */
  i18n: {
    locale: string;
    t(key: string, vars?: Record<string, string | number>): string;
    /** 按 data-i18n / data-i18n-placeholder / data-i18n-title 填充文案（页面加载时自动执行一次） */
    apply(root?: ParentNode): void;
  };

  /**
   * 使用 Spotcat 设置中的 AI 服务。需要 manifest 声明 "permissions": ["ai"]。
   * model 为 "服务商 id/模型名"（即 info() 返回的 id），不传或已失效时用默认模型
   */
  ai: {
    info(options?: { model?: string }): Promise<{ configured: boolean; id: string; model: string; provider: string }>;
    /** 返回完整回复；传 onDelta 时流式推送增量，signal 可中止 */
    chat(options: { messages: SpotcatChatMessage[]; model?: string; onDelta?: (delta: string) => void; signal?: AbortSignal }): Promise<string>;
  };

  /** Spotcat 内置的 AI 对话面板。在聊天里按 Esc 或返回按钮回到扩展，扩展状态保留 */
  chat: {
    open(options?: SpotcatChatOpenOptions): Promise<true>;
  };

  /** 扩展私有的持久化存储，值需可 JSON 序列化 */
  storage: {
    get<T = unknown>(key: string): Promise<T | null>;
    set(key: string, value: unknown): Promise<true>;
    remove(key: string): Promise<true>;
  };
}

declare const spotcat: Spotcat;
interface Window { spotcat: Spotcat; }
