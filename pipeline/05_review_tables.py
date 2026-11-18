"""Join the review items with the verdicts and write the review tables the dashboard reads.

    uv run pipeline/05_review_tables.py

Inputs:  review/items.parquet, review/judgments/agent_batch_*.jsonl, review/judgments/jev.jsonl,
         review/pilot/*.out.jsonl, review/taxonomy.yaml, src/data/twohop_strata_wide.parquet
Outputs (src/data/): review_items, review_errors, taxonomy, twohop_variant_quality (.parquet)
"""
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "duckdb", "pandas", "pyarrow"]
# ///
import pathlib

import duckdb
import pandas as pd
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
con = duckdb.connect()
con.execute(f"SET file_search_path = '{ROOT}'")

tax = yaml.safe_load((ROOT / "review" / "taxonomy.yaml").read_text())
rows = [{"group_id": g["id"], "group_name": g["name"], "group_description": g["description"], "group_order": gi,
         "code": c["id"], "code_name": c["name"], "definition": c["definition"], "code_order": gi * 100 + ci,
         "pilot_themes": c.get("pilot_themes") or []}
        for gi, g in enumerate(tax["groups"]) for ci, c in enumerate(g["codes"])]
con.register("taxonomy_df", pd.DataFrame(rows))
con.register("gaps_df", pd.DataFrame(tax.get("known_gaps") or []))
con.execute("COPY gaps_df TO 'src/data/taxonomy_gaps.parquet' (FORMAT parquet)")
con.execute("COPY taxonomy_df TO 'src/data/taxonomy.parquet' (FORMAT parquet)")

con.execute("""
CREATE TABLE agent AS
SELECT item_id, verdict, error_codes, error_note, weak_link, confidence
FROM read_json('review/judgments/agent_batch_*.jsonl',
     columns = {item_id: 'VARCHAR', verdict: 'VARCHAR', error_codes: 'VARCHAR[]', error_note: 'VARCHAR', weak_link: 'VARCHAR', confidence: 'VARCHAR'});
-- A few items the reviewers coded "other" are moved to codes added after the review; see review/recode.tsv.
CREATE TABLE recode AS SELECT * FROM read_csv('review/recode.tsv', delim = '\t', header = true);
UPDATE agent SET error_codes = list_transform(error_codes, lambda c: CASE WHEN c = 'other' THEN r.to_code ELSE c END)
FROM recode r WHERE r.item_id = agent.item_id;
CREATE TABLE jev AS SELECT * FROM read_json_auto('review/judgments/jev.jsonl');
CREATE TABLE pilot AS SELECT item_id, verdict AS pilot_verdict, error_theme AS pilot_theme
FROM read_json('review/pilot/*.out.jsonl', columns = {item_id: 'VARCHAR', verdict: 'VARCHAR', error_theme: 'VARCHAR'});

CREATE TABLE review_items AS
SELECT i.item_id, i.source, i.stratum,
       CASE WHEN i.stratum LIKE 'legacy%' THEN 'Legacy loinc2hpo'
            WHEN i.stratum LIKE 'kg loinc2hpo%' THEN 'KG loinc2hpo, absent from repo'
            WHEN i.stratum = 'bonobo imported' THEN 'BONOBO imported → HP'
            WHEN i.stratum = 'bonobo new · HP' THEN 'BONOBO new → HP'
            WHEN i.stratum = 'bonobo new · MONDO' THEN 'BONOBO new → MONDO'
            WHEN i.source = 'dismech' THEN 'DisMech → MONDO'
            ELSE '2-hop inference (sample)' END AS series, i.kind, i.loinc_id, i.loinc_label, i.object_id, i.object_label, i.relation, i.result,
       i.claim, i.context, i.derivation::VARCHAR AS derivation,
       regexp_matches(i.loinc_label, '(--|post |challenge|XXX)') AS timed_test,
       CASE WHEN i.source = 'kg_2hop' THEN split_part(i.stratum, ' · ', 2) END AS tier,
       CASE WHEN i.source = 'kg_2hop' THEN split_part(i.stratum, ' · ', 3) END AS spread,
       a.verdict, a.error_codes, a.error_codes[1] AS primary_error, a.error_note, nullif(a.weak_link, '') AS weak_link, a.confidence,
       a.verdict IN ('incorrect', 'partially_correct') AS is_error,
       a.verdict = 'incorrect' AS is_incorrect,
       a.verdict = 'correct_but_weak' AS is_weak,
       j.verdict AS jev_verdict, j.p_accurate AS jev_p_accurate, j.p_useful AS jev_p_useful, j.confidence AS jev_confidence, j.judge AS jev_model,
       p.pilot_verdict, p.pilot_theme
       , tp.first_hop_in_repo
FROM 'review/items.parquet' i
LEFT JOIN 'src/data/twohop_pairs.parquet' tp ON tp.assertion_id = i.item_id AND i.source = 'kg_2hop'
LEFT JOIN agent a USING (item_id) LEFT JOIN jev j USING (item_id) LEFT JOIN pilot p USING (item_id);
COPY review_items TO 'src/data/review_items.parquet' (FORMAT parquet);

COPY (
  SELECT r.item_id, r.source, r.stratum, r.verdict, u.code, u.pos = 1 AS is_primary, t.group_name, t.code_name
  FROM review_items r, unnest(r.error_codes) WITH ORDINALITY AS u(code, pos)
  LEFT JOIN taxonomy_df t ON t.code = u.code
) TO 'src/data/review_errors.parquet' (FORMAT parquet);

-- 2-hop: weight each stratum's sampled rates by how many pairs of that stratum a variant keeps.
COPY (
  WITH s AS (
    SELECT tier, spread, count(*) AS n_reviewed,
           avg(is_incorrect::INT) AS p_incorrect, avg(is_error::INT) AS p_error,
           avg(is_weak::INT) AS p_weak, avg((verdict = 'correct')::INT) AS p_correct
    FROM review_items WHERE source = 'kg_2hop' AND verdict IS NOT NULL AND verdict <> 'cannot_judge' GROUP BY ALL),
  pop AS (UNPIVOT 'src/data/twohop_strata_wide.parquet' ON COLUMNS('^v_') INTO NAME variant VALUE keep)
  SELECT variant, sum(n_pairs) AS n_pairs, sum(n_reviewed) AS n_reviewed,
         sum(n_pairs * p_correct) / sum(n_pairs) AS p_correct,
         sum(n_pairs * p_weak) / sum(n_pairs) AS p_weak,
         sum(n_pairs * (p_error - p_incorrect)) / sum(n_pairs) AS p_partial,
         sum(n_pairs * p_incorrect) / sum(n_pairs) AS p_incorrect,
         -- standard error of a stratified proportion, for the "correct" share
         sqrt(sum(power(n_pairs, 2) * p_correct * (1 - p_correct) / n_reviewed)) / sum(n_pairs) AS se_correct,
         sum(n_pairs * p_correct) AS est_correct_pairs
  FROM pop JOIN s USING (tier, spread) WHERE keep = 1 GROUP BY variant ORDER BY n_pairs DESC
) TO 'src/data/twohop_variant_quality.parquet' (FORMAT parquet);
""")
print(con.sql("SELECT source, count(*) n, count(verdict) judged, count(jev_verdict) jev FROM review_items GROUP BY 1 ORDER BY 1"))
