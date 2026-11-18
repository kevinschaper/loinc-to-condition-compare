-- Build the tables the dashboard reads, from data/raw/*.parquet.
-- Run: duckdb -c ".read pipeline/03_build.sql"
--
-- Outputs (src/data/):
--   assertions.parquet     one row per curated LOINC -> HP|MONDO assertion, all curated sources
--   twohop_paths.parquet   one row per LOINC -> HP -> MONDO path through the KG
--   twohop_pairs.parquet   one row per inferred LOINC -> MONDO pair, with filter-variant flags
--   twohop_variants.parquet  size of each 2-hop filter variant and how much curated content it recovers
--   structural_metrics.parquet  long table of automatic quality metrics per source
--   source_overlap.parquet pairwise overlap of sources on identical assertions

CREATE OR REPLACE TEMP VIEW nodes AS SELECT * FROM 'data/raw/kg_nodes.parquet';
CREATE OR REPLACE TEMP VIEW closure AS SELECT * FROM 'data/raw/kg_closure.parquet';
CREATE OR REPLACE TEMP VIEW ic AS SELECT * FROM 'data/raw/kg_information_content.parquet';

CREATE OR REPLACE MACRO norm(s) AS lower(trim(regexp_replace(s, '\s+', ' ', 'g')));
CREATE OR REPLACE MACRO label_up(s) AS regexp_matches(lower(s), '(elevat|increas|\bhigh|\bhyper|excess|prolonged|positiv|polycyth|cytosis|philia\b|uria\b)');
CREATE OR REPLACE MACRO label_down(s) AS regexp_matches(lower(s), '(decreas|reduc|\blow\b|\bhypo|deficien|absent|absence|penia\b|shortened)');

-- ------------------------------------------------------------------ curated assertions
CREATE OR REPLACE TEMP TABLE raw_assertions AS
-- legacy loinc2hpoAnnotation: N / NEG rows mean "this result argues the phenotype is absent"
SELECT 'legacy' AS source, 'HP' AS object_type, loinc_id, NULL::VARCHAR AS loinc_label_source,
       hp_id AS object_id, NULL::VARCHAR AS object_label_source,
       CASE WHEN outcome IN ('N', 'NEG') THEN 'RULES_OUT' ELSE 'INDICATES' END AS relation,
       list(DISTINCT outcome ORDER BY outcome) AS outcomes,
       string_agg(DISTINCT scale, '|') AS scale,
       NULL::VARCHAR AS context,
       0 AS n_evidence, 0 AS n_snippets, []::VARCHAR[] AS refs,
       string_agg(DISTINCT curation, '; ') AS record
FROM 'data/raw/legacy_loinc2hpo.parquet'
GROUP BY loinc_id, hp_id, relation
UNION ALL BY NAME
-- the loinc2hpo edges as they sit in monarch-kg (the first hop of the 2-hop inference)
SELECT 'kg_loinc2hpo' AS source, 'HP' AS object_type, loinc_id, NULL AS loinc_label_source,
       hp_id AS object_id, NULL AS object_label_source, 'INDICATES' AS relation,
       list(DISTINCT CASE predicate WHEN 'biolink:positively_correlated_with' THEN 'H'
                                    WHEN 'biolink:negatively_correlated_with' THEN 'L' ELSE 'POS' END) AS outcomes,
       NULL AS scale, NULL AS context, 0 AS n_evidence, 0 AS n_snippets, []::VARCHAR[] AS refs,
       string_agg(DISTINCT predicate, '; ') AS record
FROM 'data/raw/kg_loinc2hpo.parquet'
GROUP BY loinc_id, hp_id
UNION ALL BY NAME
SELECT CASE WHEN imported THEN 'bonobo_imported' ELSE 'bonobo_new' END AS source, object_type, loinc_id,
       any_value(loinc_label) AS loinc_label_source, object_id, any_value(object_label) AS object_label_source,
       relation,
       list(DISTINCT outcome ORDER BY outcome) AS outcomes,
       string_agg(DISTINCT scale, '|') AS scale,
       string_agg(DISTINCT concat_ws(' — ',
            band_name || CASE WHEN lower_bound IS NOT NULL OR upper_bound IS NOT NULL
                 THEN ' [' || coalesce(lower_bound::VARCHAR, '') || ', ' || coalesce(upper_bound::VARCHAR, '') || ') ' || coalesce(unit, '') ELSE '' END,
            population, interpretation), ' ‖ ') AS context,
       max(n_evidence_band + n_evidence_range) AS n_evidence, max(n_snippets) AS n_snippets,
       list_distinct(flatten(list("references"))) AS refs,
       string_agg(DISTINCT shard, '; ') AS record
FROM 'data/raw/bonobo_targets.parquet'
WHERE object_id IS NOT NULL
GROUP BY source, object_type, loinc_id, object_id, relation
UNION ALL BY NAME
SELECT 'dismech' AS source, 'MONDO' AS object_type, loinc_id, any_value(loinc_label) AS loinc_label_source,
       mondo_id AS object_id, any_value(mondo_label) AS object_label_source,
       CASE WHEN bool_or(section = 'diagnosis') AND bool_or(section = 'biochemical') THEN 'DIAGNOSTIC_TEST+BIOMARKER'
            WHEN bool_or(section = 'diagnosis') THEN 'DIAGNOSTIC_TEST' ELSE 'BIOMARKER' END AS relation,
       list(DISTINCT presence ORDER BY presence) FILTER (presence IS NOT NULL) AS outcomes,
       NULL AS scale,
       string_agg(DISTINCT concat_ws(' — ', section || ': ' || entry_name, 'presence=' || presence_raw, entry_description), ' ‖ ') AS context,
       sum(n_evidence)::INT AS n_evidence, sum(n_snippets)::INT AS n_snippets,
       list_distinct(flatten(list("references"))) AS refs,
       string_agg(DISTINCT record, '; ') AS record
FROM 'data/raw/dismech_loinc.parquet'
WHERE mondo_id IS NOT NULL
GROUP BY loinc_id, mondo_id;

CREATE OR REPLACE TEMP TABLE assertions AS
SELECT
  substr(md5(a.source || '|' || a.loinc_id || '|' || a.object_id || '|' || a.relation), 1, 12) AS assertion_id,
  a.source, a.object_type, a.loinc_id,
  coalesce(ln.name, a.loinc_label_source) AS loinc_label,
  a.object_id, coalesce(o.name, a.object_label_source) AS object_label,
  a.relation, a.outcomes, a.scale, a.context, a.n_evidence, a.n_snippets, len(a.refs) AS n_refs, a.refs, a.record,
  -- structural checks
  ln.id IS NOT NULL AS loinc_resolves,
  o.id IS NOT NULL AS object_resolves,
  coalesce(lower(o.deprecated) = 'true', false) AS object_deprecated,
  CASE WHEN a.loinc_label_source IS NULL OR ln.name IS NULL THEN NULL ELSE norm(a.loinc_label_source) = norm(ln.name) END AS loinc_label_matches,
  CASE WHEN a.object_label_source IS NULL OR o.name IS NULL THEN NULL ELSE norm(a.object_label_source) = norm(o.name) END AS object_label_matches,
  CASE
    WHEN a.object_type <> 'HP' OR a.relation <> 'INDICATES' OR o.name IS NULL THEN 'not_applicable'
    WHEN list_has_any(a.outcomes, ['H', 'HIGH', 'CRITICAL_HIGH']) AND NOT list_has_any(a.outcomes, ['L', 'LOW', 'CRITICAL_LOW'])
      THEN CASE WHEN label_down(o.name) AND NOT label_up(o.name) THEN 'conflict' WHEN label_up(o.name) THEN 'consistent' ELSE 'undetermined' END
    WHEN list_has_any(a.outcomes, ['L', 'LOW', 'CRITICAL_LOW']) AND NOT list_has_any(a.outcomes, ['H', 'HIGH', 'CRITICAL_HIGH'])
      THEN CASE WHEN label_up(o.name) AND NOT label_down(o.name) THEN 'conflict' WHEN label_down(o.name) THEN 'consistent' ELSE 'undetermined' END
    ELSE 'not_applicable'
  END AS direction_check
FROM raw_assertions a
LEFT JOIN nodes ln ON ln.id = a.loinc_id
LEFT JOIN nodes o ON o.id = a.object_id;

COPY (SELECT * FROM assertions ORDER BY source, loinc_id, object_id) TO 'src/data/assertions.parquet' (FORMAT parquet);

-- ------------------------------------------------------------------ 2-hop inference
-- LOINC -[loinc2hpo]-> HP <-[has_phenotype]- MONDO, read backwards on the second hop.
CREATE OR REPLACE TEMP TABLE d2p AS
SELECT *,
  CASE
    WHEN has_percentage IS NOT NULL THEN has_percentage / 100.0
    WHEN frequency_qualifier = 'HP:0040280' THEN 1.0
    WHEN frequency_qualifier = 'HP:0040281' THEN 0.90
    WHEN frequency_qualifier = 'HP:0040282' THEN 0.55
    WHEN frequency_qualifier = 'HP:0040283' THEN 0.17
    WHEN frequency_qualifier = 'HP:0040284' THEN 0.025
    WHEN frequency_qualifier = 'HP:0040285' THEN 0.0
  END AS freq
FROM 'data/raw/kg_d2p.parquet';

CREATE OR REPLACE TEMP TABLE hp_spread AS
SELECT hp_id, count(DISTINCT mondo_id) AS hp_n_diseases FROM d2p WHERE NOT negated GROUP BY hp_id;

CREATE OR REPLACE MACRO freq_tier(f) AS CASE
  WHEN f IS NULL THEN 'unknown' WHEN f < 0.05 THEN 'very rare (<5%)'
  WHEN f < 0.30 THEN 'occasional (5-29%)' WHEN f < 0.80 THEN 'frequent (30-79%)'
  WHEN f < 1.0 THEN 'very frequent (80-99%)' ELSE 'obligate (100%)' END;

-- Disease-phenotype edges that say the phenotype is NOT a feature (negated, or a stated frequency
-- of 0%) are never chained: a path through one is not an association. They are dropped here, and
-- only counted so the dashboard can say how many there were.
CREATE OR REPLACE TEMP TABLE all_paths AS
SELECT l.loinc_id, d.mondo_id, d.negated, d.freq, (NOT d.negated AND coalesce(d.freq, 1) > 0) AS live
FROM 'data/raw/kg_loinc2hpo.parquet' l JOIN d2p d USING (hp_id);

COPY (
  WITH pr AS (SELECT loinc_id, mondo_id, bool_or(live) AS any_live FROM all_paths GROUP BY ALL)
  SELECT (SELECT count(*) FROM all_paths WHERE negated) AS paths_negated,
         (SELECT count(*) FROM all_paths WHERE NOT negated AND NOT live) AS paths_zero_frequency,
         (SELECT count(*) FROM all_paths WHERE live) AS paths_kept,
         count(*) FILTER (NOT any_live) AS pairs_dropped, count(*) FILTER (any_live) AS pairs_kept
  FROM pr
) TO 'src/data/twohop_excluded.parquet' (FORMAT parquet);

CREATE OR REPLACE TEMP TABLE twohop_paths AS
SELECT l.loinc_id, l.predicate AS loinc_hp_predicate,
       CASE l.predicate WHEN 'biolink:positively_correlated_with' THEN 'high'
                        WHEN 'biolink:negatively_correlated_with' THEN 'low' ELSE 'positive/abnormal' END AS result_direction,
       l.hp_id, d.mondo_id, d.primary_knowledge_source AS d2p_source,
       d.has_evidence[1] AS d2p_evidence_code, d.frequency_qualifier, d.has_percentage, d.has_count, d.has_total,
       d.freq, freq_tier(d.freq) AS freq_tier, s.hp_n_diseases, i.ic AS hp_ic,
       EXISTS (SELECT 1 FROM 'data/raw/legacy_loinc2hpo.parquet' g WHERE g.loinc_id = l.loinc_id AND g.hp_id = l.hp_id) AS first_hop_in_repo
FROM 'data/raw/kg_loinc2hpo.parquet' l
JOIN d2p d USING (hp_id)
LEFT JOIN hp_spread s USING (hp_id)
LEFT JOIN ic i ON i.term = l.hp_id
WHERE NOT d.negated AND coalesce(d.freq, 1) > 0;

COPY (
  SELECT p.*, ln.name AS loinc_label, h.name AS hp_label, m.name AS mondo_label
  FROM twohop_paths p LEFT JOIN nodes ln ON ln.id = p.loinc_id LEFT JOIN nodes h ON h.id = p.hp_id LEFT JOIN nodes m ON m.id = p.mondo_id
  ORDER BY loinc_id, mondo_id
) TO 'src/data/twohop_paths.parquet' (FORMAT parquet);

CREATE OR REPLACE TEMP TABLE twohop_pairs AS
WITH agg AS (
  SELECT loinc_id, mondo_id,
         count(*) AS n_paths,
         list(DISTINCT hp_id) AS hp_ids,
         list(DISTINCT result_direction) AS result_directions,
         max(freq) AS best_freq,
         min(hp_n_diseases) AS min_hp_n_diseases,
         max(hp_ic) AS max_hp_ic,
         list(DISTINCT d2p_source) AS d2p_sources,
         bool_or(first_hop_in_repo) AS first_hop_in_repo
  FROM twohop_paths GROUP BY loinc_id, mondo_id)
SELECT a.*, freq_tier(best_freq) AS best_freq_tier,
       true AS v_all,
       best_freq IS NOT NULL AS v_freq_known,
       best_freq >= 0.05 AS v_freq_ge_5,
       best_freq >= 0.30 AS v_freq_ge_30,
       best_freq >= 0.80 AS v_freq_ge_80,
       (best_freq IS NULL OR best_freq >= 0.30) AS v_freq_ge_30_or_unknown,
       min_hp_n_diseases <= 25 AS v_specific_hp_le_25,
       min_hp_n_diseases <= 25 AND (best_freq IS NULL OR best_freq >= 0.30) AS v_specific_and_freq
FROM agg a;

-- Does a curated LOINC -> MONDO assertion agree with each inferred pair? Exact disease, or one
-- disease is an ancestor of the other in MONDO (closure includes the reflexive pair).
CREATE OR REPLACE TEMP TABLE curated_disease AS
SELECT DISTINCT source, loinc_id, object_id AS mondo_id FROM assertions
WHERE object_type = 'MONDO' AND source IN ('dismech', 'bonobo_new') AND relation NOT IN ('ARGUES_AGAINST', 'RULES_OUT', 'UNINFORMATIVE');

CREATE OR REPLACE TEMP TABLE pair_match AS
SELECT t.loinc_id, t.mondo_id,
       bool_or(c.source = 'dismech' AND c.mondo_id = t.mondo_id) AS in_dismech_exact,
       bool_or(c.source = 'dismech') AS in_dismech_related,
       bool_or(c.source = 'bonobo_new' AND c.mondo_id = t.mondo_id) AS in_bonobo_exact,
       bool_or(c.source = 'bonobo_new') AS in_bonobo_related
FROM twohop_pairs t
JOIN curated_disease c ON c.loinc_id = t.loinc_id
 AND (c.mondo_id = t.mondo_id
      OR EXISTS (SELECT 1 FROM closure k WHERE k.subject_id = c.mondo_id AND k.object_id = t.mondo_id)
      OR EXISTS (SELECT 1 FROM closure k WHERE k.subject_id = t.mondo_id AND k.object_id = c.mondo_id))
GROUP BY t.loinc_id, t.mondo_id;

COPY (
  SELECT substr(md5('kg_2hop|' || t.loinc_id || '|' || t.mondo_id), 1, 12) AS assertion_id,
         t.*, ln.name AS loinc_label, m.name AS mondo_label,
         coalesce(pm.in_dismech_exact, false) AS in_dismech_exact, coalesce(pm.in_dismech_related, false) AS in_dismech_related,
         coalesce(pm.in_bonobo_exact, false) AS in_bonobo_exact, coalesce(pm.in_bonobo_related, false) AS in_bonobo_related
  FROM twohop_pairs t
  LEFT JOIN pair_match pm USING (loinc_id, mondo_id)
  LEFT JOIN nodes ln ON ln.id = t.loinc_id LEFT JOIN nodes m ON m.id = t.mondo_id
  ORDER BY loinc_id, mondo_id
) TO 'src/data/twohop_pairs.parquet' (FORMAT parquet);

-- Per variant: how many pairs, and how much of the curated LOINC -> disease content it reaches.
-- "Reachable" curated pairs are those whose LOINC code has any loinc2hpo edge in the KG at all.
CREATE OR REPLACE TEMP TABLE variant_long AS
UNPIVOT (SELECT loinc_id, mondo_id, COLUMNS('^v_') FROM twohop_pairs) ON COLUMNS('^v_') INTO NAME variant VALUE keep;

COPY (
  WITH kept AS (SELECT variant, loinc_id, mondo_id FROM variant_long WHERE keep),
  size AS (SELECT variant, count(*) AS n_pairs, count(DISTINCT loinc_id) AS n_loinc, count(DISTINCT mondo_id) AS n_disease FROM kept GROUP BY variant),
  cur AS (SELECT c.*, c.loinc_id IN (SELECT loinc_id FROM 'data/raw/kg_loinc2hpo.parquet') AS reachable FROM curated_disease c),
  rec AS (
    SELECT v.variant, c.source,
           count(*) AS curated_pairs,
           count(*) FILTER (c.reachable) AS curated_reachable,
           count(*) FILTER (EXISTS (SELECT 1 FROM kept k WHERE k.variant = v.variant AND k.loinc_id = c.loinc_id AND k.mondo_id = c.mondo_id)) AS recovered_exact,
           count(*) FILTER (EXISTS (SELECT 1 FROM kept k WHERE k.variant = v.variant AND k.loinc_id = c.loinc_id AND (k.mondo_id = c.mondo_id
                 OR EXISTS (SELECT 1 FROM closure x WHERE x.subject_id = c.mondo_id AND x.object_id = k.mondo_id)
                 OR EXISTS (SELECT 1 FROM closure x WHERE x.subject_id = k.mondo_id AND x.object_id = c.mondo_id)))) AS recovered_related
    FROM (SELECT DISTINCT variant FROM variant_long) v CROSS JOIN cur c GROUP BY v.variant, c.source)
  SELECT s.*, r.source AS curated_source, r.curated_pairs, r.curated_reachable, r.recovered_exact, r.recovered_related
  FROM size s JOIN rec r USING (variant) ORDER BY n_pairs DESC, curated_source
) TO 'src/data/twohop_variants.parquet' (FORMAT parquet);

-- ------------------------------------------------------------------ structural metrics (long)
COPY (
  WITH base AS (SELECT * FROM assertions),
  m AS (
    SELECT source, object_type,
      count(*)::DOUBLE AS n_assertions,
      count(DISTINCT loinc_id)::DOUBLE AS n_loinc,
      count(DISTINCT object_id)::DOUBLE AS n_objects,
      avg((NOT loinc_resolves)::INT) AS loinc_unresolved_rate,
      avg((NOT object_resolves)::INT) AS object_unresolved_rate,
      avg(object_deprecated::INT) AS object_deprecated_rate,
      avg((NOT loinc_label_matches)::INT) AS loinc_label_mismatch_rate,
      avg((NOT object_label_matches)::INT) AS object_label_mismatch_rate,
      avg((direction_check = 'conflict')::INT) FILTER (direction_check <> 'not_applicable') AS direction_conflict_rate,
      count(*) FILTER (direction_check <> 'not_applicable')::DOUBLE AS direction_checked,
      avg((n_refs > 0)::INT) AS cited_rate,
      avg((n_snippets > 0)::INT) AS quoted_rate,
      count(*)::DOUBLE / count(DISTINCT loinc_id) AS assertions_per_loinc
    FROM base GROUP BY source, object_type)
  UNPIVOT m ON COLUMNS(* EXCLUDE (source, object_type)) INTO NAME metric VALUE value
) TO 'src/data/structural_metrics.parquet' (FORMAT parquet);

-- ------------------------------------------------------------------ overlap between curated sources
COPY (
  WITH k AS (SELECT DISTINCT source, object_type, loinc_id, object_id FROM assertions WHERE relation NOT IN ('RULES_OUT', 'ARGUES_AGAINST', 'UNINFORMATIVE')
             UNION ALL SELECT DISTINCT 'kg_2hop', 'MONDO', loinc_id, mondo_id FROM twohop_pairs)
  SELECT a.source AS source_a, b.source AS source_b, a.object_type,
         count(*) AS shared_pairs,
         count(DISTINCT a.loinc_id) AS shared_loinc
  FROM k a JOIN k b ON a.object_type = b.object_type AND a.loinc_id = b.loinc_id AND a.object_id = b.object_id AND a.source < b.source
  GROUP BY ALL ORDER BY shared_pairs DESC
) TO 'src/data/source_overlap.parquet' (FORMAT parquet);

COPY (
  SELECT source, object_type, count(DISTINCT loinc_id) AS n_loinc FROM assertions GROUP BY ALL
  UNION ALL SELECT 'kg_2hop', 'MONDO', count(DISTINCT loinc_id) FROM twohop_pairs
) TO 'src/data/source_sizes.parquet' (FORMAT parquet);

-- 2-hop population by review stratum, so sampled error rates can be weighted back up to each variant.
COPY (
  WITH t AS (
    SELECT *, best_freq_tier AS tier,
      CASE WHEN min_hp_n_diseases <= 25 THEN 'specific phenotype (≤25 diseases)' ELSE 'widespread phenotype (>25 diseases)' END AS spread
    FROM twohop_pairs)
  SELECT tier, spread, count(*) AS n_pairs, COLUMNS('^v_')::INT AS '\0'
  FROM (SELECT tier, spread, COLUMNS('^v_') FROM t) GROUP BY ALL
) TO 'src/data/twohop_strata_wide.parquet' (FORMAT parquet);
