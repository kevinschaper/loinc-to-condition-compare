-- Draw the review sample. Deterministic: rows are ordered by a hash of their id, so a re-run
-- over unchanged inputs draws the same items. Run after 03_build.sql.
--   duckdb -c ".read pipeline/04_sample_review.sql"
CREATE OR REPLACE MACRO pick(id) AS md5('review-2026-11|' || id);

CREATE OR REPLACE TEMP TABLE a AS SELECT * FROM 'src/data/assertions.parquet';
CREATE OR REPLACE TEMP TABLE repo_pairs AS SELECT DISTINCT loinc_id, object_id FROM a WHERE source = 'legacy';

CREATE OR REPLACE TEMP TABLE curated_items AS
WITH tagged AS (
  SELECT a.*,
    CASE
      WHEN source = 'legacy' AND relation = 'INDICATES' THEN 'legacy · indicates'
      WHEN source = 'legacy' THEN 'legacy · rules out'
      WHEN source = 'kg_loinc2hpo' AND NOT EXISTS (SELECT 1 FROM repo_pairs r WHERE r.loinc_id = a.loinc_id AND r.object_id = a.object_id) THEN 'kg loinc2hpo · not in repo'
      WHEN source = 'kg_loinc2hpo' THEN NULL            -- same content as legacy; not sampled twice
      WHEN source = 'bonobo_imported' THEN 'bonobo imported'
      WHEN source = 'bonobo_new' THEN 'bonobo new · ' || object_type
      WHEN source = 'dismech' AND relation = 'BIOMARKER' THEN 'dismech · biomarker'
      WHEN source = 'dismech' THEN 'dismech · diagnostic test'
    END AS stratum
  FROM a),
ranked AS (SELECT *, row_number() OVER (PARTITION BY stratum ORDER BY pick(assertion_id)) AS rn FROM tagged WHERE stratum IS NOT NULL)
SELECT * FROM ranked
WHERE rn <= CASE stratum
  WHEN 'legacy · indicates' THEN 50 WHEN 'legacy · rules out' THEN 10
  WHEN 'kg loinc2hpo · not in repo' THEN 30 WHEN 'bonobo imported' THEN 20
  WHEN 'bonobo new · HP' THEN 100000 WHEN 'bonobo new · MONDO' THEN 100000   -- reviewed in full
  WHEN 'dismech · biomarker' THEN 45 WHEN 'dismech · diagnostic test' THEN 55 END;

-- 2-hop: 6 frequency tiers x 2 phenotype-spread classes, 12 pairs each.
CREATE OR REPLACE TEMP TABLE hop_strata AS
SELECT p.*, best_freq_tier AS tier,
  CASE WHEN min_hp_n_diseases <= 25
       THEN 'specific phenotype (≤25 diseases)' ELSE 'widespread phenotype (>25 diseases)' END AS spread
FROM 'src/data/twohop_pairs.parquet' p;

CREATE OR REPLACE TEMP TABLE hop_items AS
SELECT * FROM hop_strata
QUALIFY row_number() OVER (PARTITION BY tier, spread ORDER BY pick(assertion_id)) <= 12;

CREATE OR REPLACE TEMP TABLE hop_paths AS
SELECT loinc_id, mondo_id,
       list({'phenotype': hp_label, 'hp_id': hp_id, 'result_direction': result_direction,
             'frequency_in_disease': freq_tier, 'diseases_with_this_phenotype': hp_n_diseases,
             'd2p_source': d2p_source} ORDER BY hp_id) AS paths
FROM 'src/data/twohop_paths.parquet' GROUP BY loinc_id, mondo_id;

CREATE OR REPLACE TEMP TABLE items AS
SELECT assertion_id AS item_id, source, stratum,
       CASE object_type WHEN 'HP' THEN 'loinc_to_phenotype' ELSE 'loinc_to_disease' END AS kind,
       loinc_id, loinc_label, object_id, object_label, relation,
       array_to_string(outcomes, ', ') AS result,
       CASE
         WHEN object_type = 'HP' AND relation = 'INDICATES' THEN
           'A result of [' || array_to_string(outcomes, ', ') || '] on this test indicates the phenotype "' || object_label || '".'
         WHEN object_type = 'HP' THEN
           'A result of [' || array_to_string(outcomes, ', ') || '] on this test ' || lower(replace(relation, '_', ' ')) || ' the phenotype "' || object_label || '".'
         WHEN source = 'dismech' THEN
           'This test is ' || CASE relation WHEN 'BIOMARKER' THEN 'a biomarker measured in' WHEN 'DIAGNOSTIC_TEST' THEN 'a test used in diagnosing' ELSE 'a diagnostic test and biomarker for' END
           || ' the disease "' || object_label || '"' || CASE WHEN len(outcomes) > 0 THEN ' (expected result: ' || array_to_string(outcomes, ', ') || ')' ELSE '' END || '.'
         ELSE 'A result of [' || array_to_string(outcomes, ', ') || '] on this test ' || lower(replace(relation, '_', ' ')) || ' the disease "' || object_label || '".'
       END AS claim,
       context, NULL::JSON AS derivation
FROM curated_items
UNION ALL BY NAME
SELECT h.assertion_id AS item_id, 'kg_2hop' AS source, '2-hop · ' || tier || ' · ' || spread AS stratum, 'loinc_to_disease' AS kind,
       h.loinc_id, h.loinc_label, h.mondo_id AS object_id, h.mondo_label AS object_label, 'ASSOCIATED_WITH' AS relation,
       array_to_string(h.result_directions, ', ') AS result,
       'An abnormal result (' || array_to_string(h.result_directions, ' or ') || ') on this test is associated with the disease "' || h.mondo_label || '".' AS claim,
       NULL AS context, to_json(p.paths) AS derivation
FROM hop_items h JOIN hop_paths p USING (loinc_id, mondo_id);

COPY (SELECT * FROM items ORDER BY pick(item_id)) TO 'review/items.parquet' (FORMAT parquet);
COPY (SELECT * FROM items ORDER BY pick(item_id)) TO 'review/items.jsonl' (FORMAT json);
SELECT stratum, count(*) AS n FROM items GROUP BY ALL ORDER BY 1;
