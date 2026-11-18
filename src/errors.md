---
title: Error taxonomy
sql:
  review: ./data/review_items.parquet
  errors: ./data/review_errors.parquet
  taxonomy: ./data/taxonomy.parquet
  gaps: ./data/taxonomy_gaps.parquet
---

# Error taxonomy

The codes came from the data. Two reviewers first described the problems in 88 items in their own words; their 29 free-text themes were merged into the codes below, and all 549 items were then coded against that list. An item can carry several codes.

```js
import * as Plot from "npm:@observablehq/plot";
import {rows, pct, SERIES_ORDER} from "./components/charts.js";
```

```js
const tax = rows(await sql`SELECT * FROM taxonomy ORDER BY code_order`);
const cell = rows(await sql`
  WITH d AS (SELECT series, count(*)::INT AS n FROM review WHERE verdict IS NOT NULL GROUP BY 1)
  SELECT r.series, e.code, count(DISTINCT e.item_id)::INT AS items, d.n, count(DISTINCT e.item_id) / d.n::DOUBLE AS share
  FROM errors e JOIN review r USING (item_id) JOIN d USING (series) GROUP BY r.series, e.code, d.n`);
const totals = rows(await sql`SELECT code, count(DISTINCT item_id)::INT AS items FROM errors GROUP BY 1`);
const nameOf = new Map(tax.map((t) => [t.code, t.code_name]));
const used = tax.filter((t) => totals.some((d) => d.code === t.code));
const short = {"Legacy loinc2hpo": "Legacy", "KG loinc2hpo, absent from repo": "KG only", "BONOBO imported → HP": "Imported", "BONOBO new → HP": "New → HP", "BONOBO new → MONDO": "New → MONDO", "DisMech → MONDO": "DisMech", "2-hop inference (sample)": "2-hop"};
```

<div class="card">${resize((width) => Plot.plot({
  title: "Share of reviewed items carrying each error code",
  subtitle: "Rows are grouped as in the taxonomy. Blank cells are zero. Imported, New → HP and New → MONDO are the BONOBO columns.",
  width, height: 60 + 26 * used.length, marginLeft: 260, marginTop: 50, marginRight: 10,
  x: {domain: SERIES_ORDER.map((s) => short[s]), axis: "top", label: null, tickSize: 0},
  y: {domain: used.map((t) => t.code_name), label: null, tickSize: 0},
  color: {type: "linear", range: ["#cde2fb", "#0d366b"], domain: [0, 0.4], clamp: true, legend: true, label: "Share of reviewed items", tickFormat: "%"},
  marks: [
    Plot.cell(cell, {x: (d) => short[d.series], y: (d) => nameOf.get(d.code), fill: "share", inset: 1, rx: 3,
      channels: {Items: "items", Reviewed: "n"}, tip: {format: {fill: (d) => pct(d, 1)}}}),
    Plot.text(cell, {x: (d) => short[d.series], y: (d) => nameOf.get(d.code), text: (d) => pct(d.share), fill: (d) => (d.share > 0.2 ? "white" : "#0b0b0b"), fontSize: 11})
  ]
}))}</div>

Each source fails in its own way. The **2-hop inference** and the **legacy** file share the test-side errors (challenge codes, antigen-specific antibodies, directions with no meaning) because the inference inherits them. **BONOBO**'s errors are about bands and relation strength: thresholds that depend on something the code does not carry, and a grade or risk marker stated as a diagnosis. **DisMech**'s are about the fit between the LOINC code chosen and the test the record describes.

## The codes

```js
const withCounts = tax.map((t) => ({...t, items: totals.find((d) => d.code === t.code)?.items ?? 0}));
```

<div class="card" style="padding:0">${Inputs.table(withCounts, {
  columns: ["group_name", "code_name", "definition", "items", "code"],
  header: {group_name: "Group", code_name: "Error", definition: "Definition", items: "Items", code: "Code"},
  width: {definition: 620, code_name: 230}, layout: "auto", select: false, rows: 30
})}</div>

## What the taxonomy does not yet cover

The reviewers were asked what they could not express. These came up in more than one batch; items with them were folded into the nearest code.

<div class="card" style="padding:0">${Inputs.table(rows(await sql`SELECT gap, array_to_string(folded_into, ', ') AS folded_into FROM gaps`), {
  header: {gap: "Gap", folded_into: "Folded into"}, width: {gap: 700}, layout: "auto", select: false
})}</div>
