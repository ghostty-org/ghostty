/**
 * Mobile navigation toggle for Doxygen documentation
 */

(function () {
  // Must match the max-width of the mobile styles in ghostty.css.
  function isMobile() {
    return window.innerWidth <= 767;
  }

  function initMobileNav() {
    const pageNav = document.getElementById("page-nav");
    if (!pageNav) return;

    // Doxygen fills this in at load. Some pages have nothing to list.
    if (!pageNav.querySelector("#page-nav-contents li")) return;

    // Create toggle button. This is created regardless of the current width
    // and shown with CSS so that it's available after rotating the device.
    const toggleBtn = document.createElement("button");
    toggleBtn.id = "page-nav-toggle";
    toggleBtn.type = "button";
    toggleBtn.textContent = "Contents";
    toggleBtn.setAttribute("aria-expanded", "false");
    toggleBtn.setAttribute("aria-controls", "page-nav");
    document.body.appendChild(toggleBtn);

    // Create backdrop
    const backdrop = document.createElement("div");
    backdrop.id = "page-nav-backdrop";
    document.body.appendChild(backdrop);

    function setOpen(isOpen) {
      pageNav.classList.toggle("mobile-open", isOpen);
      backdrop.classList.toggle("active", isOpen);
      document.body.style.overflow = isOpen ? "hidden" : "";
      toggleBtn.textContent = isOpen ? "Close" : "Contents";
      toggleBtn.setAttribute("aria-expanded", String(isOpen));
    }

    function toggleNav() {
      setOpen(!pageNav.classList.contains("mobile-open"));
    }

    // Event listeners
    toggleBtn.addEventListener("click", toggleNav);
    backdrop.addEventListener("click", toggleNav);

    // Close after following a link so the destination is visible
    pageNav.addEventListener("click", function (e) {
      if (e.target.closest("a")) setOpen(false);
    });

    // Close on escape key
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && pageNav.classList.contains("mobile-open")) {
        toggleNav();
      }
    });

    window.addEventListener("resize", function () {
      if (!isMobile()) setOpen(false);
    });
  }

  // On mobile, table rows stack into cards so cells lose their column header.
  // Label them, skipping the first cell which titles the card. Tables with two
  // columns read fine without this since the second cell is just a description.
  function labelTableCells() {
    document.querySelectorAll("table.markdownTable").forEach(function (table) {
      const headers = table.querySelectorAll("tr.markdownTableHead th");
      if (headers.length < 3) return;

      table.querySelectorAll("tr").forEach(function (row) {
        Array.from(row.cells).forEach(function (cell, i) {
          if (i > 0 && cell.tagName === "TD") {
            cell.dataset.label = headers[i].textContent.trim();
          }
        });
      });
    });
  }

  // This has to wait for load rather than DOMContentLoaded because our
  // DOMContentLoaded listener would run before Doxygen's fills in the page nav.
  function init() {
    initMobileNav();
    labelTableCells();
  }

  if (document.readyState === "complete") {
    init();
  } else {
    window.addEventListener("load", init);
  }
})();
