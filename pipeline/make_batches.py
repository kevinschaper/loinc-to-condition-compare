"""Split review/items.jsonl into ten mixed batches for the reviewing agents.

The `source` field is dropped so a reviewer sees the claim, not which resource made it.
(The stratum name and any derivation still reveal it in part; see the methods page.)
"""
import json, pathlib

root = pathlib.Path(__file__).resolve().parent.parent / "review"
items = [json.loads(l) for l in (root / "items.jsonl").open()]
(root / "batches").mkdir(exist_ok=True)
N = 10
for i in range(N):
    with (root / "batches" / f"batch_{i:02d}.jsonl").open("w") as fh:
        for it in items[i::N]:
            it.pop("source", None)
            it.pop("stratum", None)
            fh.write(json.dumps(it, ensure_ascii=False) + "\n")
