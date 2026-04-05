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

// ---------------------------------------------------------------------------
// Shared page infrastructure for UMI and Gene Counts pages.
// Pages set window._page with callbacks, then call initPage().
// ---------------------------------------------------------------------------

// --- Dataset description support ---
function showDatasetDesc(name, descriptions) {
  const el = document.getElementById("dataset-desc");
  if (!el) return;
  const desc = descriptions[name];
  if (desc) { el.textContent = desc; el.style.display = "block"; }
  else { el.style.display = "none"; }
}

// --- Chart instance management ---
function destroyCharts(chartInstances) {
  for (const c of chartInstances) c.destroy();
  chartInstances.length = 0;
}

// --- Empty / status messages ---
function showEmpty(msg) {
  document.getElementById("chart-area").innerHTML = `<p class="empty">${msg}</p>`;
}

// --- Clear page state ---
function clearPage(chartInstances) {
  destroyCharts(chartInstances);
  document.getElementById("chart-area").innerHTML = "";
  document.getElementById("sample-body").innerHTML = "";
  document.getElementById("sample-count").textContent = "";
  document.getElementById("controls").style.display = "none";
}

// --- Sample selector ---
// Builds barcode-grouped checkboxes from a normalized sample list.
// sampleList: array of {id, barcode, shortName}
// selectedIds: Set of selected sample IDs
// callbacks: {onRender, onSave} — called after selection changes
function buildSampleSelector(sampleList, selectedIds, callbacks) {
  const body = document.getElementById("sample-body");
  body.innerHTML = "";
  const barcodes = [...new Set(sampleList.map(s => s.barcode))].sort(naturalSort);

  // Select-all
  const allDiv = document.createElement("div");
  allDiv.style.marginBottom = "8px";
  const allLabel = document.createElement("label");
  allLabel.style.cssText = "cursor:pointer;font-weight:600;";
  const allCb = document.createElement("input");
  allCb.type = "checkbox"; allCb.id = "check-all"; allCb.checked = true;
  allCb.addEventListener("change", function() {
    _toggleAll(this.checked, sampleList, selectedIds, callbacks);
  });
  allLabel.appendChild(allCb);
  allLabel.appendChild(document.createTextNode(" Select all"));
  allDiv.appendChild(allLabel);
  body.appendChild(allDiv);

  for (const bc of barcodes) {
    const hue = barcodeHue(bc);
    const samples = sampleList.filter(s => s.barcode === bc);
    const groupDiv = document.createElement("div");
    groupDiv.className = "bc-group";

    const headerDiv = document.createElement("div");
    headerDiv.className = "bc-group-header";
    const swatch = document.createElement("span");
    swatch.className = "swatch";
    swatch.style.background = "hsl(" + hue + ",70%,50%)";
    headerDiv.appendChild(swatch);
    const bcLabel = document.createElement("label");
    bcLabel.style.cursor = "pointer";
    const bcCb = document.createElement("input");
    bcCb.type = "checkbox"; bcCb.checked = true;
    bcCb.dataset.barcode = bc;
    bcCb.addEventListener("change", (function(bcName) {
      return function() { _toggleBarcode(bcName, this.checked, sampleList, selectedIds, callbacks); };
    })(bc));
    bcLabel.appendChild(bcCb);
    bcLabel.appendChild(document.createTextNode(" " + bc + " (" + samples.length + ")"));
    headerDiv.appendChild(bcLabel);
    groupDiv.appendChild(headerDiv);

    const checksDiv = document.createElement("div");
    checksDiv.className = "sample-checks";
    for (const s of samples) {
      const sLabel = document.createElement("label");
      const sCb = document.createElement("input");
      sCb.type = "checkbox"; sCb.checked = true;
      sCb.dataset.id = s.id; sCb.dataset.bc = bc;
      sCb.addEventListener("change", (function(sId) {
        return function() { _toggleSample(sId, this.checked, sampleList, selectedIds, callbacks); };
      })(s.id));
      sLabel.appendChild(sCb);
      sLabel.appendChild(document.createTextNode(" " + s.shortName));
      checksDiv.appendChild(sLabel);
    }
    groupDiv.appendChild(checksDiv);
    body.appendChild(groupDiv);
  }
  _updateSampleCount(sampleList, selectedIds);
}

function _toggleAll(checked, sampleList, selectedIds, callbacks) {
  if (checked) { for (const s of sampleList) selectedIds.add(s.id); }
  else selectedIds.clear();
  document.querySelectorAll('#sample-body input[data-id]').forEach(cb => cb.checked = checked);
  document.querySelectorAll('#sample-body .bc-group-header input').forEach(cb => cb.checked = checked);
  _updateSampleCount(sampleList, selectedIds);
  callbacks.onRender(); callbacks.onSave();
}

function _toggleBarcode(bc, checked, sampleList, selectedIds, callbacks) {
  document.querySelectorAll(`#sample-body input[data-bc="${bc}"]`).forEach(cb => {
    cb.checked = checked;
    if (checked) selectedIds.add(cb.dataset.id); else selectedIds.delete(cb.dataset.id);
  });
  _syncAllCheckbox(sampleList, selectedIds);
  _updateSampleCount(sampleList, selectedIds);
  callbacks.onRender(); callbacks.onSave();
}

function _toggleSample(id, checked, sampleList, selectedIds, callbacks) {
  if (checked) selectedIds.add(id); else selectedIds.delete(id);
  const bc = sampleList.find(s => s.id === id)?.barcode;
  if (bc) {
    const bcSamples = sampleList.filter(s => s.barcode === bc);
    const bcCb = document.querySelector(`#sample-body .bc-group-header input[data-barcode="${bc}"]`);
    if (bcCb) bcCb.checked = bcSamples.every(s => selectedIds.has(s.id));
  }
  _syncAllCheckbox(sampleList, selectedIds);
  _updateSampleCount(sampleList, selectedIds);
  callbacks.onRender(); callbacks.onSave();
}

function _syncAllCheckbox(sampleList, selectedIds) {
  const all = document.getElementById("check-all");
  if (all) all.checked = selectedIds.size === sampleList.length;
}

function _updateSampleCount(sampleList, selectedIds) {
  document.getElementById("sample-count").textContent =
    `(${selectedIds.size}/${sampleList.length} selected)`;
}

// --- View mode toggle (shared by UMI and Genes pages) ---
function setViewMode(mode, renderFn, saveFn) {
  document.querySelectorAll(".controls .ctrl-btn[data-view]").forEach(btn =>
    btn.classList.toggle("active", btn.dataset.view === mode));
  renderFn(mode);
  saveFn();
}

// --- Immediate nav link sync from URL params (inline script replacement) ---
// Call from each page's inline <script> right after the header.
function syncNavLinksFromUrl() {
  const n = new URLSearchParams(location.search).get("name");
  if (n) syncNavLinks(n);
}
