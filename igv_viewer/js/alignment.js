    var browser = null;  // var so Puppeteer tools can access window.browser
    let references = [];
    let allTracks = [];  // full track configs from API (for toggle)
    let datasetDescriptions = {};  // name → description string
    let loading = false;  // guard against concurrent browser creation
    let lastLocus = null; // persist locus across browser destroy/create

    const SAMPLING_PARAMS = {
      NORMAL: {},
      ALL: { samplingDepth: 10000, visibilityWindow: 1000000, maxRows: 5000 },
    };

    function buildDropdown(selectEl, options, valueFn, labelFn) {
      selectEl.innerHTML = "";
      for (let i = 0; i < options.length; i++) {
        const opt = document.createElement("option");
        opt.value = valueFn ? valueFn(options[i], i) : options[i];
        opt.textContent = labelFn ? labelFn(options[i], i) : options[i];
        selectEl.appendChild(opt);
      }
    }

    function showStatus(msg) {
      const el = document.getElementById("status");
      el.style.display = "block";
      el.textContent = msg;
    }

    /* ---- Initialization (fast — only fetches directory names) ---- */

    async function init() {
      const res = await fetch("/api/datasets");
      const config = await res.json();
      references = config.references;

      const sel = document.getElementById("dataset");
      /* Build description map from datasetInfo */
      if (config.datasetInfo) {
        for (const di of config.datasetInfo) {
          if (di.description) datasetDescriptions[di.name] = di.description;
        }
      }
      const names = config.datasets;
      if (names.length === 0) {
        sel.innerHTML = '<option value="">No pipeline output found</option>';
        document.getElementById("igv-container").innerHTML =
          '<p class="empty">Run the L3Rseq pipeline first, then refresh this page.<br>' +
          'The viewer auto-discovers sorted BAM files in any output directory ' +
          'that contains <code>07_map/</code> or <code>09_correct/</code>.</p>';
        return;
      }
      buildDropdown(sel, names);
      sel.insertAdjacentHTML("afterbegin", '<option value="">-- select dataset --</option>');
      sel.value = "";

      sel.onchange = () => {
        syncNavLinks(sel.value);
        history.replaceState(null, "", sel.value ? "?name=" + encodeURIComponent(sel.value) : "/");
        loadDataset(sel.value);
      };

      /* Populate reference selector */
      const refSel = document.getElementById("ref-select");
      buildDropdown(refSel, references, (r, i) => i, r => r.name);
      refSel.onchange = () => {
        const dsSel = document.getElementById("dataset");
        if (dsSel.value) loadDataset(dsSel.value);
      };

      /* Auto-select: URL param first, then single-dataset auto-pick */
      const urlParams = new URLSearchParams(location.search);
      const urlName = urlParams.get("name");
      const urlLocus = urlParams.get("locus");
      let pick = null;
      if (urlName && names.includes(urlName)) pick = urlName;
      else if (names.length === 1) pick = names[0];
      if (pick) {
        sel.value = pick;
        syncNavLinks(pick);
        await loadDataset(pick, urlLocus || undefined);
      }
    }

    /* ---- Load tracks on demand (only when user selects a dataset) ---- */

    async function loadDataset(name, locus, preserveSelection) {
      if (!name || loading) return;
      loading = true;
      try {
      const container = document.getElementById("igv-container");
      /* Snapshot checkbox states before rebuild when preserving */
      const savedChecked = preserveSelection ? new Set(
        [...trackCheckboxes()].filter(cb => cb.checked).map(cb => cb.dataset.trackIdx)
      ) : null;
      if (browser) { igv.removeBrowser(browser); browser = null; }

      showStatus("Loading " + name + " ...");

      /* Show dataset description */
      const descEl = document.getElementById("dataset-desc");
      const desc = datasetDescriptions[name];
      if (desc) {
        descEl.textContent = desc;
        descEl.style.display = "block";
      } else {
        descEl.style.display = "none";
      }

      const res = await fetch("/api/tracks?name=" + encodeURIComponent(name));
      if (!res.ok) { showStatus("Failed to load dataset: " + name); return; }
      const ds = await res.json();

      /* Auto-select the matching reference for this dataset */
      const refSel = document.getElementById("ref-select");
      if (ds.refName) {
        for (let i = 0; i < references.length; i++) {
          if (references[i].name === ds.refName) {
            refSel.value = i;
            break;
          }
        }
      }

      const refIdx = parseInt(refSel.value, 10) || 0;
      const ref = references[refIdx];
      if (!ref) { container.innerHTML = '<p class="empty">No indexed reference found.</p>'; return; }

      allTracks = ds.tracks;
      buildTrackToggles(allTracks);
      /* Restore checkbox states if preserving */
      if (savedChecked) {
        for (const cb of trackCheckboxes()) {
          cb.checked = savedChecked.has(cb.dataset.trackIdx);
        }
        syncGroupCheckboxes();
      }

      const showAll = document.getElementById("show-all").checked;
      const enabledTracks = getEnabledTracks(showAll);

      /* Apply active groupBy to track configs before creating the browser,
         so data is fetched and packed with grouping from the start. */
      const activeGroupBy = document.getElementById("group-by")?.value;
      const groupBy = (activeGroupBy && activeGroupBy !== "none") ? activeGroupBy : undefined;
      if (groupBy) {
        for (const t of enabledTracks) t.groupBy = groupBy;
      }

      const browserCfg = {
        reference: ref,
        tracks: enabledTracks,
        loadDefaultGenomes: false,  // suppress fetch to igv.org (blocked by firewall)
      };
      if (locus) { browserCfg.locus = locus; lastLocus = locus; }
      browser = await igv.createBrowser(container, browserCfg);

      /* Inject sticky navbar into IGV.js Shadow DOM */
      if (browser.root) {
        const shadowRoot = browser.root.getRootNode();
        if (shadowRoot && shadowRoot !== document) {
          const style = document.createElement("style");
          style.textContent = ".igv-navbar { position: sticky !important; top: 0; z-index: 1100 !important; }";
          shadowRoot.appendChild(style);
        }
      }

      /* Also set groupBy on AlignmentTrack objects for sort/color to reference */
      if (groupBy) {
        eachBAMTrack((tv, at) => { at.groupBy = groupBy; });
      }

      const cbar = document.getElementById("controls-bar");
      cbar.style.display = "block";
      updateStickyTops();

      /* Re-apply display mode if not default */
      const activeMode = document.getElementById("btn-expanded").classList.contains("active") ? "EXPANDED" : null;
      if (activeMode) setAllDisplay(activeMode);

      /* Re-apply color setting if active */
      const colorSel = document.getElementById("color-by");
      if (colorSel.value !== "none") setAllColor();

      showStatus("Ready. " + enabledTracks.length + " of " + allTracks.length + " tracks loaded.");
      } catch (e) {
        showStatus("Error: " + e.message);
      } finally {
        loading = false;
      }
    }

    document.getElementById("show-all").onchange = () => {
      const sel = document.getElementById("dataset");
      if (!sel.value) return;
      // Preserve the user's current track selection — otherwise toggling
      // this checkbox silently resets to the default first-8.
      if (browser) reloadWithCurrentSelection();
      else loadDataset(sel.value);
    };

    /* ---- Display mode ---- */

    function setAllDisplay(mode) {
      for (const id of ["squished", "expanded"]) {
        document.getElementById("btn-" + id)
          .classList.toggle("active", id === mode.toLowerCase());
      }
      eachBAMTrack((tv, at) => {
        if (typeof at.setDisplayMode === "function") {
          at.setDisplayMode(mode);
        } else {
          at.displayMode = mode;
          tv.repaintViews();
        }
      });
    }

    function setAllHeight(px) {
      const h = parseInt(px, 10);
      if (isNaN(h) || h < 50) return;
      eachBAMTrack((tv) => {
        if (typeof tv.setTrackHeight === "function") tv.setTrackHeight(h);
      });
    }

    function setAllToggle(prop, value) {
      eachBAMTrack((tv, at) => {
        at[prop] = value;
        if (prop === "viewAsPairs" &&
            typeof at.repackAlignments === "function") at.repackAlignments();
        tv.repaintViews();
      });
    }

    function eachBAMTrack(fn) {
      if (!browser || !browser.trackViews) return;
      for (const tv of browser.trackViews) {
        if (tv.track && tv.track.alignmentTrack) fn(tv, tv.track.alignmentTrack);
      }
    }

    /* ---- Sort all tracks ---- */

    function setSortDir(dir) {
      document.getElementById("btn-sort-asc").classList.toggle("active", dir === "ASC");
      document.getElementById("btn-sort-desc").classList.toggle("active", dir === "DESC");
      sortAllTracks();
    }

    async function sortAllTracks() {
      if (!browser) return;
      const sortVal = document.getElementById("sort-by").value;
      const isAsc = document.getElementById("btn-sort-asc").classList.contains("active");

      if (sortVal === "none") {
        /* Unsort: reload the dataset to reset row order */
        const sel = document.getElementById("dataset");
        if (sel.value) {
          document.getElementById("sort-by").value = "none";
          await loadDataset(sel.value, null, true);
        }
        return;
      }

      let option, tag;
      if (sortVal.startsWith("tag:")) {
        option = "TAG";
        tag = sortVal.substring(4);
      } else {
        option = sortVal;
      }

      showStatus("Sorting by " + (tag || option) + "...");

      /*
       * Mimic IGV.js context-menu sort path (AlignmentTrack popupData):
       *   1. Build sortObject with viewport's own chr + center position
       *   2. Set at.sortObject (persists for future repaints)
       *   3. Direct sortRows() on existing cached features (no cache clearing)
       *   4. vp.repaint() to redraw the canvas
       *
       * This bypasses BAMTrack.sort() which has a position-decrement bug
       * in assignSort() and a containsPosition() check that silently skips
       * viewports when chr aliasing fails.
       */
      eachBAMTrack((tv, at) => {
        for (const vp of tv.viewports) {
          const rf = vp.referenceFrame;
          if (!rf) continue;
          const cached = vp.cachedFeatures;
          if (!cached) continue;

          const sortObj = {
            option: option,
            direction: isAsc,
            chr: rf.chr,
            position: Math.round((rf.start + rf.end) / 2),
          };
          if (tag) sortObj.tag = tag;
          at.sortObject = sortObj;

          /*
           * For TAG sorts, IGV.js sortRows only sorts reads that span the
           * sort position — reads elsewhere are left unsorted. Override this
           * for TAG sorts: sort ALL rows in every group by their tag value,
           * regardless of position.
           */
          if (option === "TAG" && cached.packedGroups) {
            for (const grp of cached.packedGroups.values()) {
              if (!grp.rows) continue;
              grp.rows.sort((a, b) => {
                const aVal = _getTagFromRow(a, tag);
                const bVal = _getTagFromRow(b, tag);
                if (aVal === undefined && bVal === undefined) return 0;
                if (aVal === undefined) return 1;
                if (bVal === undefined) return -1;
                const cmp = aVal > bVal ? 1 : aVal < bVal ? -1 : 0;
                return isAsc ? cmp : -cmp;
              });
            }
          } else if (typeof cached.sortRows === "function") {
            cached.sortRows(sortObj);
          }
          vp.repaint();
        }
      });

      showStatus("Sorted by " + (tag || option) + " (" + (isAsc ? "ascending" : "descending") + ").");
    }

    /* Extract a tag value from any alignment in a packed row */
    function _getTagFromRow(row, tag) {
      if (!row || !row.alignments) return undefined;
      for (const aln of row.alignments) {
        if (typeof aln.getTag === "function") {
          const v = aln.getTag(tag);
          if (v !== undefined) return v;
        }
      }
      return undefined;
    }

    /* ---- Color all tracks ---- */

    const SJ_COLORS = { "S": "#2ecc71", "R": "#e74c3c", "-": "#95a5a6" };
    const SJ_LABELS = { "S": "spliced", "R": "retained", "-": "not spanned" };
    const TL_COLORS = { "0": "#5dade2", "1": "#e74c3c" };
    const TL_LABELS = { "0": "normal", "1": "translocation" };

    function makeColorTable(map) {
      return { getColor(key) { return map[String(key)] || "#cccccc"; } };
    }

    function setAllColor() {
      const colorVal = document.getElementById("color-by").value;
      const legend = document.getElementById("color-legend");
      legend.innerHTML = "";

      if (colorVal === "none") {
        eachBAMTrack((tv, at) => {
          at.colorBy = "none";
          at.colorTable = null;
          tv.repaintViews();
        });
        return;
      }

      let colorBy, legendMap, labelMap;
      if (colorVal === "tag:SJ") {
        colorBy = "tag:SJ";
        legendMap = SJ_COLORS;
        labelMap = SJ_LABELS;
      } else if (colorVal === "tag:TL") {
        colorBy = "tag:TL";
        legendMap = TL_COLORS;
        labelMap = TL_LABELS;
      } else if (colorVal === "strand") {
        colorBy = "strand";
      } else {
        colorBy = colorVal;
      }

      eachBAMTrack((tv, at) => {
        at.colorBy = colorBy;
        if (legendMap) at.colorTable = makeColorTable(legendMap);
        else at.colorTable = null;
        tv.repaintViews();
      });

      /* Show legend */
      if (legendMap && labelMap) {
        for (const [val, color] of Object.entries(legendMap)) {
          const label = labelMap[val] || val;
          legend.innerHTML += '<span><span class="color-swatch" style="background:' +
            color + '"></span>' + label + '</span>';
        }
      }
    }

    /* ---- Group all tracks ---- */

    async function groupAllTracks() {
      if (!browser) return;
      const val = document.getElementById("group-by").value;
      const label = val === "none" ? "" : val.replace("tag:", "");

      /* Save current locus, reload dataset (loadDataset reads the group-by
         dropdown and bakes groupBy into track configs before creating browser) */
      const rf = browser.referenceFrameList?.[0];
      const savedLocus = rf
        ? rf.chr + ":" + (Math.round(rf.start) + 1) + "-" + Math.round(rf.end)
        : null;

      const sel = document.getElementById("dataset");
      if (sel.value) await loadDataset(sel.value, savedLocus, true);

      showStatus(label ? "Grouped by " + label + "." : "Grouping removed.");
    }

    /* ---- Track selection ---- */

    const MAX_DEFAULT_TRACKS = 8;  // cap initial load for large datasets
    function parseTrackName(name) {
      const parts = name.split(" — ");
      const samplePart = parts[0];
      const stepLabel = parts[1] || name;
      const barcode = samplePart.split("/")[0];
      const rpi = samplePart.split("/")[1] || samplePart;
      const rpiShort = rpi.replace(barcode + "_", "");
      const stepMatch = stepLabel.match(/step\s*(\d+)/);
      const stepKey = stepMatch ? stepMatch[1] : stepLabel.split(/[\s(]/)[0].toLowerCase();
      return { barcode, rpi, rpiShort, stepLabel, stepKey };
    }

    /** Get all individual track checkboxes (excludes group headers) */
    function trackCheckboxes() {
      return document.getElementById("track-toggles").querySelectorAll("input[data-track-idx]");
    }

    function buildTrackToggles(tracks) {
      const container = document.getElementById("track-toggles");
      container.innerHTML = "";
      // Reset barcode colors on new dataset
      resetBarcodeHues();

      // Group tracks by barcode
      const groups = new Map();
      for (let i = 0; i < tracks.length; i++) {
        const parsed = parseTrackName(tracks[i].name);
        if (!groups.has(parsed.barcode)) groups.set(parsed.barcode, []);
        groups.get(parsed.barcode).push({ idx: i, track: tracks[i], parsed });
      }

      // Apply MAX_DEFAULT_TRACKS cap
      const visibleCount = tracks.filter(t => !t.hidden).length;
      const needsCap = visibleCount > MAX_DEFAULT_TRACKS;
      let enabledCount = 0;

      // Toolbar: Select All / None
      const toolbar = document.createElement("div");
      toolbar.className = "track-toolbar";
      const allLabel = document.createElement("label");
      const allCb = document.createElement("input");
      allCb.type = "checkbox"; allCb.id = "check-all-tracks"; allCb.checked = false;
      allCb.onchange = () => bulkToggleAll(allCb.checked);
      allLabel.appendChild(allCb);
      allLabel.appendChild(document.createTextNode(" Select all"));
      toolbar.appendChild(allLabel);
      const noneBtn = document.createElement("button");
      noneBtn.className = "ctrl-btn"; noneBtn.textContent = "None";
      noneBtn.onclick = () => bulkToggleAll(false);
      toolbar.appendChild(noneBtn);
      container.appendChild(toolbar);

      // Build barcode groups
      for (const [bc, items] of groups) {
        const hue = barcodeHue(bc);
        const group = document.createElement("div");
        group.className = "bc-group";

        // Group header with barcode checkbox
        const header = document.createElement("div");
        header.className = "bc-group-header";
        const swatch = document.createElement("span");
        swatch.className = "swatch";
        swatch.style.background = "hsl(" + hue + ",70%,50%)";
        header.appendChild(swatch);
        const bcLabel = document.createElement("label");
        const bcCb = document.createElement("input");
        bcCb.type = "checkbox"; bcCb.dataset.barcode = bc;
        bcCb.onchange = () => bulkToggleBarcode(bc, bcCb.checked);
        bcLabel.appendChild(bcCb);
        bcLabel.appendChild(document.createTextNode(" " + bc + " (" + items.length + ")"));
        header.appendChild(bcLabel);
        group.appendChild(header);

        // Individual track checkboxes
        const checks = document.createElement("div");
        checks.className = "sample-checks";
        for (const item of items) {
          const label = document.createElement("label");
          const cb = document.createElement("input");
          cb.type = "checkbox";
          const wouldBeOn = !item.track.hidden;
          cb.checked = wouldBeOn && (!needsCap || enabledCount < MAX_DEFAULT_TRACKS);
          if (cb.checked) enabledCount++;
          cb.dataset.trackIdx = item.idx;
          cb.dataset.barcode = bc;
          cb.dataset.step = item.parsed.stepKey;
          if (item.track.hidden) cb.dataset.hidden = "1";
          cb.onchange = () => { toggleTrack(item.idx, cb.checked); syncGroupCheckboxes(); };
          label.appendChild(cb);
          label.appendChild(document.createTextNode(" " + item.parsed.rpiShort + " — " + item.parsed.stepLabel));
          checks.appendChild(label);
        }
        group.appendChild(checks);
        container.appendChild(group);
      }

      syncGroupCheckboxes();
      if (needsCap) showStatus("Large dataset: showing first " + MAX_DEFAULT_TRACKS +
        " of " + visibleCount + " tracks. Use barcode checkboxes to load more.");
    }

    /** Sync barcode-header and select-all checkboxes with individual states.
     *  Only counts non-hidden tracks — hidden tracks are excluded from
     *  the "all checked" calculation so the header can fully check/uncheck. */
    function syncGroupCheckboxes() {
      const allCbs = [...trackCheckboxes()];
      const visible = allCbs.filter(cb => !cb.dataset.hidden);
      // Per-barcode headers
      const bcHeaders = document.querySelectorAll(".bc-group-header input[data-barcode]");
      for (const bcCb of bcHeaders) {
        const bc = bcCb.dataset.barcode;
        const children = visible.filter(cb => cb.dataset.barcode === bc);
        const checked = children.filter(cb => cb.checked).length;
        bcCb.checked = children.length > 0 && checked === children.length;
        bcCb.indeterminate = checked > 0 && checked < children.length;
      }
      // Select-all
      const selectAll = document.getElementById("check-all-tracks");
      if (selectAll) {
        const total = visible.length;
        const checked = visible.filter(cb => cb.checked).length;
        selectAll.checked = total > 0 && checked === total;
        selectAll.indeterminate = checked > 0 && checked < total;
      }
      updateTrackSummary();
    }

    async function bulkToggleAll(checked) {
      for (const cb of trackCheckboxes()) {
        cb.checked = checked && !cb.dataset.hidden;  // skip hidden tracks when enabling
      }
      syncGroupCheckboxes();
      await reloadWithCurrentSelection();
    }

    async function bulkToggleBarcode(bc, checked) {
      for (const cb of trackCheckboxes()) {
        if (cb.dataset.barcode !== bc) continue;
        cb.checked = checked && !cb.dataset.hidden;  // skip hidden tracks when enabling
      }
      syncGroupCheckboxes();
      await reloadWithCurrentSelection();
    }

    /** Reload browser with current checkbox selection (for bulk operations) */
    async function reloadWithCurrentSelection() {
      if (loading) return;
      loading = true;
      try {
        const container = document.getElementById("igv-container");
        const rf = browser ? browser.referenceFrameList?.[0] : null;
        if (rf) lastLocus = rf.chr + ":" + (Math.round(rf.start) + 1) + "-" + Math.round(rf.end);
        if (browser) { igv.removeBrowser(browser); browser = null; }

        const showAll = document.getElementById("show-all").checked;
        const enabledTracks = getEnabledTracks(showAll);
        if (enabledTracks.length === 0) {
          showStatus("No tracks selected. Use the track checkboxes to enable tracks.");
          return;
        }

        const activeGroupBy = document.getElementById("group-by")?.value;
        const groupBy = (activeGroupBy && activeGroupBy !== "none") ? activeGroupBy : undefined;
        if (groupBy) {
          for (const t of enabledTracks) t.groupBy = groupBy;
        }

        const refSel = document.getElementById("ref-select");
        const refIdx = parseInt(refSel.value, 10) || 0;
        const ref = references[refIdx];
        if (!ref) return;

        showStatus("Loading " + enabledTracks.length + " tracks...");
        const browserCfg = {
          reference: ref,
          tracks: enabledTracks,
          loadDefaultGenomes: false,
        };
        if (lastLocus) browserCfg.locus = lastLocus;
        browser = await igv.createBrowser(container, browserCfg);

        /* Ensure locus is applied (config.locus can be ignored for some references) */
        if (lastLocus) {
          try { await browser.search(lastLocus); } catch {}
        }

        /* Inject sticky navbar into IGV.js Shadow DOM */
        if (browser.root) {
          const shadowRoot = browser.root.getRootNode();
          if (shadowRoot && shadowRoot !== document) {
            const style = document.createElement("style");
            style.textContent = ".igv-navbar { position: sticky !important; top: 0; z-index: 1100 !important; }";
            shadowRoot.appendChild(style);
          }
        }
        if (groupBy) {
          eachBAMTrack((tv, at) => { at.groupBy = groupBy; });
        }

        const cbar = document.getElementById("controls-bar");
        cbar.style.display = "block";
        updateStickyTops();

        const colorSel = document.getElementById("color-by");
        if (colorSel.value !== "none") setAllColor();

        showStatus("Ready. " + enabledTracks.length + " of " + allTracks.length + " tracks loaded.");
      } catch (e) {
        showStatus("Error: " + e.message);
      } finally {
        loading = false;
      }
    }

    function getEnabledTracks(showAll) {
      const enabled = [];
      for (const cb of trackCheckboxes()) {
        if (!cb.checked) continue;
        const t = allTracks[parseInt(cb.dataset.trackIdx, 10)];
        if (!t) continue;
        const extra = showAll ? SAMPLING_PARAMS.ALL : SAMPLING_PARAMS.NORMAL;
        enabled.push({ ...t, ...extra });
      }
      return enabled;
    }

    async function toggleTrack(idx, enabled) {
      if (loading) return;
      const t = allTracks[idx];
      if (!t) return;

      // Browser was destroyed (all tracks previously deselected). Recreate
      // it from the current checkbox state — otherwise the click is a silent
      // no-op and the user can't re-add tracks one at a time.
      if (!browser) {
        if (enabled) await reloadWithCurrentSelection();
        return;
      }

      if (enabled) {
        const showAll = document.getElementById("show-all").checked;
        const extra = showAll
          ? SAMPLING_PARAMS.ALL
          : SAMPLING_PARAMS.NORMAL;
        const activeGroupBy = document.getElementById("group-by")?.value;
        const groupBy = (activeGroupBy && activeGroupBy !== "none") ? activeGroupBy : undefined;
        const trackCfg = { ...t, ...extra };
        if (groupBy) trackCfg.groupBy = groupBy;
        try {
          await browser.loadTrack(trackCfg);
        } catch (e) {
          showStatus("Failed to load track: " + e.message);
        }
      } else {
        /* Remove by matching track name */
        const toRemove = browser.trackViews.find(
          tv => tv.track && tv.track.name === t.name
        );
        if (toRemove) browser.removeTrack(toRemove.track);
      }

      const loaded = browser.trackViews.filter(
        tv => tv.track && tv.track.alignmentTrack
      ).length;
      if (loaded === 0 && !enabled) {
        /* No tracks left — destroy browser to clear stale display */
        igv.removeBrowser(browser); browser = null;
        showStatus("No tracks loaded. Use the track checkboxes to enable tracks.");
      } else {
        showStatus("Showing " + loaded + " of " + allTracks.length + " tracks.");
      }
    }

    function updateStickyTops() {
      const headerH = document.querySelector("header").offsetHeight;
      const cbar = document.getElementById("controls-bar");
      cbar.style.top = headerH + "px";
      /* IGV navbar is inside Shadow DOM — reach it through browser.root */
      if (browser && browser.root) {
        const sr = browser.root.getRootNode();
        const navbar = sr && sr !== document ? sr.querySelector(".igv-navbar") : null;
        if (navbar) {
          navbar.style.top = (headerH + cbar.offsetHeight) + "px";
        }
      }
    }

    function toggleTrackList() {
      const panel = document.getElementById("track-list-panel");
      const arrow = document.getElementById("tracks-arrow");
      const isOpen = panel.style.display === "none";
      panel.style.display = isOpen ? "block" : "none";
      arrow.style.transform = isOpen ? "rotate(90deg)" : "";
      updateStickyTops();
    }

    function updateTrackSummary() {
      const cbs = trackCheckboxes();
      const total = cbs.length;
      const checked = [...cbs].filter(cb => cb.checked).length;
      document.getElementById("track-summary").textContent = checked + " / " + total + " shown";
    }

    function toggleControlsPanel() {
      const panel = document.getElementById("controls-panel");
      const arrow = document.getElementById("controls-arrow");
      const isOpen = panel.classList.toggle("open");
      arrow.classList.toggle("open", isOpen);
      updateStickyTops();
    }

    init();
