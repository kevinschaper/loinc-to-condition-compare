#!/usr/bin/env bash
# Shallow-clone the three curated sources into sources/ (git-ignored).
# bonobo is a private repo, so this needs `gh auth login` with access to it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p sources && cd sources
rm -rf loinc2hpoAnnotation bonobo dismech
gh repo clone monarch-initiative/loinc2hpoAnnotation -- --depth 1 -q
gh repo clone monarch-initiative/bonobo -- --depth 1 -q
# dismech is ~10 GB; take only the disease records.
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/monarch-initiative/dismech.git
git -C dismech sparse-checkout set kb/disorders
