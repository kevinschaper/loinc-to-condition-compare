-- Pull the slices of monarch-kg this project needs, straight from the public bucket.
-- Run: duckdb -c ".read pipeline/01_kg_extract.sql"
INSTALL httpfs; LOAD httpfs;
ATTACH 'https://data.monarchinitiative.org/monarch-kg/latest/monarch-kg.duckdb' AS kg (READ_ONLY);

-- LOINC -> HP edges as loaded from loinc2hpoAnnotation by loinc-ingest.
COPY (
  SELECT subject AS loinc_id, predicate, object AS hp_id, negated, knowledge_level, agent_type,
         primary_knowledge_source
  FROM kg.edges
  WHERE primary_knowledge_source = 'infores:loinc2hpo'
) TO 'data/raw/kg_loinc2hpo.parquet' (FORMAT parquet);

-- Disease -> phenotype edges, with everything needed to filter on negation and frequency.
COPY (
  SELECT subject AS mondo_id, object AS hp_id, predicate,
         coalesce(lower(negated) = 'true', false) AS negated,
         primary_knowledge_source, has_evidence, publications,
         frequency_qualifier, try_cast(has_percentage AS DOUBLE) AS has_percentage,
         try_cast(has_count AS BIGINT) AS has_count, try_cast(has_total AS BIGINT) AS has_total,
         onset_qualifier, sex_qualifier
  FROM kg.edges
  WHERE category = 'biolink:DiseaseToPhenotypicFeatureAssociation'
    AND subject LIKE 'MONDO:%' AND object LIKE 'HP:%'
) TO 'data/raw/kg_d2p.parquet' (FORMAT parquet);

-- Node labels for the three namespaces.
COPY (
  SELECT id, name, category, description, deprecated
  FROM kg.nodes
  WHERE id LIKE 'LOINC:%' OR id LIKE 'HP:%' OR id LIKE 'MONDO:%'
) TO 'data/raw/kg_nodes.parquet' (FORMAT parquet);

-- Subclass closure within HP and within MONDO (ancestor lookups for concordance checks).
COPY (
  SELECT subject_id, object_id
  FROM kg.closure
  WHERE (subject_id LIKE 'HP:%' AND object_id LIKE 'HP:%')
     OR (subject_id LIKE 'MONDO:%' AND object_id LIKE 'MONDO:%')
) TO 'data/raw/kg_closure.parquet' (FORMAT parquet);

COPY (SELECT * FROM kg.information_content WHERE term LIKE 'HP:%' OR term LIKE 'MONDO:%')
  TO 'data/raw/kg_information_content.parquet' (FORMAT parquet);
