// 轻量 Markdown 渲染：代码块、标题、列表、引用、分割线、段落，行内代码/粗体/斜体/链接。
// 先整体转义 HTML，因此模型输出中的标签不会被执行。流式输出时未闭合的代码块按代码块渲染。
const Markdown = (() => {
  const escape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  function inline(text) {
    const codes = [];
    let s = escape(text).replace(/`([^`\n]+)`/g, (_, code) => `\u0000${codes.push(code) - 1}\u0000`);
    s = s
      .replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[^*\w])\*([^*\n]+)\*(?![*\w])/g, '$1<em>$2</em>')
      .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2">$1</a>');
    return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[i]}</code>`);
  }

  const patterns = {
    fence: /^\s*```\s*([\w+#.-]*)\s*$/,
    heading: /^(#{1,6})\s+(.*)$/,
    ul: /^\s*[-*+]\s+(.*)$/,
    ol: /^\s*\d+[.)]\s+(.*)$/,
    quote: /^>\s?(.*)$/,
    hr: /^\s*(-{3,}|\*{3,}|_{3,})\s*$/,
  };
  const isBlockStart = (line) => Object.values(patterns).some((re) => re.test(line));

  function render(source) {
    const lines = source.replace(/\r\n?/g, '\n').split('\n');
    const out = [];
    let i = 0;

    const collect = (re) => {
      const items = [];
      while (i < lines.length && re.test(lines[i])) items.push(lines[i++].match(re)[1]);
      return items;
    };

    while (i < lines.length) {
      const line = lines[i];
      let m;
      if ((m = line.match(patterns.fence))) {
        const code = [];
        i++;
        while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) code.push(lines[i++]);
        i++;
        out.push(`<pre><code>${escape(code.join('\n'))}</code></pre>`);
      } else if ((m = line.match(patterns.heading))) {
        const level = Math.min(m[1].length + 2, 6);
        out.push(`<h${level}>${inline(m[2])}</h${level}>`);
        i++;
      } else if (patterns.hr.test(line)) {
        out.push('<hr>');
        i++;
      } else if (patterns.ul.test(line)) {
        out.push(`<ul>${collect(patterns.ul).map((t) => `<li>${inline(t)}</li>`).join('')}</ul>`);
      } else if (patterns.ol.test(line)) {
        out.push(`<ol>${collect(patterns.ol).map((t) => `<li>${inline(t)}</li>`).join('')}</ol>`);
      } else if (patterns.quote.test(line)) {
        out.push(`<blockquote>${collect(patterns.quote).map(inline).join('<br>')}</blockquote>`);
      } else if (!line.trim()) {
        i++;
      } else {
        const paragraph = [];
        while (i < lines.length && lines[i].trim() && !isBlockStart(lines[i])) paragraph.push(lines[i++]);
        out.push(`<p>${paragraph.map(inline).join('<br>')}</p>`);
      }
    }
    return out.join('');
  }

  return { render };
})();
