// Open DC - modern Dynamic Components for SketchUp
// Copyright (C) 2026 Jure Judež and contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

// OS color mode for the HtmlDialogs, applied as html[data-theme].
// prefers-color-scheme works on CEF 86+ (SketchUp 2021.1+), but some CEF
// embedders never propagate the OS mode - so Ruby also pushes the truth
// (Windows AppsUseLightTheme) through OpenDCTheme.set() on every state
// push. The forced value wins; set(null) hands control back to the
// media query (non-Windows platforms).
window.OpenDCTheme = (function () {
  var mq = window.matchMedia
    ? window.matchMedia("(prefers-color-scheme: light)")
    : null;
  var forced = null;

  function apply() {
    var t = forced || (mq && mq.matches ? "light" : "dark");
    document.documentElement.setAttribute("data-theme", t);
  }

  function set(t) {
    forced = t === "light" || t === "dark" ? t : null;
    apply();
  }

  if (mq && mq.addEventListener) mq.addEventListener("change", apply);
  apply();

  return { set: set, apply: apply };
})();
