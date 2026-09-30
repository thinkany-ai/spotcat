// 轻量 Markdown 渲染：代码块、标题、列表、引用、分割线、表格、段落，行内代码/粗体/斜体/链接。
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

  // GFM 表格：表头行 + 分隔行（| --- | :---: |），之后连续的含 | 的行都是表体
  const tableDelimiter = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;
  const isTableStart = (lines, i) =>
    lines[i].includes('|') && i + 1 < lines.length && lines[i + 1].includes('|') && tableDelimiter.test(lines[i + 1]);

  /** 按 | 拆分单元格，忽略行内代码里的 | 和转义的 \| */
  function splitRow(line) {
    let row = line.trim();
    if (row.startsWith('|')) row = row.slice(1);
    if (row.endsWith('|') && !row.endsWith('\\|')) row = row.slice(0, -1);
    const cells = [];
    let cell = '';
    let inCode = false;
    for (let k = 0; k < row.length; k++) {
      const ch = row[k];
      if (ch === '\\' && row[k + 1] === '|') { cell += '|'; k++; continue; }
      if (ch === '`') inCode = !inCode;
      if (ch === '|' && !inCode) { cells.push(cell.trim()); cell = ''; continue; }
      cell += ch;
    }
    cells.push(cell.trim());
    return cells;
  }

  function table(lines, start) {
    const header = splitRow(lines[start]);
    const aligns = splitRow(lines[start + 1]).map((d) =>
      d.startsWith(':') && d.endsWith(':') ? 'center' : d.endsWith(':') ? 'right' : d.startsWith(':') ? 'left' : '');
    const cell = (tag, text, col) =>
      `<${tag}${aligns[col] ? ` style="text-align:${aligns[col]}"` : ''}>${inline(text || '')}</${tag}>`;
    let i = start + 2;
    const rows = [];
    while (i < lines.length && lines[i].trim() && lines[i].includes('|')) rows.push(splitRow(lines[i++]));
    const html = '<div class="table"><table>' +
      `<thead><tr>${header.map((h, c) => cell('th', h, c)).join('')}</tr></thead>` +
      `<tbody>${rows.map((r) => `<tr>${header.map((_, c) => cell('td', r[c], c)).join('')}</tr>`).join('')}</tbody>` +
      '</table></div>';
    return { html, next: i };
  }

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
      } else if (isTableStart(lines, i)) {
        const t = table(lines, i);
        out.push(t.html);
        i = t.next;
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
        while (i < lines.length && lines[i].trim() && !isBlockStart(lines[i]) && !isTableStart(lines, i)) paragraph.push(lines[i++]);
        out.push(`<p>${paragraph.map(inline).join('<br>')}</p>`);
      }
    }
    return out.join('');
  }

  return { render };
})();
