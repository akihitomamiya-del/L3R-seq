"use strict";
// Shared utilities for L3Rseq viewer pages (index, genes, umi).
// Single source of truth — eliminates duplicated code across the three HTML pages.

// --- Natural sort: "RPI_2" before "RPI_10", "barcode3" before "barcode12" ---
function naturalSort(a, b) {
  if (typeof a !== "string") return a - b;
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

// --- Color palette for barcode groups ---
const BARCODE_HUES = {};
const HUE_POOL = [210, 140, 25, 280, 350, 60]; // blue, green, orange, purple, red, yellow
let hueIdx = 0;

function barcodeHue(bc) {
  if (!(bc in BARCODE_HUES)) BARCODE_HUES[bc] = HUE_POOL[hueIdx++ % HUE_POOL.length];
  return BARCODE_HUES[bc];
}

function resetBarcodeHues() {
  Object.keys(BARCODE_HUES).forEach(k => delete BARCODE_HUES[k]);
  hueIdx = 0;
}

// --- Number formatting ---
function fmtNum(n) { return Number(n).toLocaleString(); }

// --- Nav link sync (updates all nav links based on selected dataset) ---
// Works on any page — skips links that don't exist on the current page.
function syncNavLinks(name) {
  const enc = name ? encodeURIComponent(name) : "";
  const genesHash = name ? (sessionStorage.getItem("l3rseq_genes_hash_" + name) || "") : "";
  const links = {
    "viewer-link": name ? "/?name=" + enc : "/",
    "umi-link": name ? "/umi?name=" + enc : "/umi",
    "genes-link": (name ? "/genes?name=" + enc : "/genes") + genesHash,
  };
  for (const [id, href] of Object.entries(links)) {
    const el = document.getElementById(id);
    if (el) el.href = href;
  }
}

// --- Collapsible panel toggle ---
function togglePanel(id) {
  const body = document.getElementById(id).querySelector(".panel-body");
  const arrow = document.getElementById(id).querySelector(".arrow");
  body.classList.toggle("open");
  arrow.classList.toggle("open");
}
