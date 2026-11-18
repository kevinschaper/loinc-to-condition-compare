---
title: Methods
sql:
  review: ./data/review_items.parquet
---

# Methods

```js
import * as Plot from "npm:@observablehq/plot";
import {rows, pct, VERDICTS, VERDICT_LABEL, tile} from "./components/charts.js";
const versions = FileAttachment("./data/source_versions.json").json();
```

## Sources

| Source | What is taken | Version |
|---|---|---|
| loinc2hpoAnnotation | `loinc2hpo-annotations.tsv` on `main`. N and NEG rows are read as *rules out*. | ${versions.loinc2hpoAnnotation.commit} · ${versions.loinc2hpoAnnotation.date} |
| BONOBO | Every band target in `annotations/*.yaml`. The `allergy` shard is the import from loinc2hpoAnnotation; the other eight are new. | ${versions.bonobo.commit} · ${versions.bonobo.date} |
| DisMech | LOINC codes on `diagnosis` and `biochemical` entries of `kb/disorders/*.yaml`, paired with the record's MONDO term. | ${versions.dismech.commit} · ${versions.dismech.date} |
| monarch-kg | `infores:loinc2hpo` edges and disease-to-phenotype edges, queried from the public bucket with DuckDB. | ${versions["monarch-kg"].version} |

## The 2-hop inference

A path is a loinc2hpo edge and a disease-to-phenotype edge that meet on the same HP term. Paths are grouped into LOINC–disease pairs. Disease-to-phenotype edges that are negated, or that state a frequency of 0%, are left out before the join, so no path runs through them. Frequency is the stated percentage where there is one, and otherwise the midpoint of the HPO frequency class. A pair takes the frequency of its best path, and the spread of its most specific phenotype (the number of diseases annotated with it).

The join is on the exact HP term. A disease annotated with a child of the test's phenotype is not matched.

## The review

- **Sample.** BONOBO's new links were reviewed in full (150 to HP, 45 to MONDO). The others were sampled: 60 legacy, 30 KG loinc2hpo edges absent from the repo, 20 imported BONOBO, 100 DisMech, and 144 inferred pairs (12 in each of 6 frequency tiers × 2 spread classes). The draw is a fixed hash order, so it repeats. A first version of the inference kept negated and 0% edges; the 24 pairs reviewed from that stratum were dropped along with it, and their verdicts remain in `review/judgments/`.
- **Reviewers.** Ten agents each judged a mixed batch of about 57 items against `review/PROTOCOL.md` from medical knowledge alone, with no lookups. The source name was withheld, though curator context and the inferred path show what kind of source an item came from.
- **Verdicts.** *Correct*, *correct but weak* (true, but nonspecific or rare), *partially correct* (a concrete flaw), *incorrect*, *cannot judge*.
- **Taxonomy.** Built from an open-coding pilot of 88 items, then applied as a closed list. Two codes were added afterwards from items coded "other".
- **Second opinion.** Jev (TypeSafe System One) judged the same claims with the same four verdicts. It returns a choice and probabilities, no explanation and no error code.
- **2-hop estimates.** Each stratum's sample rates are weighted by the number of pairs of that stratum a variant keeps.

## How far to trust the verdicts

```js
const conf = rows(await sql`SELECT verdict, jev_verdict, count(*)::INT AS n FROM review WHERE verdict IS NOT NULL AND jev_verdict IS NOT NULL GROUP BY ALL`);
const N = conf.reduce((s, d) => s + d.n, 0);
const exact = conf.filter((d) => d.verdict === d.jev_verdict).reduce((s, d) => s + d.n, 0) / N;
const bin = conf.filter((d) => (d.verdict === "correct") === (d.jev_verdict === "correct")).reduce((s, d) => s + d.n, 0) / N;
const sev = conf.filter((d) => (d.verdict === "incorrect") === (d.jev_verdict === "incorrect")).reduce((s, d) => s + d.n, 0) / N;
// Cohen's kappa on correct / not correct
const pa = conf.filter((d) => d.verdict === "correct").reduce((s, d) => s + d.n, 0) / N;
const pj = conf.filter((d) => d.jev_verdict === "correct").reduce((s, d) => s + d.n, 0) / N;
const pe = pa * pj + (1 - pa) * (1 - pj);
const kappa = (bin - pe) / (1 - pe);
const pilot = rows(await sql`
  SELECT count(*)::INT AS n, avg((verdict = pilot_verdict)::INT) AS exact, avg(((verdict = 'correct') = (pilot_verdict = 'correct'))::INT) AS bin
  FROM review WHERE pilot_verdict IS NOT NULL AND verdict IS NOT NULL`)[0];
```

<div class="grid grid-cols-4">
  ${tile("Agent and Jev, same verdict", pct(exact), `${N} items, four verdicts`)}
  ${tile("Agree on correct / not correct", pct(bin), `Cohen's κ ${kappa.toFixed(2)}`)}
  ${tile("Agree on incorrect / not", pct(sev), "the most severe verdict")}
  ${tile("Two agent passes agree", pct(pilot.exact), `${pilot.n} items judged in the pilot and again in the review · ${pct(pilot.bin)} on correct / not`)}
</div>

<div class="card">${resize((width) => Plot.plot({
  title: "Agent verdict against Jev verdict",
  subtitle: "Count of items. The diagonal is agreement.",
  width: Math.min(width, 640), height: 300, marginLeft: 150, marginTop: 50,
  x: {domain: VERDICTS.slice(0, 4).map((v) => VERDICT_LABEL[v]), axis: "top", label: "Jev", tickSize: 0},
  y: {domain: VERDICTS.slice(0, 4).map((v) => VERDICT_LABEL[v]), label: "Agent", tickSize: 0},
  color: {type: "linear", range: ["#cde2fb", "#0d366b"]},
  marks: [
    Plot.cell(conf, {x: (d) => VERDICT_LABEL[d.jev_verdict], y: (d) => VERDICT_LABEL[d.verdict], fill: "n", inset: 1, rx: 3, tip: true}),
    Plot.text(conf, {x: (d) => VERDICT_LABEL[d.jev_verdict], y: (d) => VERDICT_LABEL[d.verdict], text: "n", fill: (d) => (d.n > 60 ? "white" : "#0b0b0b")})
  ]
}))}</div>

What this supports and what it does not:

- **Comparisons between sources are the sturdy part.** The same reviewers and protocol judged every source, and the gaps between sources are large against the disagreement between judges.
- **Absolute rates are soft.** A share "judged correct" is not a measured precision. No human curator has labelled these items.
- **"Partially correct" is the least stable verdict.** It is where the two judges disagree most, and it mixes minor imprecision with real flaws. Read *incorrect* and *correct* as the firmer ends.
- **The reviewers are the same kind of model that curated BONOBO and DisMech.** Shared blind spots would flatter those two sources. Jev is a different model and broadly agrees on the ranking, which limits this concern without removing it.
- **Small cells.** A 2-hop stratum has 12 reviewed pairs. The stratum figures are indicative; the weighted variant figures pool them.
- **Recovery of curated pairs is not recall.** It counts curated LOINC–disease pairs the inference also produces. A curated pair on a LOINC code with no loinc2hpo edge cannot be produced at all.

## Rebuilding

`just fetch kg build` refreshes the data, `just sample` redraws the sample, `just jev` and the reviewing agents add verdicts, and `just review-tables site` rebuilds the dashboard. The parquet files under `src/data/` are committed so the site builds without access to the sources.
