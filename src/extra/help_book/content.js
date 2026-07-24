// Included by every content page. When a page is opened standalone (a
// search result or anchor deep link), it redirects itself into the shell
// so the persistent sidebar appears. Inside the shell's iframe it reports
// its identity to the shell (for sidebar highlighting).
(function () {
  var page = location.pathname.split("/").pop();
  if (window.top === window.self) {
    location.replace("index.html#" + page + location.hash);
    return;
  }
  try {
    parent.postMessage({ page: page }, "*");
  } catch (e) {}
})();
