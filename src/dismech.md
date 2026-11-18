---
title: DisMech LOINC → MONDO
sql:
  review: ./data/review_items.parquet
  assertions: ./data/assertions.parquet
  errors: ./data/review_errors.parquet
  pairs: ./data/twohop_pairs.parquet
  variants: ./data/twohop_variants.parquet
---

# 3 · DisMech's LOINC → MONDO associations

DisMech disease records name LOINC codes in two places: the tests listed under a **diagnosis** entry, and the analyte of a **biochemical** biomarker, which also says whether it is raised or lowered. Each LOINC code and disease is one association here.

```js
import {rows, verdictBars, hbar, pct, tile} from "./components/charts.js";
```

```js
const totals = rows(await sql`
  SELECT count(*)::INT AS n, count(DISTINCT loinc_id)::INT AS loincs, count(DISTINCT object_id)::INT AS diseases,
         avg((n_refs > 0)::INT) AS cited, count(*) FILTER (relation = 'BIOMARKER')::INT AS biomarker
  FROM assertions WHERE source = 'dismech'`)[0];
const byRole = rows(await sql`
  SELECT CASE r.relation WHEN 'BIOMARKER' THEN 'Biomarker' WHEN 'DIAGNOSTIC_TEST' THEN 'Diagnostic test' ELSE 'Both' END AS "group", r.verdict, count(*)::INT AS n
  FROM review r WHERE r.source = 'dismech' AND r.verdict IS NOT NULL GROUP BY ALL
  UNION ALL SELECT 'All DisMech (sample)', verdict, count(*)::INT FROM review WHERE source = 'dismech' AND verdict IS NOT NULL GROUP BY ALL`);
const byEvidence = rows(await sql`
  SELECT CASE WHEN a.n_refs > 0 THEN 'Entry cites evidence' ELSE 'No evidence on the entry' END AS "group", r.verdict, count(*)::INT AS n
  FROM review r JOIN assertions a ON a.assertion_id = r.item_id WHERE r.source = 'dismech' AND r.verdict IS NOT NULL GROUP BY ALL`);
const codes = rows(await sql`
  SELECT e.group_name, e.code_name, count(*)::INT AS items FROM errors e WHERE e.source = 'dismech' GROUP BY ALL ORDER BY items DESC`);
const recover = rows(await sql`SELECT variant, n_pairs::INT AS n_pairs, curated_pairs::INT AS curated_pairs, curated_reachable::INT AS curated_reachable, recovered_exact::INT AS recovered_exact, recovered_related::INT AS recovered_related FROM variants WHERE curated_source = 'dismech' AND variant = 'v_all'`)[0];
```

<div class="grid grid-cols-4">
  ${tile("Associations", totals.n.toLocaleString("en-US"), `${totals.loincs} LOINC codes · ${totals.diseases} diseases`)}
  ${tile("Carry evidence", pct(totals.cited), "the entry cites a reference with a quote")}
  ${tile("Biomarker links", totals.biomarker.toLocaleString("en-US"), "the rest come from diagnosis entries")}
  ${tile("Also found by 2-hop", `${recover.recovered_exact}`, `exact pairs; ${recover.recovered_related} allowing a parent or child disease`)}
</div>

<div class="card">${resize((width) => verdictBars(byRole, {
  width, groups: ["All DisMech (sample)", "Diagnostic test", "Biomarker", "Both"],
  title: "Verdicts by how the test is used in the record",
  subtitle: "A sample of 100 associations: 55 from diagnosis entries, 45 biomarkers."
}))}</div>

<div class="grid grid-cols-2">
<div class="card">${resize((width) => verdictBars(byEvidence, {width, marginLeft: 180, title: "With and without evidence on the entry"}))}</div>
<div class="card">${resize((width) => hbar(codes.slice(0, 10), {x: "items", y: "code_name", width, marginLeft: 240, title: "Error codes on reviewed DisMech items", subtitle: "Count of items; an item can carry more than one."}))}</div>
</div>

## How little the 2-hop inference overlaps

Of ${totals.n.toLocaleString("en-US")} DisMech associations, only ${recover.curated_reachable} use a LOINC code that has any loinc2hpo edge in the KG, so the rest are out of the inference's reach whatever filter is applied. Of those ${recover.curated_reachable}, the inference reproduces ${recover.recovered_exact} exactly. The two sources mostly describe different tests: DisMech's are the diagnostic assays for a disease (genetic tests, pathogen detection, imaging scores), which loinc2hpo never annotated.

## Reviewed items

```js
const q = view(Inputs.search(rows(await sql`
  SELECT r.loinc_id, r.loinc_label, r.relation, r.result, r.object_label, r.verdict, array_to_string(r.error_codes, ', ') AS errors, r.error_note, r.jev_verdict, a.record, r.context
  FROM review r JOIN assertions a ON a.assertion_id = r.item_id WHERE r.source = 'dismech' ORDER BY r.verdict DESC, r.loinc_id`), {placeholder: "Search test, disease, verdict…"}));
```

<div class="card" style="padding:0">${Inputs.table(q, {
  header: {loinc_id: "LOINC", loinc_label: "Test", relation: "Role", result: "Expected", object_label: "Disease", verdict: "Verdict", errors: "Errors", error_note: "Reviewer note", jev_verdict: "Jev", record: "Record", context: "Entry"},
  width: {loinc_label: 220, error_note: 380, context: 480, object_label: 200}, layout: "auto", select: false, rows: 20
})}</div>
