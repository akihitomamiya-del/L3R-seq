// FASTA file sanitization and FAI index generation.
const fs = require("fs");
const path = require("path");
const { FASTA_WRAP_WIDTH } = require("../config");
const { statSafe } = require("./helpers");

// Sanitize a FASTA file: strip \r, ensure trailing newline, wrap long
// sequence lines, and regenerate the .fai index if stale.
function sanitizeFasta(fastaPath) {
  const stat = statSafe(fastaPath);
  if (stat && stat.size > 10 * 1024 * 1024) return;

  let data;
  try { data = fs.readFileSync(fastaPath); } catch { return; }

  let dirty = false;

  if (data.includes(0x0d)) {
    data = Buffer.from(data.toString("binary").replace(/\r/g, ""), "binary");
    dirty = true;
  }

  if (data.length > 0 && data[data.length - 1] !== 0x0a) {
    data = Buffer.concat([data, Buffer.from("\n")]);
    dirty = true;
  }

  const lines = data.toString().split("\n");
  let rewrapped = false;
  const out = [];
  for (const line of lines) {
    if (line.startsWith(">") || line.length <= FASTA_WRAP_WIDTH) {
      out.push(line);
    } else {
      for (let i = 0; i < line.length; i += FASTA_WRAP_WIDTH) {
        out.push(line.slice(i, i + FASTA_WRAP_WIDTH));
      }
      rewrapped = true;
    }
  }
  if (rewrapped) {
    data = Buffer.from(out.join("\n"));
    dirty = true;
  }

  if (dirty) {
    fs.writeFileSync(fastaPath, data);
    console.log(`  Fixed FASTA: ${path.basename(fastaPath)}`);
  }

  const faiPath = fastaPath + ".fai";
  let needFai = !fs.existsSync(faiPath);
  if (!needFai) {
    const faStat = statSafe(fastaPath);
    const faiStat = statSafe(faiPath);
    if (faStat && faiStat && faStat.mtimeMs > faiStat.mtimeMs) needFai = true;
  }
  if (needFai || dirty) {
    const text = data.toString();
    const faiLines = [];
    let seqName = null, seqLen = 0, offset = 0, lineBases = 0, lineWidth = 0;
    let firstSeqLine = true;
    for (const line of text.split("\n")) {
      if (line.startsWith(">")) {
        if (seqName) faiLines.push(`${seqName}\t${seqLen}\t${offset}\t${lineBases}\t${lineWidth}`);
        seqName = line.slice(1).split(/\s/)[0];
        seqLen = 0; firstSeqLine = true;
        offset = text.indexOf(line) + line.length + 1;
      } else if (seqName && line.length > 0) {
        seqLen += line.length;
        if (firstSeqLine) { lineBases = line.length; lineWidth = line.length + 1; firstSeqLine = false; }
      }
    }
    if (seqName) faiLines.push(`${seqName}\t${seqLen}\t${offset}\t${lineBases}\t${lineWidth}`);
    fs.writeFileSync(faiPath, faiLines.join("\n") + "\n");
    console.log(`  Rebuilt FAI:  ${path.basename(faiPath)}`);
  }
}

module.exports = { sanitizeFasta };
