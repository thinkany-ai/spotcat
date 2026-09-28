import Foundation

/// 注入到页面的 window.spotcat。API 说明见 extensions/README.md 与 extensions/spotcat.d.ts
enum SpotcatRuntime {
    static func script(context: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: context)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (() => {
          const ctx = \(json);
          const call = (method, args) =>
            window.webkit.messageHandlers.spotcat.postMessage({ method, args: args || {} });

          // ---- 原生推送的事件 ----
          const aiStreams = new Map();
          let seq = 0;
          Object.defineProperty(window, '__spotcatEvent', {
            value(name, payload) {
              if (name === 'ai.delta') aiStreams.get(payload.id)?.(payload.delta);
            },
          });

          // ---- 多语言 ----
          const locale = ctx.i18n?.locale || 'en';
          const messages = ctx.i18n?.messages || {};
          const t = (key, vars) => {
            const text = messages[key] ?? key;
            return vars ? text.replace(/\\{(\\w+)\\}/g, (m, k) => (k in vars ? String(vars[k]) : m)) : text;
          };
          const apply = (root = document) => {
            root.querySelectorAll('[data-i18n]').forEach((el) => (el.textContent = t(el.dataset.i18n)));
            root.querySelectorAll('[data-i18n-placeholder]').forEach((el) => (el.placeholder = t(el.dataset.i18nPlaceholder)));
            root.querySelectorAll('[data-i18n-title]').forEach((el) => (el.title = t(el.dataset.i18nTitle)));
          };
          document.addEventListener('DOMContentLoaded', () => {
            document.documentElement.lang = locale;
            apply();
          });

          window.spotcat = Object.freeze({
            onEnter(cb) { if (ctx.enter) cb(ctx.enter); },

            copyText: (text) => call('copyText', { text: String(text) }),
            hideWindow: () => call('hideWindow'),
            exit: () => call('exit'),
            openURL: (url) => call('openURL', { url: String(url) }),
            openSettings: (tab) => call('openSettings', { tab }),

            fetch: (url, o = {}) =>
              call('fetch', { url: String(url), method: o.method, headers: o.headers, body: o.body, timeout: o.timeout }),

            detectLanguage: (text) => call('detectLanguage', { text: String(text) }),
            translate: ({ text, from, to }) => call('translate', { text: String(text), from: from || 'auto', to }),
            speak: (text, lang) => call('speak', { text: String(text), lang }),
            stopSpeaking: () => call('stopSpeaking'),

            storage: Object.freeze({
              get: (key) => call('storage.get', { key }),
              set: (key, value) => call('storage.set', { key, value }),
              remove: (key) => call('storage.remove', { key }),
            }),

            i18n: Object.freeze({ locale, t, apply }),

            ai: Object.freeze({
              info: () => call('ai.info'),
              chat({ messages, onDelta, signal } = {}) {
                const id = ++seq;
                if (signal?.aborted) return Promise.reject(new DOMException('Aborted', 'AbortError'));
                if (onDelta) aiStreams.set(id, onDelta);
                signal?.addEventListener('abort', () => call('ai.cancel', { id }), { once: true });
                return call('ai.chat', { id, messages, stream: Boolean(onDelta) }).finally(() => aiStreams.delete(id));
              },
            }),

            chat: Object.freeze({
              open: (o = {}) => call('chat.open', { title: o.title, context: o.context, prompt: o.prompt, send: o.send }),
            }),
          });
        })();
        """
    }
}
