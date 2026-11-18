# LOINC → condition compare

A dashboard that reviews and compares associations from LOINC lab tests to HPO phenotypes and MONDO diseases across four sources:

| Source | Links |
|---|---|
| `monarch-initiative/loinc2hpoAnnotation` (legacy) | LOINC → HP |
| `monarch-initiative/bonobo`, new content only | LOINC → HP, LOINC → MONDO |
| `monarch-initiative/dismech` | LOINC → MONDO |
| 2-hop inference through monarch-kg (test → phenotype ← disease) | LOINC → MONDO |

The site is [Observable Framework](https://observablehq.com/framework/): static HTML that reads parquet files in the browser with DuckDB-WASM. The parquet files are built with DuckDB.

## Layout

| Path | What it is |
|---|---|
| `pipeline/00_fetch_sources.sh` | Shallow-clones the three curated sources into `sources/` |
| `pipeline/01_kg_extract.sql` | Pulls the monarch-kg slices from the public bucket into `data/raw/` |
| `pipeline/02_extract_sources.py` | Flattens the curated sources to one row per link |
| `pipeline/03_build.sql` | Builds the assertion table, the 2-hop paths, pairs and filter variants, and the automatic checks |
| `pipeline/04_sample_review.sql` | Draws the stratified review sample (deterministic) |
| `pipeline/05_review_tables.py` | Joins items, verdicts and taxonomy into the tables the site reads |
| `review/PROTOCOL.md`, `review/taxonomy.yaml` | What the reviewers were told, and the error codes |
| `review/pilot/`, `review/judgments/` | The open-coding pilot, the ten agent batches, and Jev's verdicts |
| `review/jev_judge.py` | Second-opinion verdicts from Jev (needs `JEV_API_KEY`) |
| `src/` | The dashboard pages; `src/data/*.parquet` is what they read |

## Run

```bash
just fetch          # clone sources (needs gh access to the private bonobo repo)
just kg build       # extract and build the tables
just sample         # draw review items into review/batches/
just jev            # Jev verdicts
just review-tables  # after the agent verdicts are in review/judgments/
just dev            # preview at http://127.0.0.1:3000
```

The agent review is not scripted: each file in `review/batches/` was given to a subagent with `review/PROTOCOL.md` and `review/taxonomy.yaml`, and its output saved as `review/judgments/agent_batch_NN.jsonl`.

Review verdicts are model judgments, not curator labels. The Methods page says what they support.
