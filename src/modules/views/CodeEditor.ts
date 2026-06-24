const SOURCE = `<p align="center">
  <img src="assets/mouse-logo.png" alt="Mouse" />
</p>

<p align="center">
  A mobile-first coding agent platform built
  around a modular, liquid-glass GUI system.
</p>

<p align="center">
  <a href="https://github.com/mouse-app">GitHub</a>
  &nbsp;·&nbsp;
  <a href="#docs">Docs</a>
  &nbsp;·&nbsp;
  <a href="#discord">Discord</a>
</p>

Using opencode agents, Mouse can autonomously
edit, test, and ship code — from your phone.

**New:** First mobile platform to support
multi-agent parallel task execution with
live status streaming via GitHub Codespaces.

## Why I Built Mouse

The problem: developers need to run autonomous
coding agents, but every existing tool is
desktop-first and lacks touch UX.

Mouse brings a fully modular, swipeable panel
system to mobile — so you can manage agents,
review diffs, and ship code from anywhere.

## Features

- Modular resizable panels (swipe to change)
- Multi-agent parallel execution
- Voice-to-bash command translation
- Git changes, graph, and one-tap commit
- GitHub Codespaces terminal integration
- opencode agent backend`

function esc(s: string) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/**
 * Tokenizing HTML/markdown highlighter. Builds spans from the RAW source so it
 * never re-matches its own injected markup (the previous chained-`.replace`
 * approach corrupted itself, leaking `class="tag"` into the output). Each
 * emitted fragment is HTML-escaped exactly once.
 */
function highlightLine(raw: string): string {
  if (raw.trim() === '') return '&nbsp;'

  // Markdown heading
  if (/^#{1,6}\s/.test(raw)) return `<span class="fn">${esc(raw)}</span>`

  // HTML tag line — tokenize attributes/strings without self-corruption.
  if (/^\s*<\/?[a-zA-Z]/.test(raw)) {
    let out = ''
    let i = 0
    while (i < raw.length) {
      const rest = raw.slice(i)
      // Tag open/close: <p  </p  <img  />  >
      let m = rest.match(/^<\/?[a-zA-Z][\w-]*/)
      if (m) { out += `<span class="tag">${esc(m[0])}</span>`; i += m[0].length; continue }
      m = rest.match(/^\/?>/)
      if (m) { out += `<span class="tag">${esc(m[0])}</span>`; i += m[0].length; continue }
      // Attribute name followed by '='
      m = rest.match(/^[a-zA-Z_:][\w:-]*(?==)/)
      if (m) { out += `<span class="attr">${esc(m[0])}</span>`; i += m[0].length; continue }
      // Quoted string value
      m = rest.match(/^"[^"]*"/)
      if (m) { out += `<span class="str">${esc(m[0])}</span>`; i += m[0].length; continue }
      // Anything else: emit one escaped char
      out += esc(raw[i])
      i++
    }
    return out
  }

  // Markdown bold inside plain text
  const e = esc(raw)
  return e.replace(/\*\*([^*]+)\*\*/g, '<span class="kw">$1</span>')
}

export class CodeEditorView {
  el: HTMLElement

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'view-code'

    const hdr = document.createElement('div')
    hdr.className = 'code-file-header'
    hdr.innerHTML = `
      <span style="color:var(--blue)">ℹ</span>
      <span>README.md</span>
      <span style="color:var(--text-faint);margin-left:auto;font-size:10px">gavrielc · just now · Add Mouse logo ar…</span>
    `

    const scroll = document.createElement('div')
    scroll.className = 'code-scroll'

    SOURCE.split('\n').forEach(line => {
      const div = document.createElement('div')
      div.className = 'code-line'
      div.innerHTML = highlightLine(line) || '&nbsp;'
      scroll.appendChild(div)
    })

    this.el.appendChild(hdr)
    this.el.appendChild(scroll)
  }
}
