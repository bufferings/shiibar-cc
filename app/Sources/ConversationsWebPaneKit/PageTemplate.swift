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
// - Chrome (the prompt glyph, the reply marker, fold controls, minimap,
//   end marker, scroll shadow) is
//   excluded from selection and copy via user-select: none (§4.6).
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
  :root {
    --docsize: 13px;
    --text:#1d1d1f; --text2:#6e6e73; --line:#d9d9de;
    --card:rgba(127,127,127,.09); --codebg:rgba(127,127,127,.1);
    --hl:rgba(255,213,0,.45); --hlcur:rgba(255,166,0,.75); --sel:#3478f6;
  }
  @media (prefers-color-scheme: dark) {
    :root { --text:#ededf0; --text2:#9b9ba3; --line:#38383d;
      --card:rgba(255,255,255,.055); --codebg:rgba(255,255,255,.07);
      --hl:rgba(255,213,0,.28); --hlcur:rgba(255,166,0,.55); }
  }
  /* The app's Appearance override (§4.5) wins in both directions. */
  html[data-theme="light"] { --text:#1d1d1f; --text2:#6e6e73; --line:#d9d9de;
    --card:rgba(127,127,127,.09); --codebg:rgba(127,127,127,.1);
    --hl:rgba(255,213,0,.45); --hlcur:rgba(255,166,0,.75); }
  html[data-theme="dark"] { --text:#ededf0; --text2:#9b9ba3; --line:#38383d;
    --card:rgba(255,255,255,.055); --codebg:rgba(255,255,255,.07);
    --hl:rgba(255,213,0,.28); --hlcur:rgba(255,166,0,.55); }

  * { box-sizing: border-box; }
  html, body { margin:0; height:100%; background:transparent; }
  body { color:var(--text); font-size:var(--docsize); line-height:1.7;
    font-family:-apple-system, BlinkMacSystemFont, "SF Pro Text", "Hiragino Sans", sans-serif; }
  #doc { height:100%; overflow-y:auto; padding:12px 0 16px; position:relative; }

  /* Hit highlights: painted ranges, never DOM structure (§8.38). */
  ::highlight(shiibar-hit) { background-color: var(--hl); }
  ::highlight(shiibar-hit-current) { background-color: var(--hlcur); }

  /* User band: full width, glyph column shared with the reply marker.
     The 22px section gap (html .prompt margin-top) lives on the holder —
     in this DOM each band is the first child of its own holder, so the
     mock's .prompt:first-child rule would zero the gap on every band
     (§8.39 audit finding). */
  .user-holder { margin-top:22px; }
  .user-holder:first-child { margin-top:0; }
  .prompt { display:flex; gap:9px; font-size:calc(var(--docsize) + .5px); line-height:1.6;
    padding:7px 28px 7px 16px; background:var(--card); } /* text clears the minimap by 8px (§9); the band bg still bleeds to the edge */
  .prompt .g { flex:none; width:12.5px; text-align:center; font-weight:600;
    font-family:"SF Mono", ui-monospace, Menlo, monospace; }

  /* Claude message: hanging reply marker + body column, 60em measure.
     Values are conversations-design.html's .ans (§8.39: the CSS is the
     single source of truth): 10px top padding is the band-to-first-reply
     gap. */
  .msg { display:flex; gap:9px; padding:10px 18px 0 16px; max-width:60em; }
  .msg .dot { flex:none; width:12.5px; text-align:center; color:var(--text2);
    font-size:calc(var(--docsize) / 13 * 9); line-height:2.4; }
  .msg .body { flex:1; min-width:0; }
  /* Text wraps 8px short of the 20px minimap (28px total inset, §9). The
     .msg container keeps its 18px so code/table BACKGROUNDS keep their
     extent (§4.6: only the text column narrows). */
  .body p, .body h1, .body h2, .body h3, .body h4, .body .li { padding-right:10px; }
  .body p { margin:0 0 8px; }
  .body h1, .body h2, .body h3, .body h4 { margin:10px 0 8px; line-height:1.35; }
  .body h1 { font-size:calc(var(--docsize) + 6px); }
  .body h2 { font-size:calc(var(--docsize) + 4px); }
  .body h3 { font-size:calc(var(--docsize) + 2px); }
  .body h4 { font-size:calc(var(--docsize) + 1px); }
  .body .li { margin:0 0 3px; }
  pre { margin:0 0 8px; background:var(--codebg); border-radius:8px; padding:9px 12px;
    overflow-x:auto; font-family:"SF Mono", ui-monospace, Menlo, monospace;
    font-size:calc(var(--docsize) - 1.5px); line-height:1.55; }
  /* Inline code with padding + radius (§4.6 — one of the reasons this pane
     is HTML). */
  code { font-family:"SF Mono", ui-monospace, Menlo, monospace; font-size:.9em;
    background:var(--codebg); padding:2px 5px; border-radius:4px; }
  pre code { background:none; padding:0; font-size:inherit; }
  .b { font-weight:600; } .i { font-style:italic; } .st { text-decoration:line-through; }
  a { color:var(--sel); }

  /* Pipe table: cells wrap at ~28em; only a still-overflowing table scrolls
     inside itself (§4.6). */
  .tbl { border:1px solid var(--line); border-radius:8px; overflow-x:auto;
    margin:0 0 8px; max-width:100%; width:fit-content; }
  .tbl table { border-collapse:collapse; line-height:1.5; }
  .tbl th, .tbl td { padding:5px 12px; text-align:left; border-top:1px solid var(--line);
    vertical-align:top; max-width:28em; overflow-wrap:break-word; white-space:normal; }
  .tbl th { border-top:0; font-weight:600; background:var(--card); }

  .expand { border:0; background:transparent; color:var(--sel); font-size:11px;
    cursor:pointer; padding:0; font-family:inherit; display:block; margin:2px 0 8px; }
  .prompt-expand { margin-left:calc(16px + 12.5px + 9px); }
  .expand .cnt { color:var(--text); background:var(--hl); border-radius:4px;
    padding:0 5px; font-size:10px; font-weight:600; }

  /* Chrome is not content: excluded from selection AND copy (§4.6). */
  .prompt .g, .msg .dot, .expand {
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
  .endcap { display:flex; align-items:center; gap:10px; color:var(--text2); font-size:11px;
    margin:14px 16px 4px; -webkit-user-select:none; user-select:none; }
  .endcap::before, .endcap::after { content:""; flex:1; height:1px; background:var(--line); }
  #topshadow { position:fixed; top:0; left:0; right:20px; height:8px; opacity:0;
    pointer-events:none; background:linear-gradient(to bottom, rgba(0,0,0,.12), transparent);
    -webkit-user-select:none; user-select:none; }
</style>
</head>
<body>
<div id="doc"></div>
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
  hasSelection: false,
  warnedNoHighlight: false,
};
const doc = document.getElementById('doc');
const mm = document.getElementById('mm');
const topShadow = document.getElementById('topshadow');
const post = m => window.webkit.messageHandlers.shiibar.postMessage(m);

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

function expandControl(mi, msg, forPrompt) {
  const folded = !S.expanded.has(mi);
  const btn = document.createElement('button');
  btn.className = 'expand' + (forPrompt ? ' prompt-expand' : '');
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

// One message's element (a fragment holding band + control for user
// messages). Registers its text nodes into nodeMaps[mi].
function buildMessage(msg, mi) {
  S.nodeMaps[mi] = [];
  const folded = msg.folds && !S.expanded.has(mi);
  const holder = document.createElement('div');
  holder.dataset.mi = mi; holder.dataset.seq = msg.seq;
  if (msg.role === 'user') {
    const band = document.createElement('div'); band.className = 'prompt';
    const g = document.createElement('span'); g.className = 'g'; g.textContent = '\u276F';
    band.appendChild(g);
    const span = document.createElement('span');
    const blk = msg.blocks[0];
    if (blk) {
      const vis = folded ? blk.foldedLen : blk.text.length;
      addText(span, mi, blk.text.slice(0, vis), blk.start);
    }
    band.appendChild(span);
    holder.appendChild(band);
    if (msg.folds) holder.appendChild(expandControl(mi, msg, true));
    holder.className = 'user-holder';
  } else {
    const row = document.createElement('div'); row.className = 'msg';
    const dot = document.createElement('span'); dot.className = 'dot'; dot.textContent = '\u23FA';
    row.appendChild(dot);
    const body = document.createElement('div'); body.className = 'body';
    msg.blocks.forEach(blk => {
      const el = buildBlock(blk, mi, folded);
      if (el) body.appendChild(el);
    });
    if (msg.folds) body.appendChild(expandControl(mi, msg, false));
    row.appendChild(body);
    holder.appendChild(row);
  }
  return holder;
}

function render() {
  S.nodeMaps = []; S.msgEls = [];
  doc.textContent = '';
  S.msgs.forEach((msg, mi) => {
    const el = buildMessage(msg, mi);
    doc.appendChild(el);
    S.msgEls[mi] = el;
  });
  if (S.msgs.length) {
    // End marker (§4.6/§8.39): chrome, not content — no node-map entry, so
    // it can never enter hits, selection ranges, or copies.
    const cap = document.createElement('div');
    cap.className = 'endcap';
    cap.textContent = S.elapsed
      ? 'Latest message \u00B7 ' + S.elapsed + ' ago'
      : 'Latest message';
    doc.appendChild(cap);
  }
  applyHighlights();
  rebuildMinimap();
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
      const band = holder.querySelector('.prompt');
      if (band) put('band', contentY(band), band.offsetHeight);
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
// {m, s, l} in UTF-16 message coordinates. Chrome text (markers, buttons)
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
    S.msgs = payload.messages;
    S.elapsed = payload.elapsed || null;
    S.hits = []; S.cur = -1; S.expanded = new Set();
    render();
    void doc.scrollHeight; // force layout before positioning
    const anchorEl = anchorSeq === null ? null : doc.querySelector('[data-seq="' + anchorSeq + '"]');
    if (anchorEl) {
      // The remembered message wins over the initial position (§4.6).
      doc.scrollTop = anchorEl.getBoundingClientRect().top - doc.getBoundingClientRect().top + doc.scrollTop;
    } else {
      doc.scrollTop = doc.scrollHeight; // bottom = latest (§4.6)
    }
    post({
      type: 'rendered', ms: performance.now() - t0, messages: S.msgs.length, gen: gen || 0,
      // Geometry for the blank-pane field diagnosis (§8.38(8)): a render
      // into a zero-size viewport is the prime suspect.
      docH: doc.scrollHeight, vw: window.innerWidth, vh: window.innerHeight,
    });
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
  setSize(px) {
    document.documentElement.style.setProperty('--docsize', px + 'px');
    rebuildMinimap();
  },
  setTheme(dark) {
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  },
  selectionRanges,
  hasSelection() { return S.hasSelection; },
};

// Badge counts live on fold buttons; refresh them without touching message
// content nodes (keeps selections alive).
function refreshFoldControls() {
  S.msgs.forEach((msg, mi) => {
    if (!msg.folds) return;
    const holder = S.msgEls[mi];
    if (!holder) return;
    const old = holder.querySelector('.expand');
    if (!old) return;
    const fresh = expandControl(mi, msg, msg.role === 'user');
    old.replaceWith(fresh);
  });
}

new ResizeObserver(() => rebuildMinimap()).observe(doc);

post({ type: 'ready' });
</script>
</body>
</html>
"""#
