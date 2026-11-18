---
title: New LOINC → HP in BONOBO
sql:
  review: ./data/review_items.parquet
  assertions: ./data/assertions.parquet
  errors: ./data/review_errors.parquet
  metrics: ./data/structural_metrics.parquet
---

# 1 · Agent-curated LOINC → HP associations new in BONOBO

BONOBO holds 947 allergy codes migrated from loinc2hpoAnnotation and eight shards curated fresh by agents. This page looks only at the fresh LOINC → HP links, and sets them beside the legacy file they are meant to supersede.

```js
import {rows, verdictBars, hbar, pct} from "./components/charts.js";
```

```js
const bySeries = rows(await sql`
  SELECT series AS "group", verdict, count(*)::INT AS n FROM review
  WHERE verdict IS NOT NULL AND kind = 'loinc_to_phenotype' GROUP BY ALL`);
const byRelation = rows(await sql`
  SELECT relation || ' · ' || CASE WHEN series LIKE 'BONOBO new%' THEN 'BONOBO new' ELSE 'legacy' END AS "group", verdict, count(*)::INT AS n
  FROM review WHERE verdict IS NOT NULL AND series IN ('BONOBO new → HP', 'Legacy loinc2hpo') GROUP BY ALL ORDER BY 1`);
const byShard = rows(await sql`
  SELECT a.record AS "group", r.verdict, count(*)::INT AS n
  FROM review r JOIN assertions a ON a.assertion_id = r.item_id
  WHERE r.series = 'BONOBO new → HP' AND r.verdict IS NOT NULL GROUP BY ALL ORDER BY 1`);
const codes = rows(await sql`
  SELECT e.code_name, e.group_name,
         count(*) FILTER (e.source = 'bonobo_new')::INT AS bonobo_new,
         count(*) FILTER (e.source IN ('legacy', 'kg_loinc2hpo'))::INT AS legacy
  FROM errors e JOIN review r USING (item_id)
  WHERE r.kind = 'loinc_to_phenotype' GROUP BY ALL ORDER BY bonobo_new + legacy DESC`);
const denom = rows(await sql`
  SELECT count(*) FILTER (source = 'bonobo_new')::INT AS bonobo_new, count(*) FILTER (source IN ('legacy', 'kg_loinc2hpo'))::INT AS legacy
  FROM review WHERE kind = 'loinc_to_phenotype' AND verdict IS NOT NULL`)[0];
```

<div class="card">${resize((width) => verdictBars(bySeries, {
  width, groups: ["BONOBO new → HP", "BONOBO imported → HP", "Legacy loinc2hpo", "KG loinc2hpo, absent from repo"],
  title: "LOINC → HP verdicts by source",
  subtitle: "All 150 new BONOBO links were reviewed; the other rows are samples."
}))}</div>

<div class="grid grid-cols-2">
<div class="card">${resize((width) => verdictBars(byRelation, {
  width, marginLeft: 190, title: "By relation", subtitle: "Legacy N and NEG rows are read as RULES_OUT."
}))}</div>
<div class="card">${resize((width) => verdictBars(byShard, {
  width, marginLeft: 190, title: "New BONOBO links by shard", subtitle: "Each shard was curated in its own agent session."
}))}</div>
</div>

## Which errors

Share of reviewed LOINC → HP items carrying each error code. An item can carry more than one.

<div class="card" style="padding:0">${Inputs.table(codes.map((d) => ({...d, bonobo_share: d.bonobo_new / denom.bonobo_new, legacy_share: d.legacy / denom.legacy})), {
  columns: ["group_name", "code_name", "bonobo_new", "bonobo_share", "legacy", "legacy_share"],
  header: {group_name: "Group", code_name: "Error", bonobo_new: "BONOBO new", bonobo_share: "share", legacy: "Legacy + KG", legacy_share: "share"},
  format: {bonobo_share: (d) => pct(d, 1), legacy_share: (d) => pct(d, 1)},
  width: {group_name: 230, code_name: 280}, select: false, rows: 25
})}</div>

## Automatic checks

These need no review. They run on every assertion, not on a sample.

```js
const sm = rows(await sql`
  PIVOT (SELECT source, metric, "value" FROM metrics WHERE object_type = 'HP') ON source USING first("value") GROUP BY metric`);
const metricLabel = {
  n_assertions: "Assertions", n_loinc: "LOINC codes", n_objects: "Distinct HP terms", assertions_per_loinc: "Assertions per LOINC code",
  cited_rate: "With a citation", quoted_rate: "With a verbatim quote", object_deprecated_rate: "HP term obsolete in the KG",
  object_unresolved_rate: "HP term not found in the KG", loinc_unresolved_rate: "LOINC code not found in the KG",
  loinc_label_mismatch_rate: "LOINC label differs from the KG", object_label_mismatch_rate: "HP label differs from the KG",
  direction_conflict_rate: "Direction flag (lexical)", direction_checked: "Assertions the direction flag could check"
};
const fmt = (m) => (v) => v == null ? "–" : /rate$/.test(m) ? pct(v, 1) : (+v.toFixed(2)).toLocaleString("en-US");
```

<div class="card" style="padding:0">${Inputs.table(sm.filter((d) => metricLabel[d.metric]).map((d) => ({
  metric: metricLabel[d.metric], bonobo_new: fmt(d.metric)(d.bonobo_new), bonobo_imported: fmt(d.metric)(d.bonobo_imported), legacy: fmt(d.metric)(d.legacy), kg_loinc2hpo: fmt(d.metric)(d.kg_loinc2hpo)
})), {header: {metric: "Check", bonobo_new: "BONOBO new", bonobo_imported: "BONOBO imported", legacy: "Legacy", kg_loinc2hpo: "In monarch-kg"}, select: false, rows: 20})}</div>

The direction flag is a word match: a high result tied to a term whose label reads as decreased, or the reverse. It is a triage list, not an error count. BONOBO's hits are inverse analytes (a low TSH indicating hyperthyroidism), which are right; several of the KG's are real swaps.

## Reviewed items with a problem

```js
const flagged = rows(await sql`
  SELECT loinc_id, loinc_label, result, relation, object_label, verdict, array_to_string(error_codes, ', ') AS errors, error_note, jev_verdict
  FROM review WHERE series = 'BONOBO new → HP' AND verdict NOT IN ('correct') ORDER BY verdict DESC, loinc_id`);
```

<div class="card" style="padding:0">${Inputs.table(flagged, {
  header: {loinc_id: "LOINC", loinc_label: "Test", result: "Result", relation: "Relation", object_label: "Phenotype", verdict: "Verdict", errors: "Errors", error_note: "Reviewer note", jev_verdict: "Jev"},
  width: {loinc_label: 240, error_note: 420, object_label: 200}, layout: "auto", select: false, rows: 20
})}</div>
