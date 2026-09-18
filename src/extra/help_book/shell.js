// The shell page script: drives the content iframe from the location
// hash and highlights the current page in the sidebar.
(function () {
  var frame = document.getElementById("content");

  // The location hash addresses the page shown in the content frame,
  // e.g. index.html#option.font-size.html. Only same-directory page
  // names (with an optional anchor) are allowed as frame targets.
  function navigate() {
    var target = location.hash.slice(1) || "home.html";
    if (!/^[\w.-]+\.html(#[\w.-]*)?$/.test(target)) target = "home.html";
    if (frame.getAttribute("src") !== target) {
      frame.setAttribute("src", target);
    }
  }
  window.addEventListener("hashchange", navigate);
  navigate();

  // Content pages report their identity when they load in the frame
  // (for sidebar highlighting).
  window.addEventListener("message", function (ev) {
    var d = ev.data || {};
    if (d.page) {
      var cur = document.querySelector("nav.sidebar a.current");
      if (cur) cur.className = "";
      var a = document.getElementById(d.page.replace(/\.html$/, ""));
      if (a) {
        a.className = "current";
        var det = a.closest("details");
        if (det) det.open = true;
      }
      if (location.hash.slice(1).split("#")[0] !== d.page) {
        try {
          history.replaceState(null, "", "#" + d.page);
        } catch (e) {}
      }
    }
  });
})();
