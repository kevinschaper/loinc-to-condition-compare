---
title: 2-hop graph inference
sql:
  review: ./data/review_items.parquet
  pairs: ./data/twohop_pairs.parquet
  paths: ./data/twohop_paths.parquet
  vq: ./data/twohop_variant_quality.parquet
  excluded: ./data/twohop_excluded.parquet
  variants: ./data/twohop_variants.parquet
  errors: ./data/review_errors.parquet
---

# 4 · LOINC → MONDO by 2-hop inference through monarch-kg

The inference joins two edge sets already in the graph: a test's link to a phenotype (the loinc2hpo edges) and a disease's link to the same phenotype, read backwards. **test → phenotype ← disease** becomes **test → disease**. A disease–phenotype edge that says the phenotype is *not* a feature (negated, or a stated frequency of 0%) is never chained. The question is how much of the result is worth having, and whether filtering the disease–phenotype edge on frequency helps.

```js
import {rows, verdictBars, hbar, pct, tile, VERDICTS, VERDICT_LABEL} from "./components/charts.js";
```

```js
const VARIANT = {
  v_all: "All inferred pairs",
  v_freq_known: "… and frequency recorded",
  v_freq_ge_5: "… and frequency ≥ 5%",
  v_freq_ge_30_or_unknown: "… and frequency ≥ 30% or not recorded",
  v_freq_ge_30: "… and frequency ≥ 30%",
  v_freq_ge_80: "… and frequency ≥ 80%",
  v_specific_hp_le_25: "… and phenotype in ≤ 25 diseases",
  v_specific_and_freq: "… ≤ 25 diseases and ≥ 30% or not recorded"
};
const vq = rows(await sql`SELECT * FROM vq`).map((d) => ({...d, label: VARIANT[d.variant]}));
const order = Object.values(VARIANT);
const vqLong = vq.flatMap((d) => [
  {group: d.label, verdict: "correct", share: d.p_correct, n_group: d.n_pairs},
  {group: d.label, verdict: "correct_but_weak", share: d.p_weak, n_group: d.n_pairs},
  {group: d.label, verdict: "partially_correct", share: d.p_partial, n_group: d.n_pairs},
  {group: d.label, verdict: "incorrect", share: d.p_incorrect, n_group: d.n_pairs}
]);
const byTier = rows(await sql`SELECT tier AS "group", verdict, count(*)::INT AS n FROM review WHERE source = 'kg_2hop' AND verdict IS NOT NULL GROUP BY ALL`);
const bySpread = rows(await sql`SELECT CASE WHEN spread LIKE 'specific%' THEN 'In ≤ 25 diseases' ELSE 'In > 25 diseases' END AS "group", verdict, count(*)::INT AS n FROM review WHERE source = 'kg_2hop' AND verdict IS NOT NULL GROUP BY ALL`);
const byHop = rows(await sql`
  SELECT CASE WHEN NOT first_hop_in_repo THEN 'First hop absent from the loinc2hpo repo'
              WHEN timed_test THEN 'Challenge or timed test code'
              ELSE 'Baseline test, first hop in the repo' END AS "group", verdict, count(*)::INT AS n
  FROM review WHERE source = 'kg_2hop' AND verdict IS NOT NULL GROUP BY ALL`);
const hopPop = rows(await sql`
  SELECT count(*)::INT AS total,
         count(*) FILTER (NOT first_hop_in_repo)::INT AS not_repo,
         count(*) FILTER (first_hop_in_repo AND regexp_matches(loinc_label, '(--|post |challenge|XXX)'))::INT AS timed,
         count(*) FILTER (first_hop_in_repo AND NOT regexp_matches(loinc_label, '(--|post |challenge|XXX)'))::INT AS clean
  FROM pairs`)[0];
const weak = rows(await sql`
  SELECT CASE weak_link WHEN 'test_to_phenotype' THEN 'Test → phenotype' WHEN 'phenotype_to_disease' THEN 'Phenotype → disease'
                        WHEN 'chaining' THEN 'The chaining itself' ELSE 'No weak link' END AS link, count(*)::INT AS n
  FROM review WHERE source = 'kg_2hop' GROUP BY ALL ORDER BY n DESC`);
const codes = rows(await sql`SELECT code_name, count(*)::INT AS items FROM errors WHERE source = 'kg_2hop' GROUP BY ALL ORDER BY items DESC LIMIT 12`);
const rec = rows(await sql`SELECT variant, n_pairs::INT AS n_pairs, curated_reachable::INT AS reachable, recovered_exact::INT AS exact, recovered_related::INT AS related FROM variants WHERE curated_source = 'dismech'`).map((d) => ({...d, label: VARIANT[d.variant]}));
const excl = rows(await sql`SELECT * FROM excluded`)[0];
const all = vq.find((d) => d.variant === "v_all"), best = vq.find((d) => d.variant === "v_specific_and_freq");
```

<div class="grid grid-cols-4">
  ${tile("Inferred pairs", all.n_pairs.toLocaleString("en-US"), "one LOINC code and one disease")}
  ${tile("Left out as negated or 0%", (excl.paths_negated + excl.paths_zero_frequency).toLocaleString("en-US"), `disease–phenotype paths; ${excl.pairs_dropped.toLocaleString("en-US")} pairs had no other path`)}
  ${tile("Judged correct, all pairs", pct(all.p_correct), `±${pct(1.96 * all.se_correct)} · weighted from ${all.n_reviewed} reviewed`)}
  ${tile("Judged correct, strictest filter", pct(best.p_correct), `±${pct(1.96 * best.se_correct)} · ${best.n_pairs.toLocaleString("en-US")} pairs left`)}
</div>

## Filter variants

<div class="card">${resize((width) => verdictBars(vqLong, {
  width, groups: order, weighted: true, marginLeft: 300,
  title: "Estimated verdict mix of each filter variant",
  subtitle: "Sample rates in each frequency × spread stratum, weighted by how many pairs of that stratum the variant keeps.",
  note: "12 pairs were reviewed per stratum, so the correct share carries about ±5 points on the wide variants and ±11 on the two narrowest."
}))}</div>

Filtering on frequency does what it should to the **weak** associations: they fall from about a quarter of pairs to under a tenth at ≥ 30%. It does little for the share judged **correct**, because frequency is a property of the second hop and most failures are in the first.

<div class="grid grid-cols-2">
<div class="card">${resize((width) => verdictBars(byTier, {
  width, marginLeft: 170,
  groups: ["obligate (100%)", "very frequent (80-99%)", "frequent (30-79%)", "occasional (5-29%)", "very rare (<5%)", "unknown"],
  title: "By frequency of the phenotype in the disease", subtitle: "24 reviewed pairs per tier."
}))}</div>
<div class="card">${resize((width) => verdictBars(bySpread, {
  width, marginLeft: 130, groups: ["In ≤ 25 diseases", "In > 25 diseases"], title: "By how many diseases share the phenotype", subtitle: "72 reviewed pairs each."
}))}</div>
</div>

## Where the chain breaks

<div class="grid grid-cols-2">
<div class="card">${resize((width) => hbar(weak, {x: "n", y: "link", width, marginLeft: 170, title: "Weakest link, as the reviewer saw it", subtitle: "144 reviewed pairs."}))}</div>
<div class="card">${resize((width) => hbar(codes, {x: "items", y: "code_name", width, marginLeft: 250, title: "Error codes on reviewed 2-hop pairs", subtitle: "An item can carry more than one."}))}</div>
</div>

<div class="card">${resize((width) => verdictBars(byHop, {
  width, marginLeft: 290,
  groups: ["Baseline test, first hop in the repo", "Challenge or timed test code", "First hop absent from the loinc2hpo repo"],
  title: "Verdicts by a property of the first hop",
  subtitle: "Reviewed pairs, split after the fact. Not weighted, and not a designed stratum.",
  note: `In the population: ${hopPop.clean.toLocaleString("en-US")} pairs on a baseline test with the first hop in the repo, ${hopPop.timed.toLocaleString("en-US")} on a challenge or timed code, ${hopPop.not_repo.toLocaleString("en-US")} whose first hop is absent from the repo.`
}))}</div>

Two properties of the **test → phenotype** edge separate the results more than any frequency threshold:

- **Edges that are in monarch-kg but not in the loinc2hpoAnnotation repo.** The graph holds 2,688 loinc2hpo edges with no row in the repository's `main` file. Most tie a *low* result on an antigen-specific antibody test to "Abnormal circulating immunoglobulin concentration" or a similar parent term. Pairs built on them are almost all wrong.
- **Challenge and timed codes.** Half the inferred pairs start from a code such as "Glucose 2 hours post dose lactose", which inherited the baseline analyte's phenotype. The disease link is often real; reading the timed value as high or low is not.

This split was made after the review, on a sample not designed for it, so treat it as the next thing to test, not as a measured rate.

## Does the inference find what curators found?

<div class="card" style="padding:0">${Inputs.table(rec.sort((a, b) => b.n_pairs - a.n_pairs), {
  columns: ["label", "n_pairs", "reachable", "exact", "related"],
  header: {label: "Variant", n_pairs: "Inferred pairs", reachable: "DisMech pairs within reach", exact: "Recovered exactly", related: "Recovered, parent or child disease"},
  format: {n_pairs: (d) => d.toLocaleString("en-US")}, select: false, rows: 12, width: {label: 320}
})}</div>

A DisMech pair is within reach when its LOINC code has any loinc2hpo edge. Each tightening of the filter loses curated pairs as well as noise.

## Look up a test

```js
const term = view(Inputs.text({label: "LOINC code or name", placeholder: "e.g. 2276-4 or ferritin", value: "ferritin", width: 420}));
```

```js
const found = rows(await sql`
  SELECT loinc_id, loinc_label, result_direction, hp_label, mondo_label,
         freq_tier, hp_n_diseases::INT AS hp_n_diseases, d2p_source, first_hop_in_repo
  FROM paths WHERE ${term} <> '' AND (loinc_id ILIKE ${"%" + term + "%"} OR loinc_label ILIKE ${"%" + term + "%"})
  ORDER BY freq DESC NULLS LAST, hp_n_diseases LIMIT 500`);
```

<div class="card" style="padding:0">${Inputs.table(found, {
  header: {loinc_id: "LOINC", loinc_label: "Test", result_direction: "Result", hp_label: "Phenotype", mondo_label: "Disease", freq_tier: "Frequency", hp_n_diseases: "Diseases with phenotype", d2p_source: "Disease–phenotype source", first_hop_in_repo: "First hop in repo"},
  width: {loinc_label: 260, hp_label: 220, mondo_label: 240}, layout: "auto", select: false, rows: 20
})}</div>

Up to 500 paths, most frequent first.
