// The Conversations message page (DESIGN.md §4.6 "rendering engine", §8.38).
//
// Discipline, in order of importance:
// - Transcript content enters the DOM ONLY via createTextNode — never as
//   markup, never through innerHTML. The page cannot execute or embed
//   anything the transcript says.
// - Core is authoritative: the page draws at the boundaries it receives
//   (UTF-16 offsets pre-converted in Swift). The only layout-derived values
//   are the minimap geometry and hit-line positions, which §4.6 allows.
// - Hit highlighting uses the CSS Custom Highlight API (ranges painted by
//   the engine, zero DOM mutation), so an active selection survives query
//   retyping and a hit crossing a styled run never splits its container
//   (the M39 brief's two spike leftovers). If the API is ever missing the
//   page logs one error through the bridge and degrades to no in-text
//   highlight — counters, minimap hit lines, and jumps still work.
// - Chrome (the label row with its copy button, fold controls, minimap,
//   end marker, scroll shadow) is excluded from selection and copy via
//   user-select: none (§4.6). Labels are generated content, never text
//   nodes, so they also stay out of hits, folds, and textContent.
// - Per-message copy (§4.6): the page only reports WHICH message's button
//   was pressed (its seq); Swift assembles and writes the text, then tells
//   the page to show the check mark and `Copied`.
// - Reload (§4.6 "conversation pane reload"): `update` applies a newer copy
//   of the same conversation. Swift decides how the lists relate (same /
//   appended / replaced); the page only measures where the end marker and
//   the top message sit and places the scroll accordingly. An update whose
//   base the page does not hold asks Swift for a full load instead.
//
// All text in this page is English (repo rule: docs-only Japanese).

let pageTemplate = #"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; script-src 'nonce-__NONCE__'; style-src 'nonce-__NONCE__'">
<style nonce="__NONCE__">
  /* Values below are window-design.html's message-surface CSS at text size
     13 (§8.39: the CSS values are normative for typography and spacing;
     colors follow the system). The text size (§4.5 / §4.6 "text size of the
     conversation pane") arrives as --docsize (the body size) and --k (the
     unitless ratio to 13): every other font size, the copy icon, and every
     vertical margin and padding is its value at 13 times --k. Horizontal
     paddings (the list indent included), radii, borders, the minimap width
     and the top shadow height stay fixed. */
  :root {
    --docsize: 13px;
    --k: 1;
    --text:#1d1d1f; --text2:#6e6e73; --label2:#7c7c82; --line:#d9d9de;
    --card:rgba(127,127,127,.09); --codebg:rgba(127,127,127,.1);
    --hl:rgba(255,213,0,.45); --hlcur:rgba(255,166,0,.75); --sel:#3478f6;
    /* The You label is the system blue (§4.6), resolved by WebKit for the
       view's effective appearance, so it follows light/dark by itself. */
    --you:-apple-system-blue;
    /* The ground of the `Copied` tag (window-design.html --panebg). */
    --panebg:#ffffff;
  }
  @media (prefers-color-scheme: dark) {
    :root { --text:#ededf0; --text2:#9b9ba3; --label2:#a5a5ad; --line:#38383d;
      --card:rgba(255,255,255,.055); --codebg:rgba(255,255,255,.07);
      --hl:rgba(255,213,0,.28); --hlcur:rgba(255,166,0,.55); --panebg:#2b2b2f; }
  }
  /* The app's Appearance override (§4.5) wins in both directions. */
  html[data-theme="light"] { --text:#1d1d1f; --text2:#6e6e73; --label2:#7c7c82; --line:#d9d9de;
    --card:rgba(127,127,127,.09); --codebg:rgba(127,127,127,.1);
    --hl:rgba(255,213,0,.45); --hlcur:rgba(255,166,0,.75); --panebg:#ffffff; }
  html[data-theme="dark"] { --text:#ededf0; --text2:#9b9ba3; --label2:#a5a5ad; --line:#38383d;
    --card:rgba(255,255,255,.055); --codebg:rgba(255,255,255,.07);
    --hl:rgba(255,213,0,.28); --hlcur:rgba(255,166,0,.55); --panebg:#2b2b2f; }

  * { box-sizing: border-box; }
  html, body { margin:0; height:100%; background:transparent; }
  body { color:var(--text); font-size:var(--docsize); line-height:1.7;
    font-family:-apple-system, BlinkMacSystemFont, "SF Pro Text", "Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif; }
  #doc { height:100%; overflow-y:auto; padding:calc(12px * var(--k)) 0 calc(16px * var(--k)); position:relative; }
  /* Focusable (tabindex -1) only so the keyboard scrolls it; no ring. */
  #doc:focus { outline:none; }

  /* Hit highlights: painted ranges, never DOM structure (§8.38). */
  ::highlight(shiibar-hit) { background-color: var(--hl); }
  ::highlight(shiibar-hit-current) { background-color: var(--hlcur); }

  /* One element per message: the label row (.who) + the content. A user
     message (.band) carries the band background over label and text and
     bleeds to the right edge (under the minimap); a Claude message (.ans)
     has no background. The container keeps 18px on the right so code and
     table BACKGROUNDS keep their extent; text elements add 10-14px so text
     wraps 8px short of the 20px minimap (§4.6/§9). */
  .msg { padding:0 18px 0 16px; margin-top:calc(16px * var(--k)); }
  .msg:first-child { margin-top:0; }
  .msg.ans { font-size:var(--docsize); line-height:1.7; max-width:60em; }
  .msg.band { background:var(--card); padding:calc(7px * var(--k)) 18px calc(8px * var(--k)) 16px;
    margin-top:calc(20px * var(--k)); }
  .msg.band:first-child { margin-top:0; }
  .msg.band + .msg { margin-top:calc(10px * var(--k)); }

  /* Label row (§4.6/§8.49). The label is generated content (::before from
     data-label), so it is never a DOM text node: it cannot enter hits, fold
     boundaries, textContent, selection ranges, or WebKit's copy. */
  .who { display:flex; align-items:center; font-size:calc(11px * var(--k)); font-weight:650; line-height:1.6;
    margin-bottom:calc(2px * var(--k)); }
  .who::before { content:attr(data-label); }
  .who.you { color:var(--you); }
  .who.ai { color:var(--label2); }

  /* Per-message copy button (§4.6 "per-message copy"): right end of the
     label row, 14px icon at 13, secondary color; the check mark keeps the same
     position, size, and color. margin-right 10px keeps it inside the
     8px-before-the-minimap line like the text. */
  .cp { flex:none; margin-left:auto; margin-right:10px; padding:calc(2px * var(--k)) 3px; border-radius:5px;
    color:var(--label2); display:flex; border:0; background:transparent; cursor:default;
    font:inherit; line-height:0; position:relative; }
  .cp:hover { background:var(--card); }
  .cp svg { width:calc(14px * var(--k)); height:calc(14px * var(--k)); display:block; fill:none; stroke:currentColor;
    stroke-width:1.3; stroke-linecap:round; stroke-linejoin:round; }
  /* `Copied` next to the check mark (§4.6 "per-message copy", window-design
     .cpd): 4px left of the icon, absolutely placed so the label row keeps
     its height and nothing else moves. The text scales with --k; padding,
     radius, and border stay fixed. The word is generated content, so it is
     never a text node: it cannot enter a selection, a copy, or
     textContent. */
  .cpd { position:absolute; right:calc(100% + 4px); top:50%; transform:translateY(-50%); white-space:nowrap;
    font-size:calc(11px * var(--k)); line-height:1.2; font-weight:400; color:var(--text);
    background:var(--panebg); border:1px solid var(--line); border-radius:4px; padding:3px 6px;
    pointer-events:none; }
  .cpd::before { content:"Copied"; }

  /* User message: shown as typed (no Markdown), regular weight, 13.5px at 13. */
  .mt { font-size:calc(13.5px * var(--k)); line-height:1.6; padding-right:14px; }

  /* Claude message body. */
  .body p, .body h1, .body h2, .body h3, .body h4, .body .li { padding-right:10px; }
  .body p { margin:0 0 calc(8px * var(--k)); }
  .body h1, .body h2, .body h3, .body h4 { margin:calc(10px * var(--k)) 0 calc(8px * var(--k)); line-height:1.35; }
  .body h1 { font-size:calc(19px * var(--k)); }
  .body h2 { font-size:calc(17px * var(--k)); }
  .body h3 { font-size:calc(15px * var(--k)); }
  .body h4 { font-size:calc(14px * var(--k)); }
  .body .li { margin:0 0 calc(3px * var(--k)); }
  pre { margin:0 0 calc(8px * var(--k)); background:var(--codebg); border-radius:8px;
    padding:calc(9px * var(--k)) 12px;
    overflow-x:auto; font-family:"SF Mono", ui-monospace, Menlo, monospace;
    font-size:calc(11.5px * var(--k)); line-height:1.55; }
  /* Inline code with padding + radius (§4.6 — one of the reasons this pane
     is HTML). */
  code { font-family:"SF Mono", ui-monospace, Menlo, monospace; font-size:.88em;
    background:var(--codebg); padding:calc(2px * var(--k)) 5px; border-radius:4px; }
  pre code { background:none; padding:0; font-size:inherit; }
  .b { font-weight:600; } .i { font-style:italic; } .st { text-decoration:line-through; }
  a { color:var(--sel); }

  /* Pipe table: cells wrap at ~28em; only a still-overflowing table scrolls
     inside itself (§4.6). */
  .tbl { border:1px solid var(--line); border-radius:8px; overflow-x:auto;
    margin:0 0 calc(8px * var(--k)); max-width:100%; width:fit-content; }
  .tbl table { border-collapse:collapse; font-size:var(--docsize); line-height:1.5; }
  .tbl th, .tbl td { padding:calc(5px * var(--k)) 12px; text-align:left; border-top:1px solid var(--line);
    vertical-align:top; max-width:28em; overflow-wrap:break-word; white-space:normal; }
  .tbl th { border-top:0; font-weight:600; background:var(--card); }

  .expand { border:0; background:transparent; color:var(--sel); font-size:calc(11px * var(--k));
    cursor:pointer; padding:0; font-family:inherit; display:block;
    margin:calc(2px * var(--k)) 0 calc(8px * var(--k)); }
  .band .expand { margin:calc(2px * var(--k)) 0 0; }
  .expand .cnt { color:var(--text); background:var(--hl); border-radius:4px;
    padding:0 5px; font-size:calc(10px * var(--k)); font-weight:600; }

  /* Chrome is not content: excluded from selection AND copy (§4.6) — the
     label row (label + copy button) and the fold controls. */
  .who, .cp, .cpd, .expand {
    -webkit-user-select:none; user-select:none;
  }

  /* Minimap = the scrollbar (§4.6/§8.39, .mm values from the html mock):
     always-on schematic of the whole conversation, its thumb IS the
     viewport indicator; the OS scrollbar is hidden (no double position
     display). Hit lines land on it while searching. Chrome: unselectable. */
  #doc::-webkit-scrollbar { display:none; }
  #mm { position:fixed; top:0; bottom:0; right:0; width:20px;
    -webkit-user-select:none; user-select:none; cursor:default; }
  #mm .m { position:absolute; left:4px; right:4px; border-radius:1px; }
  #mm .band { background:rgba(127,127,127,.34); }
  #mm .txt { background:rgba(127,127,127,.16); }
  #mm .codeb { background:rgba(127,127,127,.24); }
  #mm .hit { position:absolute; left:2px; right:2px; height:2px; background:var(--hl); }
  #mm .hit.cur { background:var(--hlcur); }
  #mm .thumb { position:absolute; left:0; right:0; border-radius:5px; background:rgba(127,127,127,.22); }
  #mm:hover .thumb, #mm.dragging .thumb { background:rgba(127,127,127,.38); }

  /* Bottom cues (§4.6/§8.39): the end marker after the last message, and a
     top scroll shadow while content extends above. Both are chrome. */
  .endcap { display:flex; align-items:center; gap:10px; color:var(--label2); font-size:calc(11px * var(--k));
    margin:calc(14px * var(--k)) 16px calc(4px * var(--k)); -webkit-user-select:none; user-select:none; }
  .endcap::before, .endcap::after { content:""; flex:1; height:1px; background:var(--line); }
  #topshadow { position:fixed; top:0; left:0; right:20px; height:8px; opacity:0;
    pointer-events:none; background:linear-gradient(to bottom, rgba(0,0,0,.12), transparent);
    -webkit-user-select:none; user-select:none; }
</style>
</head>
<body>
<div id="doc" tabindex="-1"></div>
<div id="mm"></div>
<div id="topshadow"></div>
<script nonce="__NONCE__">
'use strict';
const S = {
  msgs: [],            // load payload messages
  hits: [],            // {m, s, l, hidden} in UTF-16 message coordinates
  cur: -1,             // current hit index
  expanded: new Set(), // message indexes expanded past the fold
  nodeMaps: [],        // per message: [{node, start, end}] in message coords
  msgEls: [],          // per message: container element
  ranges: [],          // per hit: resolved Range or null (behind the fold)
  copied: new Map(),   // message seq -> timer of its check-mark feedback
  gen: 0,              // delivery generation of the content on the page
  hasSelection: false,
  warnedNoHighlight: false,
};
const doc = document.getElementById('doc');
const mm = document.getElementById('mm');
const topShadow = document.getElementById('topshadow');
const post = m => window.webkit.messageHandlers.shiibar.postMessage(m);

// Keyboard scrolling (DESIGN.md §4.5 "key operations": ↑ / ↓, Space and
// Page Up / Page Down scroll the conversation on the one-column detail
// page). WebKit scrolls the focused element's scroller; with nothing
// focused it tries the document, which never scrolls here (#doc is the
// scroller). So a key that arrives with nothing focused focuses #doc first
// (no scroll, no selection change) and WebKit's default handling of the
// same key scrolls it.
document.addEventListener('keydown', () => {
  const active = document.activeElement;
  if (!active || active === document.body || active === document.documentElement) {
    doc.focus({ preventScroll: true });
  }
}, true);

// Silent breakage is forbidden: everything unexpected goes to the native log.
window.onerror = (message, source, line) => {
  post({ type: 'error', message: String(message) + ' @line ' + line });
};
window.addEventListener('unhandledrejection', e => {
  post({ type: 'error', message: 'unhandled rejection: ' + String(e.reason) });
});

// ---- DOM building (content via createTextNode only) ----

function addText(parent, mi, text, start) {
  if (!text) return;
  const node = document.createTextNode(text);
  parent.appendChild(node);
  S.nodeMaps[mi].push({ node, start, end: start + text.length });
}

// Styled inline runs; no hit segmentation here — highlights are ranges.
function appendStyled(parent, mi, text, runs, base) {
  let pos = 0;
  for (const r of (runs || [])) {
    if (r.s >= text.length) break;
    if (r.s > pos) addText(parent, mi, text.slice(pos, r.s), base + pos);
    const end = Math.min(r.s + r.l, text.length);
    let w;
    if (r.code) w = document.createElement('code');
    else if (r.href) { w = document.createElement('a'); w.href = r.href; }
    else w = document.createElement('span');
    if (r.bold) w.classList.add('b');
    if (r.italic) w.classList.add('i');
    if (r.strike) w.classList.add('st');
    addText(w, mi, text.slice(Math.max(r.s, pos), end), base + Math.max(r.s, pos));
    parent.appendChild(w);
    pos = end;
  }
  if (pos < text.length) addText(parent, mi, text.slice(pos), base + pos);
}

function buildBlock(blk, mi, folded) {
  if (blk.kind === 'table') {
    if (folded && blk.foldedLen === 0) return null;
    const wrap = document.createElement('div'); wrap.className = 'tbl';
    const table = document.createElement('table');
    blk.rows.forEach((row, ri) => {
      const cells = row.filter(c => !folded || c.foldedLen > 0);
      if (!cells.length) return;
      const tr = document.createElement('tr');
      cells.forEach(c => {
        const td = document.createElement(ri === 0 ? 'th' : 'td');
        const vis = folded ? c.foldedLen : c.text.length;
        appendStyled(td, mi, c.text.slice(0, vis), c.runs, c.start);
        tr.appendChild(td);
      });
      table.appendChild(tr);
    });
    wrap.appendChild(table);
    return wrap;
  }
  const vis = folded ? blk.foldedLen : blk.text.length;
  if (vis <= 0 && blk.text.length > 0) return null;
  const text = blk.text.slice(0, vis);
  if (blk.kind === 'code') {
    const pre = document.createElement('pre');
    addText(pre, mi, text, blk.start);
    return pre;
  }
  if (blk.kind === 'h') {
    const h = document.createElement('h' + Math.min(4, blk.level || 1));
    appendStyled(h, mi, text, blk.runs, blk.start);
    return h;
  }
  const p = document.createElement('p');
  if (blk.kind === 'li') { p.className = 'li'; p.style.paddingLeft = ((blk.indent || 0) * 14) + 'px'; }
  appendStyled(p, mi, text, blk.runs, blk.start);
  return p;
}

function expandControl(mi, msg) {
  const folded = !S.expanded.has(mi);
  const btn = document.createElement('button');
  btn.className = 'expand';
  if (folded) {
    btn.appendChild(document.createTextNode('Show full message'));
    // Badge count = Core's hidden flags; the page never recomputes it.
    const hidden = S.hits.filter(h => h.m === mi && h.hidden).length;
    if (hidden) {
      btn.appendChild(document.createTextNode(' '));
      const cnt = document.createElement('span'); cnt.className = 'cnt';
      cnt.textContent = hidden + (hidden === 1 ? ' match' : ' matches');
      btn.appendChild(cnt);
    }
    btn.onclick = () => { S.expanded.add(mi); rebuildMessage(mi); };
  } else {
    btn.textContent = 'Show less';
    btn.onclick = () => {
      S.expanded.delete(mi);
      rebuildMessage(mi);
      // Re-folding must not throw the viewpoint off this message (§4.6).
      const el = S.msgEls[mi];
      if (el) el.scrollIntoView({ block: 'nearest' });
    };
  }
  return btn;
}

// Icons are fixed page geometry (window-design.html's i-copy / i-check
// symbols), never transcript content.
const SVG_NS = 'http://www.w3.org/2000/svg';
const ICONS = {
  copy: ['M5.5 7a1.5 1.5 0 0 1 1.5-1.5h5A1.5 1.5 0 0 1 13.5 7v5a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 12z',
         'M10.5 5.5V4a1.5 1.5 0 0 0-1.5-1.5H4A1.5 1.5 0 0 0 2.5 4v5A1.5 1.5 0 0 0 4 10.5h1.5'],
  check: ['M3.5 8.5l3 3 6-7'],
};

function setCopyIcon(btn, done) {
  btn.textContent = '';
  btn.dataset.state = done ? 'done' : 'idle';
  if (done) {
    const tag = document.createElement('span');
    tag.className = 'cpd';
    btn.appendChild(tag);
  }
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 16 16');
  for (const d of ICONS[done ? 'check' : 'copy']) {
    const path = document.createElementNS(SVG_NS, 'path');
    path.setAttribute('d', d);
    svg.appendChild(path);
  }
  btn.appendChild(svg);
}

// The label row: generated-content label + the per-message copy button.
function labelRow(msg) {
  const row = document.createElement('div');
  const isUser = msg.role === 'user';
  row.className = 'who ' + (isUser ? 'you' : 'ai');
  row.dataset.label = isUser ? 'You' : 'Claude';
  const btn = document.createElement('button');
  btn.className = 'cp';
  btn.title = 'Copy';
  btn.dataset.seq = msg.seq;
  setCopyIcon(btn, S.copied.has(msg.seq));
  // Pressing the button must leave the selection alone (§4.6): no focus
  // move, no selection change on mousedown.
  btn.addEventListener('mousedown', e => e.preventDefault());
  btn.addEventListener('click', e => {
    e.preventDefault();
    e.stopPropagation();
    post({ type: 'copyMessage', seq: msg.seq });
  });
  row.appendChild(btn);
  return row;
}

// One message's element: label row + content (+ fold control). Registers
// its text nodes into nodeMaps[mi]; the label row registers none.
function buildMessage(msg, mi) {
  S.nodeMaps[mi] = [];
  const folded = msg.folds && !S.expanded.has(mi);
  const holder = document.createElement('div');
  holder.dataset.mi = mi; holder.dataset.seq = msg.seq;
  holder.appendChild(labelRow(msg));
  if (msg.role === 'user') {
    holder.className = 'msg band';
    const mt = document.createElement('div'); mt.className = 'mt';
    const blk = msg.blocks[0];
    if (blk) {
      const vis = folded ? blk.foldedLen : blk.text.length;
      addText(mt, mi, blk.text.slice(0, vis), blk.start);
    }
    holder.appendChild(mt);
    if (msg.folds) holder.appendChild(expandControl(mi, msg));
  } else {
    holder.className = 'msg ans';
    const body = document.createElement('div'); body.className = 'body';
    msg.blocks.forEach(blk => {
      const el = buildBlock(blk, mi, folded);
      if (el) body.appendChild(el);
    });
    if (msg.folds) body.appendChild(expandControl(mi, msg));
    holder.appendChild(body);
  }
  return holder;
}

// Copy feedback after Swift wrote the copy (§4.6/§9): the check mark (same
// position, size, and color) and `Copied`; both revert after `ms`, counted
// from the latest press. Survives a rebuild of the message (fold toggles)
// and an appending update because the state lives in S.copied, keyed by
// seq.
function markCopied(seq, ms) {
  const prev = S.copied.get(seq);
  if (prev) clearTimeout(prev);
  const timer = setTimeout(() => {
    S.copied.delete(seq);
    doc.querySelectorAll('.cp[data-seq="' + seq + '"]').forEach(b => setCopyIcon(b, false));
  }, ms);
  S.copied.set(seq, timer);
  doc.querySelectorAll('.cp[data-seq="' + seq + '"]').forEach(b => setCopyIcon(b, true));
}

function render() {
  S.nodeMaps = []; S.msgEls = [];
  doc.textContent = '';
  S.msgs.forEach((msg, mi) => {
    const el = buildMessage(msg, mi);
    doc.appendChild(el);
    S.msgEls[mi] = el;
  });
  appendEndMarker();
  applyHighlights();
  rebuildMinimap();
}

// End marker (§4.6/§8.39): chrome, not content — no node-map entry, so it
// can never enter hits, selection ranges, or copies.
function endMarkerText() {
  return S.elapsed ? 'Latest message \u00B7 ' + S.elapsed + ' ago' : 'Latest message';
}

function appendEndMarker() {
  if (!S.msgs.length) return;
  const cap = document.createElement('div');
  cap.className = 'endcap';
  cap.textContent = endMarkerText();
  doc.appendChild(cap);
}

// Whether any part of the end marker is inside the viewport (§4.6
// "conversation pane reload": reading the end follows the new end).
function endMarkerInView() {
  const cap = doc.querySelector('.endcap');
  if (!cap) return false;
  const top = contentY(cap);
  const bottom = top + cap.offsetHeight;
  return top < doc.scrollTop + doc.clientHeight && bottom > doc.scrollTop;
}

// The message at the top of the viewport (the same rule as the scroll
// memory's anchor): its index and its offset from the viewport top.
function topMessage() {
  for (let mi = 0; mi < S.msgEls.length; mi++) {
    const el = S.msgEls[mi];
    if (!el) continue;
    const y = contentY(el);
    if (y + el.offsetHeight > doc.scrollTop) return { mi, offset: y - doc.scrollTop };
  }
  return null;
}

// Expansion toggles rebuild ONE message in place; other messages' nodes —
// and any selection over them — stay untouched.
function rebuildMessage(mi) {
  const fresh = buildMessage(S.msgs[mi], mi);
  doc.replaceChild(fresh, S.msgEls[mi]);
  S.msgEls[mi] = fresh;
  applyHighlights();
  rebuildMinimap();
}

// ---- Highlights: ranges over existing nodes, zero DOM mutation ----

function resolveRange(mi, s, l) {
  const map = S.nodeMaps[mi];
  if (!map) return null;
  let startNode = null, startOffset = 0, endNode = null, endOffset = 0;
  for (const e of map) {
    if (!startNode && s >= e.start && s < e.end) { startNode = e.node; startOffset = s - e.start; }
    if (s + l > e.start && s + l <= e.end) { endNode = e.node; endOffset = s + l - e.start; }
  }
  if (!startNode || !endNode) return null; // behind the fold
  const range = document.createRange();
  range.setStart(startNode, startOffset);
  range.setEnd(endNode, endOffset);
  return range;
}

function applyHighlights() {
  S.ranges = [];
  if (typeof Highlight === 'undefined' || !('highlights' in CSS)) {
    if (!S.warnedNoHighlight) {
      S.warnedNoHighlight = true;
      post({ type: 'error', message: 'CSS Custom Highlight API unavailable; in-text highlights disabled' });
    }
    return;
  }
  const base = new Highlight();
  const current = new Highlight();
  S.hits.forEach((h, i) => {
    const r = resolveRange(h.m, h.s, h.l);
    S.ranges[i] = r;
    if (!r) return;
    (i === S.cur ? current : base).add(r);
  });
  CSS.highlights.set('shiibar-hit', base);
  CSS.highlights.set('shiibar-hit-current', current);
}

// ---- Minimap = scrollbar (§4.6/§8.39): a schematic of the block
// structure at real layout offsets — rectangles only, no scaled text —
// rebuilt on load/expand/fold/zoom/resize; the thumb and shadow update on
// every scroll (cheap). Hit lines replace the old tick overlay. ----

function contentY(el) {
  return el.getBoundingClientRect().top - doc.getBoundingClientRect().top + doc.scrollTop;
}

function rebuildMinimap() {
  mm.textContent = '';
  const scrollHeight = Math.max(1, doc.scrollHeight);
  const mapHeight = mm.clientHeight;
  const put = (cls, y, h) => {
    const seg = document.createElement('div');
    seg.className = 'm ' + cls;
    seg.style.top = (y / scrollHeight * mapHeight) + 'px';
    seg.style.height = Math.max(2, h / scrollHeight * mapHeight) + 'px';
    mm.appendChild(seg);
  };
  S.msgEls.forEach((holder, mi) => {
    if (!holder || !S.msgs[mi]) return;
    if (S.msgs[mi].role === 'user') {
      // The whole band (label row included) is the stripe.
      put('band', contentY(holder), holder.offsetHeight);
      return;
    }
    const body = holder.querySelector('.body');
    if (!body) return;
    for (const child of body.children) {
      if (child.classList.contains('expand')) continue;
      const kind = (child.tagName === 'PRE' || child.classList.contains('tbl')) ? 'codeb' : 'txt';
      put(kind, contentY(child), child.offsetHeight);
    }
  });
  drawMinimapHits();
  const thumb = document.createElement('div');
  thumb.className = 'thumb';
  thumb.id = 'mmthumb';
  mm.appendChild(thumb);
  updateViewportCues();
}

// Hit lines on the minimap (§4.6: distribution + current position live on
// the minimap now). Redrawable without a full rebuild.
function drawMinimapHits() {
  mm.querySelectorAll('.hit').forEach(el => el.remove());
  if (!S.hits.length) return;
  const scrollHeight = Math.max(1, doc.scrollHeight);
  const mapHeight = mm.clientHeight;
  const thumb = document.getElementById('mmthumb');
  S.hits.forEach((h, i) => {
    let y = 0;
    const r = S.ranges[i];
    if (r) y = r.getBoundingClientRect().top - doc.getBoundingClientRect().top + doc.scrollTop;
    else if (S.msgEls[h.m]) y = contentY(S.msgEls[h.m]);
    const line = document.createElement('div');
    line.className = 'hit' + (i === S.cur ? ' cur' : '');
    line.style.top = (y / scrollHeight * mapHeight) + 'px';
    mm.insertBefore(line, thumb);
  });
}

// Thumb (the viewport indicator) and the top scroll shadow: per scroll.
function updateViewportCues() {
  const thumb = document.getElementById('mmthumb');
  if (thumb) {
    const scrollHeight = Math.max(1, doc.scrollHeight);
    const mapHeight = mm.clientHeight;
    thumb.style.top = (doc.scrollTop / scrollHeight * mapHeight) + 'px';
    thumb.style.height = Math.max(20, doc.clientHeight / scrollHeight * mapHeight) + 'px';
  }
  topShadow.style.opacity = Math.min(doc.scrollTop / 24, 1);
}

// Drag the thumb to scroll; click the track to jump there (§4.6).
let minimapDrag = null;
mm.addEventListener('mousedown', e => {
  e.preventDefault();
  const thumb = document.getElementById('mmthumb');
  const scrollHeight = Math.max(1, doc.scrollHeight);
  const mapHeight = Math.max(1, mm.clientHeight);
  if (thumb) {
    const rect = thumb.getBoundingClientRect();
    if (e.clientY < rect.top || e.clientY > rect.bottom) {
      // Track click: center the viewport on the clicked position.
      const fraction = (e.clientY - mm.getBoundingClientRect().top) / mapHeight;
      doc.scrollTop = fraction * scrollHeight - doc.clientHeight / 2;
    }
  }
  mm.classList.add('dragging');
  minimapDrag = { y: e.clientY, scroll: doc.scrollTop };
});
window.addEventListener('mousemove', e => {
  if (!minimapDrag) return;
  const scale = Math.max(1, doc.scrollHeight) / Math.max(1, mm.clientHeight);
  doc.scrollTop = minimapDrag.scroll + (e.clientY - minimapDrag.y) * scale;
});
window.addEventListener('mouseup', () => {
  minimapDrag = null;
  mm.classList.remove('dragging');
});

// ---- Copy support (§4.6 "selection and copy") ----

// The selection as rendered-text ranges, one entry per touched message:
// {m, s, l} in UTF-16 message coordinates. Chrome text (labels, buttons)
// is not in the node maps, so it can never enter a range. Native converts
// to Character offsets and serializes via Core (§8.38).
function selectionRanges() {
  const sel = getSelection();
  if (!sel || sel.isCollapsed || !sel.rangeCount) return [];
  const range = sel.getRangeAt(0);
  const out = [];
  S.nodeMaps.forEach((map, mi) => {
    let lo = Infinity, hi = -Infinity;
    for (const e of map) {
      if (!range.intersectsNode(e.node)) continue;
      const from = range.startContainer === e.node ? range.startOffset : 0;
      const to = range.endContainer === e.node ? range.endOffset : e.node.data.length;
      lo = Math.min(lo, e.start + from);
      hi = Math.max(hi, e.start + to);
    }
    if (lo < hi) out.push({ m: mi, s: lo, l: hi - lo });
  });
  return out;
}


document.addEventListener('selectionchange', () => {
  const has = !getSelection().isCollapsed;
  if (has !== S.hasSelection) {
    S.hasSelection = has;
    post({ type: 'selection', has });
  }
});

// ---- Scroll memory (§4.6: per conversation, message granularity) ----

let anchorTimer = null;
doc.addEventListener('scroll', () => {
  updateViewportCues();
  if (anchorTimer) return;
  anchorTimer = setTimeout(() => {
    anchorTimer = null;
    const top = doc.scrollTop;
    const docTop = doc.getBoundingClientRect().top;
    for (const el of S.msgEls) {
      if (!el) continue;
      const y = el.getBoundingClientRect().top - docTop + doc.scrollTop;
      if (y + el.offsetHeight > top) {
        post({ type: 'anchor', seq: Number(el.dataset.seq) });
        return;
      }
    }
  }, 300);
});

// ---- Native API ----

window.shiibarAPI = {
  // `gen` is the delivery generation (§8.38(7)): echoed in the rendered
  // ack so the native side can verify the newest payload actually rendered
  // and re-inject once if it was lost.
  load(payload, anchorSeq, gen) {
    const t0 = performance.now();
    S.gen = gen || 0;
    S.msgs = payload.messages;
    S.elapsed = payload.elapsed || null;
    S.hits = []; S.cur = -1; S.expanded = new Set();
    S.copied.forEach(t => clearTimeout(t)); S.copied = new Map();
    render();
    void doc.scrollHeight; // force layout before positioning
    const anchorEl = anchorSeq === null ? null : doc.querySelector('[data-seq="' + anchorSeq + '"]');
    if (anchorEl) {
      // The remembered message wins over the initial position (§4.6).
      doc.scrollTop = anchorEl.getBoundingClientRect().top - doc.getBoundingClientRect().top + doc.scrollTop;
    } else {
      doc.scrollTop = doc.scrollHeight; // bottom = latest (§4.6)
    }
    postRendered(t0, gen);
  },
  // A reload of the same conversation (§4.6 "conversation pane reload").
  // `mode` is Swift's decision: 'same' (only the end marker's elapsed time
  // changes), 'append' (messages from index `from` are new; the existing
  // elements, the selection, the expansions, and the copy feedback stay),
  // or 'replace' (render again; `keep` pairs [old index, new index] of the
  // messages that stayed the same). `gen` / `baseGen` are delivery
  // generations (§8.38(7)): a repeated delivery only acks again, and an
  // update whose base is not the content on the page (a lost delivery, a
  // reloaded page) is not applied: the page reports where the reader is
  // and Swift sends a full load of the latest content at that position.
  update(payload, mode, from, keep, gen, baseGen) {
    const t0 = performance.now();
    if (gen <= S.gen) { postRendered(t0, gen); return; }
    if (S.gen !== baseGen || (mode === 'append' && from !== S.msgEls.length)) {
      S.copied.forEach(t => clearTimeout(t)); S.copied = new Map();
      const atEnd = endMarkerInView();
      const top = atEnd ? null : topMessage();
      post({
        type: 'needsLoad', gen, hasContent: S.msgEls.length > 0, atEnd,
        anchor: top ? Number(S.msgEls[top.mi].dataset.seq) : null,
      });
      return;
    }
    // Measured right before the update is applied (§4.6). Unchanged
    // messages never move the scroll, wherever the end marker is.
    const followEnd = mode !== 'same' && endMarkerInView();
    S.elapsed = payload.elapsed || null;
    if (mode === 'same') {
      S.msgs = payload.messages;
      const cap = doc.querySelector('.endcap');
      if (cap) cap.textContent = endMarkerText();
    } else if (mode === 'append') {
      const cap = doc.querySelector('.endcap');
      if (cap) cap.remove();
      S.msgs = payload.messages;
      for (let mi = from; mi < S.msgs.length; mi++) {
        const el = buildMessage(S.msgs[mi], mi);
        doc.appendChild(el);
        S.msgEls[mi] = el;
      }
      appendEndMarker();
      applyHighlights();
      rebuildMinimap();
    } else {
      const top = followEnd ? null : topMessage();
      const kept = new Map(keep);
      const target = top && kept.has(top.mi) ? { mi: kept.get(top.mi), offset: top.offset } : null;
      S.msgs = payload.messages;
      S.hits = []; S.cur = -1; S.expanded = new Set();
      render();
      void doc.scrollHeight; // force layout before positioning
      if (!followEnd) {
        const el = target ? S.msgEls[target.mi] : null;
        // The top message stays where it was; gone, the view goes to the end.
        doc.scrollTop = el ? contentY(el) - target.offset : doc.scrollHeight;
      }
    }
    if (followEnd) {
      void doc.scrollHeight;
      doc.scrollTop = doc.scrollHeight;
    }
    S.gen = gen;
    updateViewportCues();
    postRendered(t0, gen);
  },
  // Query retyping: highlights and badges change, the DOM and the scroll do
  // not (§4.6 + the selection-survival rule). Fold controls are the one
  // DOM-touching exception: their badge counts are rebuilt in place.
  setHits(hits, cur) {
    const t0 = performance.now();
    S.hits = hits; S.cur = cur;
    applyHighlights();
    refreshFoldControls();
    drawMinimapHits();
    post({ type: 'hitsApplied', ms: performance.now() - t0 });
  },
  jump(idx) {
    S.cur = idx;
    const h = S.hits[idx];
    if (h && h.hidden && !S.expanded.has(h.m)) {
      S.expanded.add(h.m);
      rebuildMessage(h.m);
    } else {
      applyHighlights();
      drawMinimapHits();
    }
    const r = S.ranges[idx];
    if (r) {
      const rect = r.getBoundingClientRect();
      const docRect = doc.getBoundingClientRect();
      doc.scrollTop += rect.top - docRect.top - doc.clientHeight / 2;
      updateViewportCues();
    }
  },
  // The body size in px and its unitless ratio to 13 travel together, so
  // the page never divides a length by a length.
  setSize(px, k) {
    document.documentElement.style.setProperty('--docsize', px + 'px');
    document.documentElement.style.setProperty('--k', String(k));
    rebuildMinimap();
  },
  setTheme(dark) {
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  },
  markCopied,
  selectionRanges,
  hasSelection() { return S.hasSelection; },
};

// The rendered ack of a load or an update (§8.38(7)), with the geometry for
// the blank-pane field diagnosis (§8.38(8)): a render into a zero-size
// viewport is the prime suspect.
function postRendered(t0, gen) {
  post({
    type: 'rendered', ms: performance.now() - t0, messages: S.msgs.length, gen: gen || 0,
    docH: doc.scrollHeight, vw: window.innerWidth, vh: window.innerHeight,
  });
}

// Badge counts live on fold buttons; refresh them without touching message
// content nodes (keeps selections alive).
function refreshFoldControls() {
  S.msgs.forEach((msg, mi) => {
    if (!msg.folds) return;
    const holder = S.msgEls[mi];
    if (!holder) return;
    const old = holder.querySelector('.expand');
    if (!old) return;
    const fresh = expandControl(mi, msg);
    old.replaceWith(fresh);
  });
}

new ResizeObserver(() => rebuildMinimap()).observe(doc);

post({ type: 'ready' });
</script>
</body>
</html>
"""#
