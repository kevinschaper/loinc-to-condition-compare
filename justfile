# LOINC -> condition compare: pipeline and dashboard

default:
    @just --list

# Clone the curated sources into sources/ (needs gh access to the private bonobo repo)
fetch:
    pipeline/00_fetch_sources.sh

# Pull the monarch-kg slices from the public bucket into data/raw/
kg:
    duckdb -c ".read pipeline/01_kg_extract.sql"
    curl -s https://data.monarchinitiative.org/monarch-kg/latest/metadata.yaml | head -3 > data/raw/kg_version.yaml

# Flatten the curated sources and build the dashboard tables in src/data/
build:
    uv run pipeline/02_extract_sources.py
    cp data/raw/source_versions.json src/data/
    duckdb -c ".read pipeline/03_build.sql"

# Draw the review sample (deterministic) into review/items.jsonl and review/batches/
sample:
    duckdb -c ".read pipeline/04_sample_review.sql"
    uv run pipeline/make_batches.py

# Second-opinion verdicts from Jev (needs JEV_API_KEY)
jev:
    uv run review/jev_judge.py

# Join items, verdicts and taxonomy into the review tables the dashboard reads
review-tables:
    uv run pipeline/05_review_tables.py

# Everything that needs no model calls
data: kg build review-tables

# Preview the dashboard locally
dev:
    npm run dev

# Build the static site into dist/
site:
    npm run build
