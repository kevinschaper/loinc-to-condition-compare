---
title: Reviewed items
toc: false
sql:
  review: ./data/review_items.parquet
  taxonomy: ./data/taxonomy.parquet
---

# Reviewed items

Every reviewed association with both verdicts. Click a facet value to filter; values within a facet combine as *or*, facets combine as *and*, and the counts show what each value would return given the other filters. Click a card to read the claim, the reviewer's note and the curator context.

```js
import {rows} from "./components/charts.js";
import {reviewBrowser} from "./components/review-browser.js";
```

```js
const tax = rows(await sql`SELECT code, code_name, group_name FROM taxonomy ORDER BY code_order`);
const order = {correct: 0, correct_but_weak: 1, partially_correct: 2, incorrect: 3, cannot_judge: 4};
const all = rows(await sql`
  SELECT item_id, series, stratum, kind, loinc_id, loinc_label, result, relation, object_id, object_label, verdict,
         array_to_string(error_codes, '|') AS codes, error_note, weak_link, confidence, jev_verdict,
         round(jev_p_accurate, 2) AS jev_p_accurate, claim, context, derivation
  FROM review WHERE verdict IS NOT NULL ORDER BY series, loinc_label`)
  .map((d) => ({...d, codes: d.codes ? d.codes.split("|") : []}))
  .sort((a, b) => order[b.verdict] - order[a.verdict]);
```

```js
display(reviewBrowser(all, tax));
```

<style>
.rb { display: grid; grid-template-columns: 250px minmax(0, 1fr); gap: 1.25rem; align-items: start; max-width: none; font: .82rem/1.35 var(--sans-serif); }
@media (max-width: 860px) { .rb { grid-template-columns: 1fr; } }
.rb button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; text-align: left; }
.rb-search { width: 100%; box-sizing: border-box; padding: .4rem .55rem; font: inherit; border: 1px solid var(--theme-foreground-faintest); border-radius: 6px; background: var(--theme-background); color: var(--theme-foreground); }
.rb-facet { margin-top: 1rem; }
.rb-facet h3 { display: flex; justify-content: space-between; align-items: baseline; margin: 0 0 .3rem; font-size: .72rem; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--theme-foreground-muted); }
.rb-group { margin: .55rem 0 .1rem; font-size: .72rem; color: var(--theme-foreground-muted); }
.rb-val { display: block; width: 100%; padding: .2rem .35rem .28rem !important; border-radius: 5px; }
.rb-val:hover { background: var(--theme-background-alt); }
.rb-val.on { background: var(--theme-background-alt); box-shadow: inset 2px 0 0 var(--theme-foreground-focus); }
.rb-val.empty { opacity: .4; }
.rb-val-top { display: flex; gap: .35rem; align-items: baseline; }
.rb-check { flex: none; width: .8rem; color: var(--theme-foreground-focus); font-weight: 700; }
.rb-val-label { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rb-val.on .rb-val-label { font-weight: 600; }
.rb-val-n { flex: none; font-variant-numeric: tabular-nums; color: var(--theme-foreground-muted); }
.rb-track { display: block; height: 5px; margin: .2rem 0 0 1.15rem; border-radius: 3px; background: var(--theme-foreground-faintest); overflow: hidden; }
.rb-bar { display: flex; gap: 1px; height: 100%; border-radius: 3px; overflow: hidden; }
.rb-clear { font-size: .72rem; font-weight: 400; text-transform: none; letter-spacing: 0; color: var(--theme-foreground-focus) !important; text-decoration: underline; }
.rb-summary { margin-bottom: .6rem; }
.rb-count { display: flex; flex-wrap: wrap; gap: .35rem; align-items: center; font-size: .9rem; }
.rb-active { padding: .1rem .5rem !important; border: 1px solid var(--theme-foreground-faintest) !important; border-radius: 999px; font-size: .75rem; }
.rb-active:hover { border-color: var(--theme-foreground-muted) !important; }
.rb-mix { display: flex; gap: 2px; height: 10px; margin: .5rem 0 .3rem; border-radius: 4px; overflow: hidden; }
.rb-legend { display: flex; flex-wrap: wrap; gap: .2rem .9rem; color: var(--theme-foreground-muted); font-size: .76rem; }
.rb-dot { display: inline-block; width: .6rem; height: .6rem; margin-right: .35rem; border-radius: 50%; vertical-align: baseline; }
.rb-cards { display: grid; gap: .6rem; }
.rb-card { border: 1px solid var(--theme-foreground-faintest); border-left: 4px solid; border-radius: 8px; background: var(--theme-background-alt); }
.rb-card:hover, .rb-card.open { border-top-color: var(--theme-foreground-faint); border-right-color: var(--theme-foreground-faint); border-bottom-color: var(--theme-foreground-faint); }
.rb-card-head { display: block; width: 100%; box-sizing: border-box; padding: .65rem .9rem .7rem !important; border-radius: 8px; }
.rb-card-head:focus-visible { outline: 2px solid var(--theme-foreground-focus); outline-offset: -2px; }
.rb-card-top { display: flex; flex-wrap: wrap; gap: .2rem .8rem; align-items: baseline; font-size: .76rem; }
.rb-verdict { font-weight: 600; }
.rb-src { color: var(--theme-foreground-muted); }
.rb-jev { margin-left: auto; color: var(--theme-foreground-muted); }
.rb-jev .rb-dot { margin-left: .2rem; }
.rb-pair { display: flex; flex-wrap: wrap; gap: .1rem .5rem; margin-top: .35rem; font-size: .98rem; font-weight: 600; line-height: 1.3; overflow-wrap: anywhere; }
.rb-arrow { color: var(--theme-foreground-muted); font-weight: 400; }
.rb-meta { display: block; margin-top: .15rem; font-size: .74rem; color: var(--theme-foreground-muted); }
.rb-note { display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; margin-top: .45rem; }
.rb-chips { display: block; margin-top: .45rem; }
.rb-id { font-size: .72rem; color: var(--theme-foreground-muted); }
.rb-chip { display: inline-block; max-width: 100%; box-sizing: border-box; margin: 0 .25rem .2rem 0; padding: .05rem .45rem; border: 1px solid var(--theme-foreground-faintest); border-radius: 9px; font-size: .72rem; line-height: 1.25; vertical-align: top; }
.rb-detail { padding: 0 .9rem .9rem; }
.rb-detail p, .rb-detail dl { max-width: none; }
.rb-claim { margin: 0 0 .7rem; padding-top: .6rem; border-top: 1px solid var(--theme-foreground-faintest); font-weight: 600; }
.rb-detail dl { display: grid; grid-template-columns: 8.5rem minmax(0, 1fr); gap: .45rem .8rem; margin: 0; }
.rb-detail dt { color: var(--theme-foreground-muted); }
.rb-detail dd { margin: 0; }
.rb-paths { width: 100%; max-width: none; margin: 0; border-collapse: collapse; font-size: .76rem; }
.rb-paths th, .rb-paths td { padding: .2rem .5rem .2rem 0; text-align: left; border-bottom: 1px solid var(--theme-foreground-faintest); }
.rb-more { margin-top: .8rem; padding: .4rem .9rem !important; border: 1px solid var(--theme-foreground-faint) !important; border-radius: 6px; }
.rb-none { color: var(--theme-foreground-muted); }
</style>
