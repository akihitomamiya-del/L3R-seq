"use strict";
// Dev Overlay — click DEV to toggle. Right-click to copy label.
(function() {
  var active = false, tooltip = null, badge = null;
  var PAGE = (location.pathname.replace(/^\/|\.html$/g, "") || "index") + ".html";

  function nameOf(el) {
    var dv = el.getAttribute && el.getAttribute("data-view");
    if (dv) return "View: " + dv;
    var dg = el.getAttribute && el.getAttribute("data-gene");
    if (dg) return "Gene link: " + dg;
    var did = el.getAttribute && el.getAttribute("data-id");
    if (did) return "Sample: " + did;
    var dti = el.getAttribute && el.getAttribute("data-track-idx");
    if (dti) { var lbl = el.parentElement ? el.parentElement.textContent.trim() : ""; return "Track: " + (lbl || "#" + dti); }
    var dbc = el.getAttribute && el.getAttribute("data-barcode");
    if (dbc) return "Barcode group: " + dbc;
    var dc = el.getAttribute && el.getAttribute("data-col");
    if (dc) return "Sort column: " + dc;
    if (el.id) return el.id.replace(/[-_]/g, " ");
    if (el.tagName === "CANVAS") {
      var ct = el.closest(".chart-container");
      var h3 = ct && ct.querySelector("h3");
      return "Chart: " + (h3 ? h3.textContent : "canvas");
    }
    var label = el.closest && el.closest("label");
    if (label && label !== el) return label.textContent.trim().substring(0, 40);
    if (el.className && typeof el.className === "string") {
      var cls = el.className.trim().split(/\s+/)[0];
      if (cls) return cls.replace(/[-_]/g, " ");
    }
    return el.tagName.toLowerCase();
  }

  function identify(el) {
    var name = nameOf(el), sel = selectorOf(el);
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
    var attr = ["data-view","data-id","data-track-idx","data-gene"];
    for (var i = 0; i < attr.length; i++) {
      var v = el.getAttribute && el.getAttribute(attr[i]);
      if (v) return "[" + attr[i] + "='" + v + "']";
    }
    if (el.className && typeof el.className === "string")
      s += "." + el.className.trim().split(/\s+/)[0];
    var par = el.parentElement;
    if (par && par.id) s = "#" + par.id + " > " + s;
    return s;
  }

  function esc(s) { return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;"); }

  function copyText(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.cssText = "position:fixed;left:-9999px";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    ta.remove();
  }

  function flash(x, y) {
    var f = document.createElement("div");
    f.textContent = "Copied!";
    f.style.cssText = "position:fixed;z-index:9999999;pointer-events:none;background:#27ae60;color:#fff;padding:4px 10px;border-radius:4px;font:bold 12px system-ui;transition:opacity 0.6s;left:" + x + "px;top:" + (y - 30) + "px";
    document.body.appendChild(f);
    setTimeout(function() { f.style.opacity = "0"; }, 200);
    setTimeout(function() { f.remove(); }, 800);
  }

  function init() {
    badge = document.createElement("div");
    badge.id = "dev-overlay-badge";
    badge.textContent = "DEV";
    badge.style.cssText = "position:fixed;bottom:12px;right:12px;z-index:999998;background:#888;color:#fff;padding:4px 10px;border-radius:4px;font:bold 11px system-ui;cursor:pointer;user-select:none;box-shadow:0 2px 8px rgba(0,0,0,0.3);opacity:0.5";
    badge.onclick = toggle;
    document.body.appendChild(badge);

    tooltip = document.createElement("div");
    tooltip.id = "dev-overlay-tooltip";
    tooltip.style.cssText = "position:fixed;z-index:999999;pointer-events:none;background:#1a1a2e;color:#e0e0e0;padding:8px 12px;border-radius:6px;font:12px/1.5 'SF Mono',Consolas,monospace;max-width:420px;box-shadow:0 4px 16px rgba(0,0,0,0.4);border:1px solid #444;display:none;white-space:pre-line";
    document.body.appendChild(tooltip);
  }

  function onMove(e) {
    var el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === tooltip || el === badge) { tooltip.style.display = "none"; return; }
    var info = identify(el);
    tooltip.innerHTML = '<span style="color:#f39c12;font-weight:bold">' + esc(info.name) + '</span>\n<span style="color:#888">sel:</span> ' + esc(info.sel) + '\n<span style="color:#555">right-click to copy</span>';
    tooltip.style.display = "block";
    var tx = e.clientX + 16, ty = e.clientY + 16, r = tooltip.getBoundingClientRect();
    if (tx + r.width > innerWidth - 8) tx = e.clientX - r.width - 8;
    if (ty + r.height > innerHeight - 8) ty = e.clientY - r.height - 8;
    tooltip.style.left = tx + "px"; tooltip.style.top = ty + "px";
  }

  function onContext(e) {
    var el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === tooltip || el === badge) return;
    var info = identify(el);
    copyText(info.name + "  (" + info.sel + ")");
    flash(e.clientX, e.clientY);
    e.preventDefault();
  }

  function toggle() {
    active = !active;
    if (active) {
      badge.textContent = "DEV ON";
      badge.style.background = "#e74c3c";
      badge.style.opacity = "1";
      document.addEventListener("mousemove", onMove, false);
      document.addEventListener("contextmenu", onContext, false);
    } else {
      badge.textContent = "DEV";
      badge.style.background = "#888";
      badge.style.opacity = "0.5";
      tooltip.style.display = "none";
      document.removeEventListener("mousemove", onMove, false);
      document.removeEventListener("contextmenu", onContext, false);
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
