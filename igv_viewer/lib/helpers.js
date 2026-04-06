// Shared filesystem helpers used across all lib modules.
const fs = require("fs");

// Natural sort: "RPI_2" before "RPI_10", "barcode3" before "barcode12"
function naturalCompare(a, b) {
  const re = /(\d+)/g;
  const pa = a.split(re), pb = b.split(re);
  for (let i = 0; i < Math.min(pa.length, pb.length); i++) {
    if (pa[i] !== pb[i]) {
      const na = Number(pa[i]), nb = Number(pb[i]);
      if (!isNaN(na) && !isNaN(nb)) return na - nb;
      return pa[i] < pb[i] ? -1 : 1;
    }
  }
  return pa.length - pb.length;
}

function readdirSafe(dir) {
  try { return fs.readdirSync(dir).sort(naturalCompare); } catch (e) { console.warn("[warn] readdir " + dir + ": " + e.message); return []; }
}

function isDirSafe(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}

function statSafe(p) {
  try { return fs.statSync(p); } catch { return null; }
}

module.exports = { naturalCompare, readdirSafe, isDirSafe, statSafe };
