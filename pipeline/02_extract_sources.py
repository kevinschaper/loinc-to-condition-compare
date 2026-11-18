"""Flatten the three curated sources into one row per asserted LOINC -> term link.

    uv run pipeline/02_extract_sources.py

Reads the clones under sources/ (see pipeline/00_fetch_sources.sh) and writes
data/raw/{legacy_loinc2hpo,bonobo_targets,dismech_loinc}.parquet plus
data/raw/source_versions.json. Nothing here judges quality; it only reshapes.
"""
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "duckdb", "pandas", "pyarrow"]
# ///
from __future__ import annotations

import csv
import glob
import json
import pathlib
import subprocess

import duckdb
import pandas as pd
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "sources"
OUT = ROOT / "data" / "raw"
Loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)

# The one bonobo shard that was migrated from loinc2hpoAnnotation rather than curated fresh.
BONOBO_IMPORTED_SHARDS = {"allergy"}


def git_version(repo: str) -> dict:
    def run(*a):
        return subprocess.run(["git", "-C", str(SRC / repo), *a], capture_output=True, text=True).stdout.strip()
    return {"commit": run("rev-parse", "--short", "HEAD"), "date": run("log", "-1", "--format=%cs")}


def refs(evidence) -> list[str]:
    return sorted({e["reference"] for e in evidence or [] if isinstance(e, dict) and e.get("reference")})


def has_snippet(evidence) -> int:
    return sum(1 for e in evidence or [] if isinstance(e, dict) and e.get("snippet"))


# ---------------------------------------------------------------- legacy loinc2hpoAnnotation
def legacy() -> pd.DataFrame:
    rows = []
    with open(SRC / "loinc2hpoAnnotation" / "loinc2hpo-annotations.tsv") as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            rows.append({
                "loinc_id": "LOINC:" + r["loincId"],
                "scale": r["loincScale"],
                "outcome": r["outcome"],
                "hp_id": r["hpoTermId"],
                "supplemental_term": None if r["supplementalTermId"] == "." else r["supplementalTermId"],
                "curation": r["curation"],
                "comment": None if r["comment"] == "." else r["comment"],
            })
    return pd.DataFrame(rows)


# ---------------------------------------------------------------- bonobo
def bonobo() -> pd.DataFrame:
    rows = []
    for f in sorted(glob.glob(str(SRC / "bonobo" / "annotations" / "*.yaml"))):
        shard = pathlib.Path(f).stem
        rec = yaml.load(open(f), Loader=Loader)
        for ann in rec.get("annotations") or []:
            subj = ann.get("subject") or {}
            lt = subj.get("loinc_term") or {}
            if not lt.get("id"):
                continue  # derived, codeless gradings have no LOINC subject
            ann_ev = ann.get("evidence") or []
            for ri, rr in enumerate(ann.get("reference_ranges") or []):
                pop = rr.get("population") or {}
                rr_ev = rr.get("evidence") or []
                unit = ((rr.get("unit") or {}).get("term") or {}).get("label")
                for band in rr.get("bands") or []:
                    b_ev = band.get("evidence") or []
                    for kind, slot in (("HP", "phenotype_targets"), ("MONDO", "disease_targets")):
                        for t in band.get(slot) or []:
                            term = t.get("term") or {}
                            t_ev = t.get("evidence") or []
                            ev_all = b_ev + rr_ev + ann_ev + t_ev
                            rows.append({
                                "shard": shard,
                                "imported": shard in BONOBO_IMPORTED_SHARDS,
                                "loinc_id": lt["id"],
                                "loinc_label": lt.get("label"),
                                "subject_term": subj.get("preferred_term"),
                                "scale": ann.get("scale"),
                                "range_index": ri,
                                "range_kind": rr.get("range_kind"),
                                "population": pop.get("description"),
                                "source_authority": pop.get("source_authority"),
                                "unit": unit,
                                "band_name": band.get("name"),
                                "outcome": band.get("outcome"),
                                "lower_bound": band.get("lower_bound"),
                                "upper_bound": band.get("upper_bound"),
                                "nominal_value": band.get("nominal_value") or band.get("value"),
                                "interpretation": band.get("interpretation"),
                                "band_notes": band.get("notes"),
                                "object_type": kind,
                                "object_id": term.get("id"),
                                "object_label": term.get("label"),
                                "relation": t.get("relation"),
                                "asserts_normality": bool(t.get("asserts_normality")),
                                "has_preconditions": bool(t.get("preconditions") or rr.get("preconditions")),
                                "n_evidence_band": len(b_ev) + len(t_ev),
                                "n_evidence_range": len(rr_ev) + len(ann_ev),
                                "n_snippets": has_snippet(ev_all),
                                "references": refs(ev_all),
                            })
    return pd.DataFrame(rows)


# ---------------------------------------------------------------- dismech
PRESENCE = {
    "increased": "increased", "elevated": "increased", "high": "increased",
    "decreased": "decreased", "reduced": "decreased", "low": "decreased",
    "positive": "present", "present": "present", "diagnostic": "present",
    "normal": "normal", "absent": "absent", "negative": "absent",
}


def norm_presence(p) -> str | None:
    if p is None:
        return None
    key = str(p).strip().lower().replace("_", " ")
    for k, v in PRESENCE.items():
        if key == k:
            return v
    for k, v in PRESENCE.items():
        if key.startswith(k):
            return v + "_qualified"
    return "other"


def dismech() -> pd.DataFrame:
    rows = []
    for f in sorted(glob.glob(str(SRC / "dismech" / "kb" / "disorders" / "*.yaml"))):
        txt = open(f).read()
        if "LOINC:" not in txt:
            continue
        d = yaml.load(txt, Loader=Loader)
        dt = (d.get("disease_term") or {}).get("term") or {}
        base = {
            "record": pathlib.Path(f).stem,
            "disease_name": d.get("name"),
            "mondo_id": dt.get("id"),
            "mondo_label": dt.get("label"),
            "disease_category": d.get("category"),
        }
        for section in ("diagnosis", "biochemical"):
            for e in d.get(section) or []:
                if not isinstance(e, dict):
                    continue
                found: dict[str, dict] = {}

                def add(term, slot):
                    if isinstance(term, dict) and str(term.get("id", "")).startswith("LOINC:"):
                        cur = found.setdefault(term["id"], {"label": term.get("label"), "slots": set()})
                        cur["slots"].add(slot)

                for m in e.get("measurements") or []:
                    add((m or {}).get("term"), "measurements")
                add(e.get("loinc_term"), "loinc_term")
                add((e.get("biomarker_term") or {}).get("term"), "biomarker_term")
                for m in e.get("mappings_list") or []:
                    add((m or {}).get("term"), "mappings_list")
                band_hp: dict[str, list] = {}
                for rr in e.get("reference_ranges") or []:
                    lt = (rr or {}).get("loinc_term")
                    add(lt, "reference_ranges")
                    for b in (rr or {}).get("interpretation_bands") or (rr or {}).get("bands") or []:
                        pt = ((b or {}).get("phenotype_term") or {}).get("term") or {}
                        if pt.get("id") and isinstance(lt, dict) and lt.get("id"):
                            band_hp.setdefault(lt["id"], []).append(
                                {"hp_id": pt["id"], "hp_label": pt.get("label"), "flag": b.get("abnormal_flag"), "band": b.get("name")})
                ev = e.get("evidence") or []
                for lid, info in found.items():
                    rows.append({
                        **base,
                        "section": section,
                        "entry_name": e.get("name"),
                        "entry_description": e.get("description") or e.get("context"),
                        "entry_notes": e.get("notes"),
                        "presence_raw": None if e.get("presence") is None else str(e.get("presence")),
                        "presence": norm_presence(e.get("presence")),
                        "loinc_id": lid,
                        "loinc_label": info["label"],
                        "slots": sorted(info["slots"]),
                        "has_reference_range": "reference_ranges" in info["slots"],
                        "band_phenotypes": json.dumps(band_hp.get(lid)) if band_hp.get(lid) else None,
                        "n_evidence": len(ev),
                        "n_snippets": has_snippet(ev),
                        "n_support": sum(1 for x in ev if isinstance(x, dict) and x.get("supports") == "SUPPORT"),
                        "references": refs(ev),
                    })
    return pd.DataFrame(rows)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect()
    for name, df in (("legacy_loinc2hpo", legacy()), ("bonobo_targets", bonobo()), ("dismech_loinc", dismech())):
        con.register("df", df)
        con.execute(f"COPY df TO '{OUT / (name + '.parquet')}' (FORMAT parquet)")
        con.unregister("df")
        print(f"{name:<18} {len(df):>6} rows")
    versions = {r: git_version(r) for r in ("loinc2hpoAnnotation", "bonobo", "dismech")}
    kgv = OUT / "kg_version.yaml"
    if kgv.exists():
        versions["monarch-kg"] = yaml.safe_load(kgv.read_text())
    (OUT / "source_versions.json").write_text(json.dumps(versions, indent=2, default=str))


if __name__ == "__main__":
    main()
