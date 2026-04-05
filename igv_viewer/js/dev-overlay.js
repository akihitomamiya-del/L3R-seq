"use strict";
// Dev Overlay — Ctrl+Shift+D to toggle.
// Hover: see component name + selector. Click: copy to clipboard.
(function() {
  var active = false, tooltip = null, badge = null, highlighted = null;
  var PAGE = (location.pathname.replace(/^\/|\.html$/g, "") || "index") + ".html";

  // --- Auto-derive a human-readable name from any element ---
  function nameOf(el) {
    // data-view buttons ("View: chart")
    var dv = el.getAttribute && el.getAttribute("data-view");
    if (dv) return "View: " + dv;
    // data-gene links
    var dg = el.getAttribute && el.getAttribute("data-gene");
    if (dg) return "Gene link: " + dg;
    // sample checkboxes
    var did = el.getAttribute && el.getAttribute("data-id");
    if (did) return "Sample: " + did;
    // track checkboxes
    var dti = el.getAttribute && el.getAttribute("data-track-idx");
    if (dti) { var lbl = el.parentElement ? el.parentElement.textContent.trim() : ""; return "Track: " + (lbl || "#" + dti); }
    // barcode group headers
    var dbc = el.getAttribute && el.getAttribute("data-barcode");
    if (dbc) return "Barcode group: " + dbc;
    // sortable table headers
    var dc = el.getAttribute && el.getAttribute("data-col");
    if (dc) return "Sort column: " + dc;
    // elements with id — humanize it
    if (el.id) return el.id.replace(/[-_]/g, " ");
    // canvas inside chart container
    if (el.tagName === "CANVAS") {
      var ct = el.closest(".chart-container");
      var h3 = ct && ct.querySelector("h3");
      return "Chart: " + (h3 ? h3.textContent : "canvas");
    }
    // labeled inputs
    var label = el.closest && el.closest("label");
    if (label && label !== el) return label.textContent.trim().substring(0, 40);
    // class-based fallback
    if (el.className && typeof el.className === "string") {
      var cls = el.className.trim().split(/\s+/)[0];
      if (cls) return cls.replace(/[-_]/g, " ");
    }
    return el.tagName.toLowerCase();
  }

  // --- Walk up to find a meaningful ancestor name ---
  function identify(el) {
    var name = nameOf(el);
    var sel = selectorOf(el);
    // If the name is just a tag, walk up for context
    if (name === el.tagName.toLowerCase()) {
      for (var p = el.parentElement, i = 0; p && i < 4; p = p.parentElement, i++) {
        var pn = nameOf(p);
        if (pn !== p.tagName.toLowerCase()) { name = pn + " > " + name; break; }
      }
    }
    return { name: name, sel: sel };
  }

  function selectorOf(el) {
    if (el.id) return "#" + el.id;
    var s = el.tagName.toLowerCase();
    var dv = el.getAttribute && el.getAttribute("data-view");
    if (dv) return "[data-view='" + dv + "']";
    var did = el.getAttribute && el.getAttribute("data-id");
    if (did) return "[data-id='" + did + "']";
    var dti = el.getAttribute && el.getAttribute("data-track-idx");
    if (dti) return "[data-track-idx='" + dti + "']";
    var dg = el.getAttribute && el.getAttribute("data-gene");
    if (dg) return "[data-gene='" + dg + "']";
    if (el.className && typeof el.className === "string")
      s += "." + el.className.trim().split(/\s+/)[0];
    var par = el.parentElement;
    if (par && par.id) s = "#" + par.id + " > " + s;
    return s;
  }

  function escHtml(s) { return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;"); }

  // --- UI ---
  function ensureUI() {
    if (!tooltip) {
      tooltip = document.createElement("div");
      tooltip.id = "dev-overlay-tooltip";
      tooltip.style.cssText = "position:fixed;z-index:999999;pointer-events:none;background:#1a1a2e;color:#e0e0e0;padding:8px 12px;border-radius:6px;font:12px/1.5 'SF Mono',Consolas,monospace;max-width:420px;box-shadow:0 4px 16px rgba(0,0,0,0.4);border:1px solid #444;display:none;white-space:pre-line";
      document.body.appendChild(tooltip);
    }
    if (!badge) {
      badge = document.createElement("div");
      badge.id = "dev-overlay-badge";
      badge.textContent = "DEV OVERLAY";
      badge.style.cssText = "position:fixed;bottom:12px;right:12px;z-index:999998;background:#e74c3c;color:#fff;padding:4px 12px;border-radius:4px;font:bold 11px system-ui;cursor:pointer;user-select:none;box-shadow:0 2px 8px rgba(0,0,0,0.3)";
      badge.title = "Ctrl+Shift+D to toggle";
      badge.onclick = toggle;
      document.body.appendChild(badge);
    }
  }

  function clearHighlight() {
    if (!highlighted) return;
    highlighted.style.outline = highlighted._devO || "";
    highlighted.style.outlineOffset = highlighted._devOO || "";
    highlighted = null;
  }

  function onMove(e) {
    var el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === tooltip || el === badge) { tooltip.style.display = "none"; clearHighlight(); return; }
    var info = identify(el);
    tooltip.innerHTML = '<span style="color:#f39c12;font-weight:bold">' + escHtml(info.name) + '</span>\n<span style="color:#888">sel:</span> ' + escHtml(info.sel) + '\n<span style="color:#888">page:</span> ' + PAGE;
    tooltip.style.display = "block";
    var tx = e.clientX + 16, ty = e.clientY + 16, r = tooltip.getBoundingClientRect();
    if (tx + r.width > innerWidth - 8) tx = e.clientX - r.width - 8;
    if (ty + r.height > innerHeight - 8) ty = e.clientY - r.height - 8;
    tooltip.style.left = tx + "px"; tooltip.style.top = ty + "px";
    if (highlighted !== el) { clearHighlight(); el._devO = el.style.outline; el._devOO = el.style.outlineOffset; el.style.outline = "2px solid #e74c3c"; el.style.outlineOffset = "-1px"; highlighted = el; }
  }

  function onClick(e) {
    var el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === tooltip || el === badge) return;
    var info = identify(el);
    navigator.clipboard.writeText(info.name + "  (" + info.sel + ")").catch(function(){});
    var f = document.createElement("div"); f.textContent = "Copied!";
    f.style.cssText = "position:fixed;z-index:9999999;pointer-events:none;background:#27ae60;color:#fff;padding:4px 10px;border-radius:4px;font:bold 12px system-ui;transition:opacity 0.6s;left:" + e.clientX + "px;top:" + (e.clientY-30) + "px";
    document.body.appendChild(f); setTimeout(function(){f.style.opacity="0"},200); setTimeout(function(){f.remove()},800);
    e.preventDefault(); e.stopPropagation();
  }

  function toggle() {
    active = !active;
    ensureUI();
    if (active) { badge.style.display = "block"; document.addEventListener("mousemove", onMove, true); document.addEventListener("click", onClick, true); }
    else { tooltip.style.display = "none"; badge.style.display = "none"; clearHighlight(); document.removeEventListener("mousemove", onMove, true); document.removeEventListener("click", onClick, true); }
  }

  document.addEventListener("keydown", function(e) { if (e.ctrlKey && e.shiftKey && e.key === "D") { e.preventDefault(); toggle(); } });
})();
