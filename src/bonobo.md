---
title: BONOBO HP + MONDO
sql:
  review: ./data/review_items.parquet
  assertions: ./data/assertions.parquet
  errors: ./data/review_errors.parquet
---

# 2 · BONOBO's new links to phenotypes and diseases together

Everything agents curated fresh in BONOBO: LOINC → HP and LOINC → MONDO, reviewed in full. A BONOBO link is a band of a test result, a term, and a relation such as *indicates* or *rules out*.

```js
import {rows, verdictBars, pct} from "./components/charts.js";
```

```js
const base = `FROM review r JOIN assertions a ON a.assertion_id = r.item_id WHERE r.source = 'bonobo_new' AND r.verdict IS NOT NULL`;
const byTarget = rows(await sql`SELECT r.series AS "group", r.verdict, count(*)::INT AS n FROM review r WHERE r.source = 'bonobo_new' AND r.verdict IS NOT NULL GROUP BY ALL
  UNION ALL SELECT 'BONOBO new, both targets', r.verdict, count(*)::INT FROM review r WHERE r.source = 'bonobo_new' AND r.verdict IS NOT NULL GROUP BY ALL`);
const byRelation = rows(await sql`SELECT r.relation || ' → ' || a.object_type AS "group", r.verdict, count(*)::INT AS n FROM review r JOIN assertions a ON a.assertion_id = r.item_id WHERE r.source = 'bonobo_new' AND r.verdict IS NOT NULL GROUP BY ALL ORDER BY 1`);
const byShard = rows(await sql`SELECT a.record AS "group", r.verdict, count(*)::INT AS n FROM review r JOIN assertions a ON a.assertion_id = r.item_id WHERE r.source = 'bonobo_new' AND r.verdict IS NOT NULL GROUP BY ALL ORDER BY 1`);
const byCited = rows(await sql`SELECT CASE WHEN a.n_refs > 0 THEN 'Cited with a quote' ELSE 'No citation' END AS "group", r.verdict, count(*)::INT AS n FROM review r JOIN assertions a ON a.assertion_id = r.item_id WHERE r.source = 'bonobo_new' AND r.verdict IS NOT NULL GROUP BY ALL ORDER BY 1`);
const codes = rows(await sql`
  SELECT e.group_name, e.code_name, count(*) FILTER (r.kind = 'loinc_to_phenotype')::INT AS hp, count(*) FILTER (r.kind = 'loinc_to_disease')::INT AS mondo
  FROM errors e JOIN review r USING (item_id) WHERE r.source = 'bonobo_new' GROUP BY ALL ORDER BY hp + mondo DESC`);
```

<div class="card">${resize((width) => verdictBars(byTarget, {
  width, groups: ["BONOBO new → HP", "BONOBO new → MONDO", "BONOBO new, both targets"],
  title: "New BONOBO links by target", subtitle: "Every new link was reviewed, so these are counts of the whole, not estimates."
}))}</div>

<div class="grid grid-cols-2">
<div class="card">${resize((width) => verdictBars(byRelation, {width, marginLeft: 200, title: "By relation and target"}))}</div>
<div class="card">${resize((width) => verdictBars(byShard, {width, marginLeft: 200, title: "By shard"}))}</div>
</div>

<div class="card">${resize((width) => verdictBars(byCited, {
  width, title: "Does a citation go with a better verdict?",
  subtitle: "A band is cited when it, its range or its annotation carries a reference with a verbatim quote."
}))}</div>

## Which errors

<div class="card" style="padding:0">${Inputs.table(codes, {
  header: {group_name: "Group", code_name: "Error", hp: "→ HP items", mondo: "→ MONDO items"}, width: {group_name: 230, code_name: 280}, select: false, rows: 25
})}</div>

## Every new link and its verdict

```js
const q = view(Inputs.search(rows(await sql`
  SELECT r.loinc_id, r.loinc_label, r.result, r.relation, r.object_id, r.object_label, a.record AS shard, r.verdict,
         array_to_string(r.error_codes, ', ') AS errors, r.error_note, r.jev_verdict, r.context
  FROM review r JOIN assertions a ON a.assertion_id = r.item_id WHERE r.source = 'bonobo_new' ORDER BY r.verdict DESC, r.loinc_id`), {placeholder: "Search test, term, shard, verdict…"}));
```

<div class="card" style="padding:0">${Inputs.table(q, {
  header: {loinc_id: "LOINC", loinc_label: "Test", result: "Band outcome", relation: "Relation", object_id: "Term id", object_label: "Term", shard: "Shard", verdict: "Verdict", errors: "Errors", error_note: "Reviewer note", jev_verdict: "Jev", context: "Band, population, interpretation"},
  width: {loinc_label: 220, error_note: 380, context: 480, object_label: 200}, layout: "auto", select: false, rows: 25
})}</div>
