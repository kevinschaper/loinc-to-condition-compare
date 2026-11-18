// https://observablehq.com/framework/config
export default {
  title: "LOINC → condition compare",
  root: "src",
  output: "dist",
  theme: ["air", "near-midnight"],
  pages: [
    {
      name: "Concerns",
      pages: [
        {name: "1 · New LOINC → HP in BONOBO", path: "/bonobo-hp"},
        {name: "2 · BONOBO HP + MONDO", path: "/bonobo"},
        {name: "3 · DisMech LOINC → MONDO", path: "/dismech"},
        {name: "4 · 2-hop graph inference", path: "/twohop"}
      ]
    },
    {
      name: "Review",
      pages: [
        {name: "Error taxonomy", path: "/errors"},
        {name: "Reviewed items", path: "/items"},
        {name: "Methods", path: "/methods"}
      ]
    }
  ],
  footer: "Review verdicts are model judgments, not curator labels.",
  pager: false,
  cleanUrls: true
};
