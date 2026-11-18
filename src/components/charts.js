import * as Plot from "npm:@observablehq/plot";
import {html} from "npm:htl";

// Verdicts are an ordered status scale, so they wear the status colors and always ship with a label.
export const VERDICTS = ["correct", "correct_but_weak", "partially_correct", "incorrect", "cannot_judge"];
export const VERDICT_LABEL = {
  correct: "Correct",
  correct_but_weak: "Correct but weak",
  partially_correct: "Partially correct",
  incorrect: "Incorrect",
  cannot_judge: "Cannot judge"
};
export const VERDICT_COLOR = {
  correct: "#0ca30c",
  correct_but_weak: "#9ec5f4",
  partially_correct: "#fab219",
  incorrect: "#d03b3b",
  cannot_judge: "#b9b8b1"
};

export const SERIES_ORDER = [
  "Legacy loinc2hpo",
  "KG loinc2hpo, absent from repo",
  "BONOBO imported → HP",
  "BONOBO new → HP",
  "BONOBO new → MONDO",
  "DisMech → MONDO",
  "2-hop inference (sample)"
];

/** Arrow table (from a sql`` cell) -> plain objects, with BigInt turned into Number. */
export function rows(table) {
  return Array.from(table, (r) => {
    const o = {};
    for (const [k, v] of Object.entries(r.toJSON ? r.toJSON() : r)) o[k] = typeof v === "bigint" ? Number(v) : v;
    return o;
  });
}

/** Wilson score interval for k successes in n trials. */
export function wilson(k, n, z = 1.96) {
  if (!n) return [NaN, NaN];
  const p = k / n, d = 1 + (z * z) / n;
  const c = (p + (z * z) / (2 * n)) / d;
  const h = (z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))) / d;
  return [Math.max(0, c - h), Math.min(1, c + h)];
}

export const pct = (x, digits = 0) => (x == null || Number.isNaN(x) ? "–" : (100 * x).toFixed(digits) + "%");

/**
 * Stacked share-of-verdict bars, one row per group.
 * data: [{group, verdict, n}] (counts) or [{group, verdict, share, n_group}] when weighted is true.
 */
export function verdictBars(data, {width, groups, title, subtitle, marginLeft = 230, weighted = false, note} = {}) {
  const order = groups ?? [...new Set(data.map((d) => d.group))];
  const total = new Map();
  for (const d of data) total.set(d.group, (total.get(d.group) ?? 0) + (weighted ? 0 : d.n));
  const shaped = data
    .filter((d) => order.includes(d.group))
    .map((d) => ({
      ...d,
      share: weighted ? d.share : d.n / total.get(d.group),
      n_group: weighted ? d.n_group : total.get(d.group),
      label: VERDICT_LABEL[d.verdict] ?? d.verdict
    }))
    .filter((d) => d.share > 0);
  const nLabel = order.map((g) => {
    const d = shaped.find((s) => s.group === g);
    return {group: g, text: d ? `n = ${d.n_group.toLocaleString("en-US")}` : ""};
  });
  // In a narrow card the label gutter must not eat the plot.
  marginLeft = Math.round(Math.min(marginLeft, Math.max(110, width * 0.42)));
  return Plot.plot({
    title,
    subtitle,
    caption: note,
    width,
    height: 44 + 34 * order.length,
    marginLeft,
    marginRight: 78,
    x: {axis: "top", label: null, percent: true, ticks: width < 520 ? 2 : 5, tickFormat: (d) => d + "%", grid: true},
    y: {domain: order, label: null, tickSize: 0, padding: 0.28, tickFormat: (d) => (d.length * 6.2 > marginLeft ? d.slice(0, Math.floor(marginLeft / 6.2) - 1) + "…" : d)},
    color: {domain: VERDICTS.map((v) => VERDICT_LABEL[v]), range: VERDICTS.map((v) => VERDICT_COLOR[v]), legend: true},
    marks: [
      Plot.barX(
        shaped,
        Plot.stackX({
          x: "share",
          y: "group",
          fill: "label",
          order: VERDICTS.map((v) => VERDICT_LABEL[v]),
          insetLeft: 1,
          insetRight: 1,
          channels: {Share: {value: "share", label: "Share"}, Group: "group"},
          tip: {format: {x: false, y: false, Share: (d) => pct(d, 1), fill: true, Group: true}}
        })
      ),
      Plot.text(
        shaped,
        Plot.stackX({
          x: "share",
          y: "group",
          z: "label",
          order: VERDICTS.map((v) => VERDICT_LABEL[v]),
          text: (d) => (d.share * (width - marginLeft - 78) >= 30 ? pct(d.share) : ""),
          fill: (d) => (d.verdict === "correct" || d.verdict === "incorrect" ? "white" : "#1a1a19"),
          fontWeight: 500
        })
      ),
      Plot.text(nLabel, {y: "group", text: "text", frameAnchor: "right", dx: 74, textAnchor: "end", fill: "currentColor", fillOpacity: 0.6})
    ]
  });
}

/** Horizontal bars for one measure, sorted as given. */
export function hbar(data, {x, y, width, title, subtitle, marginLeft = 230, format = (d) => d.toLocaleString("en-US"), percent = false, fill = "#2a78d6", xLabel = null, note} = {}) {
  return Plot.plot({
    title,
    subtitle,
    caption: note,
    width,
    height: 40 + 28 * data.length,
    marginLeft,
    marginRight: 70,
    x: {axis: null, label: xLabel, percent},
    y: {domain: data.map((d) => d[y]), label: null, tickSize: 0, padding: 0.3},
    marks: [
      Plot.barX(data, {x, y, fill, tip: {format: {x: format}}}),
      Plot.text(data, {x, y, text: (d) => format(d[x]), dx: 6, textAnchor: "start", fill: "currentColor"})
    ]
  });
}

/** A headline number with a label and a quiet second line. */
export function tile(label, value, detail) {
  return html`<div class="card" style="margin:0">
    <h2 style="margin:0 0 .25rem;font-size:.82rem;font-weight:500;opacity:.75">${label}</h2>
    <div style="font-size:2rem;font-weight:650;line-height:1.15">${value}</div>
    <div style="font-size:.8rem;opacity:.7;margin-top:.25rem">${detail}</div>
  </div>`;
}

/** Share judged "correct" with a Wilson interval, as text. */
export function correctShare(k, n) {
  const [lo, hi] = wilson(k, n);
  return {value: pct(k / n), detail: `${k} of ${n} reviewed · 95% CI ${pct(lo)}–${pct(hi)}`};
}
