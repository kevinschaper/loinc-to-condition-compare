import {html} from "npm:htl";
import {VERDICTS, VERDICT_LABEL, VERDICT_COLOR, SERIES_ORDER} from "./charts.js";

const SERIES_SHORT = {
  "Legacy loinc2hpo": "Legacy loinc2hpo",
  "KG loinc2hpo, absent from repo": "KG loinc2hpo, not in repo",
  "BONOBO imported → HP": "BONOBO imported → HP",
  "BONOBO new → HP": "BONOBO new → HP",
  "BONOBO new → MONDO": "BONOBO new → MONDO",
  "DisMech → MONDO": "DisMech → MONDO",
  "2-hop inference (sample)": "2-hop inference"
};
const JEV = ["Same verdict", "Same side, other verdict", "Differs on correct / not"];
const TARGETS = ["HPO phenotype", "MONDO disease"];
const NEUTRAL = "#2a78d6";

function jevClass(d) {
  if (!d.jev_verdict || !d.verdict) return null;
  if (d.jev_verdict === d.verdict) return JEV[0];
  return (d.verdict === "correct") === (d.jev_verdict === "correct") ? JEV[1] : JEV[2];
}

const dot = (v) => html`<span class="rb-dot" style="background:${VERDICT_COLOR[v] ?? "#b9b8b1"}"></span>`;

/**
 * Faceted browser over the reviewed items.
 * items: rows of review_items with `codes` (array of error code ids).
 * taxonomy: [{code, code_name, group_name}] in display order.
 */
export function reviewBrowser(items, taxonomy, {pageSize = 40} = {}) {
  const codeName = new Map(taxonomy.map((t) => [t.code, t.code_name]));
  const usedCodes = new Set(items.flatMap((d) => d.codes));
  const facets = [
    {id: "series", title: "Source", values: SERIES_ORDER.map((s) => ({key: s, label: SERIES_SHORT[s] ?? s})), get: (d) => [d.series], stacked: true},
    {id: "verdict", title: "Reviewer verdict", values: VERDICTS.filter((v) => items.some((d) => d.verdict === v)).map((v) => ({key: v, label: VERDICT_LABEL[v], color: VERDICT_COLOR[v]})), get: (d) => [d.verdict]},
    {id: "jev", title: "Second judge (Jev)", values: JEV.map((k) => ({key: k, label: k})), get: (d) => [d.jev]},
    {id: "target", title: "Target", values: TARGETS.map((k) => ({key: k, label: k})), get: (d) => [d.target]},
    {id: "code", title: "Error code", values: taxonomy.filter((t) => usedCodes.has(t.code)).map((t) => ({key: t.code, label: t.code_name, group: t.group_name})), get: (d) => d.codes, long: true}
  ];
  for (const d of items) {
    d.jev = jevClass(d);
    d.target = d.kind === "loinc_to_phenotype" ? TARGETS[0] : TARGETS[1];
    d.haystack = [d.loinc_id, d.loinc_label, d.object_id, d.object_label, d.claim, d.error_note, d.context, d.codes.map((c) => codeName.get(c)).join(" ")].join(" ").toLowerCase();
  }

  const state = {sel: Object.fromEntries(facets.map((f) => [f.id, new Set()])), q: "", open: null, limit: pageSize};
  const passes = (d, skip) => {
    if (state.q && !state.q.split(/\s+/).every((w) => d.haystack.includes(w))) return false;
    for (const f of facets) {
      if (f.id === skip || !state.sel[f.id].size) continue;
      if (!f.get(d).some((k) => state.sel[f.id].has(k))) return false;
    }
    return true;
  };

  const search = html`<input class="rb-search" type="search" placeholder="Search test, term, note…" aria-label="Search reviewed items">`;
  search.oninput = () => { state.q = search.value.trim().toLowerCase(); state.limit = pageSize; render(); };
  const rail = html`<div class="rb-facets"></div>`;
  const results = html`<div class="rb-results"></div>`;
  const root = html`<div class="rb"><aside class="rb-rail">${search}${rail}</aside>${results}</div>`;

  function toggle(fid, key) {
    const s = state.sel[fid];
    s.has(key) ? s.delete(key) : s.add(key);
    state.limit = pageSize;
    render();
  }

  function facetBlock(f) {
    const pool = items.filter((d) => passes(d, f.id));
    const counts = new Map(), mix = new Map();
    for (const d of pool) for (const k of f.get(d)) {
      counts.set(k, (counts.get(k) ?? 0) + 1);
      if (f.stacked) { const m = mix.get(k) ?? {}; m[d.verdict] = (m[d.verdict] ?? 0) + 1; mix.set(k, m); }
    }
    const max = Math.max(1, ...f.values.map((v) => counts.get(v.key) ?? 0));
    const sel = state.sel[f.id];
    let lastGroup = null;
    const rowsEl = f.values.map((v) => {
      const n = counts.get(v.key) ?? 0;
      const on = sel.has(v.key);
      const bar = f.stacked
        ? html`<span class="rb-bar" style="width:${(100 * n) / max}%">${VERDICTS.filter((k) => mix.get(v.key)?.[k]).map((k) => html`<span style="flex:${mix.get(v.key)[k]};background:${VERDICT_COLOR[k]}"></span>`)}</span>`
        : html`<span class="rb-bar" style="width:${(100 * n) / max}%;background:${v.color ?? NEUTRAL}"></span>`;
      const btn = html`<button type="button" class="rb-val${on ? " on" : ""}${n ? "" : " empty"}" aria-pressed=${String(on)} title=${v.label}>
        <span class="rb-val-top"><span class="rb-check">${on ? "✓" : ""}</span><span class="rb-val-label">${v.label}</span><span class="rb-val-n">${n}</span></span>
        <span class="rb-track">${bar}</span>
      </button>`;
      btn.onclick = () => toggle(f.id, v.key);
      if (f.long && v.group !== lastGroup) { lastGroup = v.group; return html.fragment`<div class="rb-group">${v.group}</div>${btn}`; }
      return btn;
    });
    const clear = html`<button type="button" class="rb-clear">clear</button>`;
    clear.onclick = () => { sel.clear(); render(); };
    return html`<section class="rb-facet"><h3>${f.title}${sel.size ? clear : ""}</h3>${rowsEl}</section>`;
  }

  function detail(d) {
    let paths = null;
    try { paths = d.derivation ? JSON.parse(d.derivation) : null; } catch { paths = null; }
    return html`<div class="rb-detail">
      <p class="rb-claim">${d.claim}</p>
      <dl>
        <dt>Reviewer</dt><dd>${dot(d.verdict)}${VERDICT_LABEL[d.verdict]} · ${d.confidence} confidence${d.weak_link && d.weak_link !== "none" ? ` · weak link: ${d.weak_link.replaceAll("_", " ")}` : ""}<br>${d.error_note || "No note."}</dd>
        ${d.codes.length ? html.fragment`<dt>Error codes</dt><dd>${d.codes.map((c) => html`<span class="rb-chip">${codeName.get(c) ?? c}</span>`)}</dd>` : ""}
        <dt>Jev</dt><dd>${dot(d.jev_verdict)}${VERDICT_LABEL[d.jev_verdict] ?? "–"} · p(accurate) ${d.jev_p_accurate ?? "–"}</dd>
        ${d.context ? html.fragment`<dt>Curator context</dt><dd>${d.context}</dd>` : ""}
        ${paths ? html.fragment`<dt>Inferred through</dt><dd><table class="rb-paths"><thead><tr><th>Phenotype</th><th>Result</th><th>Frequency in disease</th><th>Diseases with phenotype</th></tr></thead><tbody>
          ${paths.map((p) => html`<tr><td>${p.phenotype} <span class="rb-id">${p.hp_id}</span></td><td>${p.result_direction}</td><td>${p.frequency_in_disease}</td><td>${p.diseases_with_this_phenotype ?? "–"}</td></tr>`)}</tbody></table></dd>` : ""}
        <dt>Sample stratum</dt><dd>${d.stratum}</dd>
      </dl>
    </div>`;
  }

  function card(d) {
    const open = state.open === d.item_id;
    const rel = String(d.relation ?? "").toLowerCase().replaceAll("_", " ");
    const head = html`<button type="button" class="rb-card-head" aria-expanded=${String(open)}>
      <span class="rb-card-top">
        <span class="rb-verdict">${dot(d.verdict)}${VERDICT_LABEL[d.verdict]}</span>
        <span class="rb-src">${SERIES_SHORT[d.series] ?? d.series}</span>
        <span class="rb-jev" title="Second judge">Jev: ${dot(d.jev_verdict)}${VERDICT_LABEL[d.jev_verdict] ?? "–"}</span>
      </span>
      <span class="rb-pair"><span>${d.loinc_label}</span><span class="rb-arrow">→</span><span>${d.object_label}</span></span>
      <span class="rb-meta">${d.loinc_id}${d.result ? ` · result ${d.result}` : ""} · ${rel} · ${d.object_id}</span>
      ${!open && d.error_note ? html`<span class="rb-note">${d.error_note}</span>` : ""}
      ${!open && d.codes.length ? html`<span class="rb-chips">${d.codes.map((c) => html`<span class="rb-chip">${codeName.get(c) ?? c}</span>`)}</span>` : ""}
    </button>`;
    head.onclick = () => { state.open = open ? null : d.item_id; render(); };
    return html`<article class="rb-card${open ? " open" : ""}" style="border-left-color:${VERDICT_COLOR[d.verdict] ?? "#b9b8b1"}">${head}${open ? detail(d) : ""}</article>`;
  }

  function render() {
    rail.replaceChildren(...facets.map(facetBlock));
    const hits = items.filter((d) => passes(d));
    const mix = VERDICTS.map((v) => ({v, n: hits.filter((d) => d.verdict === v).length})).filter((d) => d.n);
    const active = facets.flatMap((f) => [...state.sel[f.id]].map((k) => ({f, k, label: f.values.find((v) => v.key === k)?.label ?? k})));
    const chips = active.map(({f, k, label}) => {
      const b = html`<button type="button" class="rb-active" title="Remove filter">${label} ✕</button>`;
      b.onclick = () => toggle(f.id, k);
      return b;
    });
    const clearAll = html`<button type="button" class="rb-clear">clear all</button>`;
    clearAll.onclick = () => { for (const f of facets) state.sel[f.id].clear(); state.q = ""; search.value = ""; render(); };
    const more = html`<button type="button" class="rb-more">Show ${Math.min(pageSize, hits.length - state.limit)} more</button>`;
    more.onclick = () => { state.limit += pageSize; render(); };
    results.replaceChildren(html`
      <div class="rb-summary">
        <div class="rb-count"><strong>${hits.length.toLocaleString("en-US")}</strong> of ${items.length} reviewed items ${chips}${active.length || state.q ? clearAll : ""}</div>
        ${hits.length ? html`<div class="rb-mix" role="img" aria-label="Verdict mix of the filtered items">${mix.map((m) => html`<span style="flex:${m.n};background:${VERDICT_COLOR[m.v]}" title=${`${VERDICT_LABEL[m.v]}: ${m.n}`}></span>`)}</div>
        <div class="rb-legend">${mix.map((m) => html`<span>${dot(m.v)}${VERDICT_LABEL[m.v]} ${m.n} · ${Math.round((100 * m.n) / hits.length)}%</span>`)}</div>` : ""}
      </div>
      ${hits.length ? html`<div class="rb-cards">${hits.slice(0, state.limit).map(card)}</div>` : html`<p class="rb-none">No reviewed item matches these filters.</p>`}
      ${hits.length > state.limit ? more : ""}`);
  }

  render();
  return root;
}
