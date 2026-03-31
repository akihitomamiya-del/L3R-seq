#!/usr/bin/env node
// patch-igv.js — Post-install patches for igv.min.js.
// Fixes tag value 0 being treated as falsy in group-by logic.
// Run automatically via npm postinstall, or manually: node scripts/patch-igv.js
const fs = require("fs");
const path = require("path");

const igvPath = path.join(__dirname, "../node_modules/igv/dist/igv.min.js");

if (!fs.existsSync(igvPath)) {
  console.log("igv.min.js not found — skipping patches (run npm install first)");
  process.exit(0);
}

let code = fs.readFileSync(igvPath, "utf8");
let patched = false;

const patches = [
  {
    desc: "Fix tag value 0 in getTag lookup (Tp function)",
    find: 'e.tags()[n]||""',
    replace: 'e.tags()[n]??""',
  },
  {
    desc: "Fix tag value 0 in group key assignment (pack caller)",
    find: 'Tp(r,n,i)||""',
    replace: 'Tp(r,n,i)??""',
  },
  {
    desc: "Fix group label not rendering for tag value 0",
    find: 'this.groupBy&&n){i.save()',
    replace: 'this.groupBy&&n!==""){i.save()',
  },
];

for (const p of patches) {
  if (code.includes(p.find)) {
    code = code.replace(p.find, p.replace);
    console.log(`  Patched: ${p.desc}`);
    patched = true;
  } else if (code.includes(p.replace)) {
    console.log(`  Already patched: ${p.desc}`);
  } else {
    console.warn(`  WARNING: Pattern not found — ${p.desc}`);
    console.warn(`    Expected: ${p.find}`);
  }
}

if (patched) {
  fs.writeFileSync(igvPath, code);
  console.log("igv.min.js patched successfully.");
} else {
  console.log("No new patches needed.");
}
