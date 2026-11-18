# Review protocol

You are reviewing associations from LOINC laboratory tests to HPO phenotypes or MONDO diseases,
as a clinical-laboratory and biomedical-ontology reviewer. Judge each claim from your own medical
knowledge. Do not look anything up, and do not read other files in this repository beyond the
ones named here.

## Input

One JSON object per line. Fields:

- `item_id`
- `kind`: `loinc_to_phenotype` or `loinc_to_disease`
- `loinc_id`, `loinc_label`: the LOINC long common name (analyte, property, timing, specimen, method)
- `object_id`, `object_label`: the HP or MONDO term
- `relation`, `result`: the relation claimed and the result outcome it is about (H/L/N/POS/NEG,
  band outcomes such as HIGH/LOW/NORMAL/GRADE, or high/low)
- `claim`: the statement to judge
- `context`: curator text where there is any (band bounds, population, interpretation, or the
  disease-record entry)
- `derivation`: for graph-inferred items only, the path(s) test -> phenotype -> disease, with the
  phenotype's frequency in the disease and how many diseases carry that phenotype

## What to record for each item

- `verdict`
  - `correct`: accurate as stated and clinically meaningful
  - `correct_but_weak`: the finding does occur, but the association is so nonspecific, indirect
    or uncommon that it has little value
  - `partially_correct`: the right idea with a concrete flaw
  - `incorrect`: the claim is wrong
  - `cannot_judge`: you cannot assess it
- `error_codes`: a list of codes from `taxonomy.yaml` (the `id` of a code, not of a group), most
  important first. Empty list for `correct`. At least one code for every other verdict except
  `cannot_judge`. Use `other` only when nothing fits, and say what in `error_note`.
- `error_note`: one or two sentences naming exactly what is wrong. Empty string for `correct`.
- `weak_link`: for items with a `derivation`: `test_to_phenotype`, `phenotype_to_disease`,
  `chaining` or `none`. Empty string otherwise.
- `confidence`: `high`, `medium` or `low`

## Calibration, from the pilot

- A challenge or timed code is not wrong by itself. Flag it when the challenge changes what high
  or low means; pass it when the stimulated value is how the phenotype is demonstrated (cortisol
  after ACTH for adrenal insufficiency).
- A negative or normal result that "rules out" or "argues against" the corresponding positivity
  phenotype is correct though nearly tautological. Flag `overclaimed_exclusion` only when the
  term is broader than what the test covers, or when a single normal result cannot exclude it.
- For a disease claim, "correct" needs the test to be a recognised diagnostic test or a
  characteristic finding. A true but nonspecific or rare correlate is `correct_but_weak`.
- These are real curated resources. Do not invent problems, and do not wave through real ones.

## Output

One JSON object per line with exactly the keys `item_id`, `verdict`, `error_codes`, `error_note`,
`weak_link`, `confidence`. Every input item must appear exactly once. Before finishing, check
that the line count matches the input, every line parses, and every code is in the taxonomy.
