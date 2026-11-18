"""Second-opinion judgments from Jev (TypeSafe System One) on the review items.

    uv run review/jev_judge.py [--limit N]

Reads review/items.jsonl, appends to review/judgments/jev.jsonl, and skips items already there.
Needs JEV_API_KEY (or TYPESAFE_API_KEY). Jev returns a choice with a probability for each
option, not an explanation, so it gives a verdict and a confidence but no error category.
"""
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
import argparse, concurrent.futures as cf, json, os, pathlib, sys, time
import httpx

ROOT = pathlib.Path(__file__).resolve().parent
ITEMS, OUT = ROOT / "items.jsonl", ROOT / "judgments" / "jev.jsonl"
MODEL = os.environ.get("JEV_MODEL", "jev-latest")
VERDICTS = {
    "correct": "The claim is medically accurate as stated and clinically meaningful",
    "correct_but_weak": "The finding does occur, but the association is so nonspecific, indirect or uncommon that it has little value",
    "partially_correct": "The right idea with a concrete flaw: wrong granularity, wrong specimen, imprecise direction, or an over-claim",
    "incorrect": "The claim is wrong",
}


def request(item: dict) -> dict:
    state = {
        "lab_test": {"code": item["loinc_id"], "loinc_long_common_name": item["loinc_label"]},
        "target": {"kind": "HPO phenotype" if item["kind"] == "loinc_to_phenotype" else "MONDO disease",
                   "id": item["object_id"], "name": item["object_label"]},
        "claim": item["claim"],
    }
    if item.get("context"):
        state["curator_context"] = item["context"][:3000]
    if item.get("derivation"):
        state["inferred_through"] = item["derivation"][:6]
    return {"model": MODEL, "state": state, "questions": {
        "verdict": {"type": "choice",
                    "instructions": "Judge `claim`, which links the laboratory test in `lab_test` to the term in `target`. "
                                    "Consider whether the analyte, specimen and result direction fit the target.",
                    "criteria": VERDICTS},
        "accurate": {"type": "noul", "instructions": "Is `claim` medically accurate?"},
        "useful": {"type": "noul",
                   "instructions": "Would a clinician consider the result described in `claim` a specific and useful indicator of `target`, "
                                   "rather than a nonspecific or incidental correlate?"},
    }}


def post(client: httpx.Client, item: dict) -> dict:
    for attempt in range(6):
        r = client.post("/v1/systemone", json=request(item))
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 5:
            time.sleep(min(2 ** attempt, 30)); continue
        r.raise_for_status()
        body = r.json()
        a = body["answers"]
        return {"item_id": item["item_id"], "judge": body.get("model", MODEL), "verdict": a["verdict"]["choice"],
                "verdict_probabilities": a["verdict"].get("probabilities"), "confidence": a["verdict"].get("confidence"),
                "p_accurate": a["accurate"]["noul"], "p_useful": a["useful"]["noul"],
                "input_tokens": (body.get("usage") or {}).get("input_tokens")}
    raise RuntimeError("unreachable")


def main() -> None:
    ap = argparse.ArgumentParser(); ap.add_argument("--limit", type=int, default=0); args = ap.parse_args()
    key = os.environ.get("JEV_API_KEY") or os.environ.get("TYPESAFE_API_KEY")
    if not key:
        sys.exit("set JEV_API_KEY or TYPESAFE_API_KEY")
    OUT.parent.mkdir(exist_ok=True)
    done = {json.loads(l)["item_id"] for l in OUT.open()} if OUT.exists() else set()
    items = [i for i in map(json.loads, ITEMS.open()) if i["item_id"] not in done]
    if args.limit:
        items = items[:args.limit]
    print(f"{len(done)} done, {len(items)} to go", file=sys.stderr)
    with httpx.Client(base_url="https://api.typesafe.ai", timeout=120, headers={"Authorization": f"Bearer {key}"}) as client, \
         OUT.open("a") as fh, cf.ThreadPoolExecutor(4) as pool:
        for n, fut in enumerate(cf.as_completed([pool.submit(post, client, i) for i in items]), 1):
            try:
                fh.write(json.dumps(fut.result()) + "\n"); fh.flush()
            except Exception as e:  # keep going; a re-run picks up what failed
                print(f"  ! {type(e).__name__}: {e}", file=sys.stderr)
            if n % 50 == 0:
                print(f"  {n}/{len(items)}", file=sys.stderr)


main()
