---
title: Overview
toc: false
sql:
  review: ./data/review_items.parquet
  assertions: ./data/assertions.parquet
  variant_quality: ./data/twohop_variant_quality.parquet
  pairs: ./data/twohop_pairs.parquet
---

# LOINC → condition associations, compared

How good are the links from a LOINC lab test to an HPO phenotype or a MONDO disease, and does it matter where they come from? This dashboard compares four sources: the legacy **loinc2hpoAnnotation** file, the agent-curated **BONOBO** corpus, **DisMech**'s disease records, and a **2-hop inference** through monarch-kg (test → phenotype → disease).

A stratified sample of each source was judged by reviewing agents against a fixed protocol, with Jev as a second opinion. **Verdicts are model judgments, not curator labels**; see [Methods](./methods) for what that does and does not support.

```js
import {rows, verdictBars, tile, correctShare, pct, SERIES_ORDER, hbar} from "./components/charts.js";
```

```js
const bySeries = rows(await sql`
  SELECT series AS "group", verdict, count(*)::INT AS n
  FROM review WHERE verdict IS NOT NULL GROUP BY ALL`);
const vq = rows(await sql`SELECT * FROM variant_quality`);
const sizes = rows(await sql`
  SELECT * FROM (
    SELECT CASE source WHEN 'legacy' THEN 'Legacy loinc2hpo' WHEN 'kg_loinc2hpo' THEN 'loinc2hpo as loaded in monarch-kg'
                       WHEN 'bonobo_imported' THEN 'BONOBO imported' WHEN 'bonobo_new' THEN 'BONOBO new' ELSE 'DisMech' END AS source,
           object_type AS target, count(*)::INT AS assertions, count(DISTINCT loinc_id)::INT AS loinc_codes, count(DISTINCT object_id)::INT AS terms
    FROM assertions GROUP BY ALL
    UNION ALL
    SELECT '2-hop inference', 'MONDO', count(*)::INT, count(DISTINCT loinc_id)::INT, count(DISTINCT mondo_id)::INT FROM pairs)
  ORDER BY assertions DESC`);
```

```js
function seriesTile(label, series) {
  const d = bySeries.filter((r) => r.group === series && r.verdict !== "cannot_judge");
  const n = d.reduce((s, r) => s + r.n, 0);
  const k = d.filter((r) => r.verdict === "correct").reduce((s, r) => s + r.n, 0);
  const c = correctShare(k, n);
  return tile(label, c.value, c.detail);
}
function variantTile(label, variant) {
  const v = vq.find((r) => r.variant === variant);
  return tile(label, pct(v.p_correct), `${v.n_pairs.toLocaleString("en-US")} pairs · weighted from ${v.n_reviewed} reviewed · ±${pct(1.96 * v.se_correct)}`);
}
```

## Share judged correct

<div class="grid grid-cols-4">
  ${seriesTile("1 · BONOBO new → HP", "BONOBO new → HP")}
  ${seriesTile("2 · BONOBO new → MONDO", "BONOBO new → MONDO")}
  ${seriesTile("3 · DisMech → MONDO", "DisMech → MONDO")}
  ${variantTile("4 · 2-hop inference", "v_all")}
</div>

<div class="grid grid-cols-4">
  ${seriesTile("Baseline · legacy loinc2hpo", "Legacy loinc2hpo")}
  ${seriesTile("KG loinc2hpo edges absent from repo", "KG loinc2hpo, absent from repo")}
  ${variantTile("2-hop, frequency ≥ 30% or unknown", "v_freq_ge_30_or_unknown")}
  ${variantTile("2-hop, specific phenotype and frequency", "v_specific_and_freq")}
</div>

## Verdicts by source

<div class="card">${resize((width) => verdictBars(bySeries, {
  width, groups: SERIES_ORDER,
  title: "Reviewed associations by verdict",
  subtitle: "Share of the reviewed sample in each source. BONOBO's new content was reviewed in full; the others are samples.",
  note: "The 2-hop row is the raw stratified sample, which over-represents small strata. The population-weighted figures are on the 2-hop page."
}))}</div>

## What is being compared

<div class="card" style="padding:0">${Inputs.table(sizes, {
  header: {source: "Source", target: "Target", assertions: "Assertions", loinc_codes: "LOINC codes", terms: "Distinct terms"},
  format: {assertions: (d) => d.toLocaleString("en-US"), loinc_codes: (d) => d.toLocaleString("en-US"), terms: (d) => d.toLocaleString("en-US")},
  select: false, rows: 12
})}</div>

An assertion is one LOINC code, one term and one relation. BONOBO bands that repeat the same link are collapsed; a 2-hop pair is one LOINC code and one disease, however many phenotypes connect them.
