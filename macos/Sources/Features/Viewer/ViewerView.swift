import SwiftUI
import WebKit

/// SwiftUI root view for a viewer tab. Hosts a `WKWebView` that renders the
/// given HTML or Markdown file.
struct ViewerView: View {
    let fileURL: URL

    var body: some View {
        ViewerWebView(fileURL: fileURL)
            .ignoresSafeArea()
    }
}

/// `NSViewRepresentable` wrapper around `WKWebView`.
struct ViewerWebView: NSViewRepresentable {
    let fileURL: URL

    /// When set (split-pane usage), the web view is cached on the surface so it
    /// survives SwiftUI rebuilds of the split tree. nil for standalone tabs.
    var persistentHost: Ghostty.SurfaceView? = nil

    func makeNSView(context: Context) -> WKWebView {
        // Reuse a cached web view so content does not reload (flicker) when the
        // split tree rebuilds, e.g. after another pane is closed.
        if let cached = persistentHost?.viewerWebView as? WKWebView {
            return cached
        }

        let config = WKWebViewConfiguration()
        // A viewer never needs cookies or localStorage; a non-persistent store
        // skips disk I/O on init.
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsMagnification = true
        ViewerWebView.load(url: fileURL, into: webView)
        persistentHost?.viewerWebView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // The file URL is fixed for the lifetime of the view; nothing to do.
    }

    /// Renders `url` into `webView`: Markdown is converted to HTML, everything
    /// else (HTML, etc.) is loaded directly.
    static func load(url: URL, into webView: WKWebView) {
        let ext = url.pathExtension.lowercased()
        let dir = url.deletingLastPathComponent()

        switch ext {
        case "md", "markdown", "mdown", "mkd", "mkdn":
            let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? "# Could not read file\n\n`\(url.path)`"
            webView.loadHTMLString(ViewerHTML.markdownPage(markdown: text), baseURL: dir)
        default:
            // html, htm, or anything else: render the file directly. Grant
            // read access to the directory so relative assets resolve.
            webView.loadFileURL(url, allowingReadAccessTo: dir)
        }
    }
}

/// Builds the self-contained HTML page used to render Markdown. The page embeds
/// its own CSS and a compact Markdown-to-HTML renderer, so no network access or
/// bundled resources are required.
///
/// The Markdown source is embedded as a base64 string. base64's alphabet
/// (`A-Za-z0-9+/=`) contains no HTML-significant characters, so it can never
/// prematurely close the `<script>` element or break out of a string literal.
enum ViewerHTML {
    static func markdownPage(markdown: String) -> String {
        let b64 = Data(markdown.utf8).base64EncodedString()
        return template.replacingOccurrences(of: "__MARKDOWN_B64__", with: b64)
    }

    private static let template = #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root { color-scheme: light dark; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  font-size: 15px; line-height: 1.6;
  max-width: 880px; margin: 0 auto; padding: 32px 40px;
  color: #1f2328; background: #ffffff;
  -webkit-text-size-adjust: 100%; word-wrap: break-word;
}
h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 24px 0 16px; }
h1 { font-size: 2em; border-bottom: 1px solid #d1d9e0; padding-bottom: .3em; }
h2 { font-size: 1.5em; border-bottom: 1px solid #d1d9e0; padding-bottom: .3em; }
h3 { font-size: 1.25em; }
h4 { font-size: 1em; }
h5 { font-size: .875em; }
h6 { font-size: .85em; color: #59636e; }
p { margin: 0 0 16px; }
a { color: #0969da; text-decoration: none; }
a:hover { text-decoration: underline; }
code {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: .88em; background: #eff1f3; padding: .2em .4em; border-radius: 6px;
}
pre {
  background: #eff1f3; padding: 16px; border-radius: 8px; overflow: auto;
  line-height: 1.45;
}
pre code { background: none; padding: 0; font-size: .85em; }
blockquote {
  margin: 0 0 16px; padding: 0 1em; color: #59636e;
  border-left: .25em solid #d1d9e0;
}
ul, ol { margin: 0 0 16px; padding-left: 2em; }
li { margin: .25em 0; }
li > ul, li > ol { margin: .25em 0; }
img { max-width: 100%; }
hr { border: 0; height: 1px; background: #d1d9e0; margin: 24px 0; }
table { border-collapse: collapse; margin: 0 0 16px; display: block; overflow: auto; }
table th, table td { border: 1px solid #d1d9e0; padding: 6px 13px; }
table th { font-weight: 600; }
table tr:nth-child(2n) { background: #f6f8fa; }
@media (prefers-color-scheme: dark) {
  body { color: #e6edf3; background: #0d1117; }
  h1, h2 { border-color: #3d444d; }
  h6 { color: #9198a1; }
  a { color: #4493f8; }
  code, pre { background: #161b22; }
  blockquote { color: #9198a1; border-color: #3d444d; }
  hr { background: #3d444d; }
  table th, table td { border-color: #3d444d; }
  table tr:nth-child(2n) { background: #161b22; }
}
</style>
</head>
<body>
<div id="content"></div>
<script>
var MD_B64 = "__MARKDOWN_B64__";
(function () {
  "use strict";

  function decodeBase64Utf8(b64) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder("utf-8").decode(bytes);
  }

  var SRC = decodeBase64Utf8(MD_B64);

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // Format inline spans. The text is split on inline code spans so code is
  // never touched by the emphasis/link passes, and no sentinel characters
  // are needed.
  function inlineFmt(text) {
    var parts = text.split(/(`[^`\n]+`)/);
    var out = "";
    for (var p = 0; p < parts.length; p++) {
      var seg = parts[p];
      if (seg.length >= 2 && seg.charAt(0) === "`" && seg.charAt(seg.length - 1) === "`") {
        out += "<code>" + esc(seg.slice(1, -1)) + "</code>";
        continue;
      }
      var s = esc(seg);
      s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g,
        '<img alt="$1" src="$2">');
      s = s.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g,
        '<a href="$2">$1</a>');
      s = s.replace(/\*\*([^\s](?:[\s\S]*?[^\s])?)\*\*/g, "<strong>$1</strong>");
      s = s.replace(/\*([^\s*](?:[\s\S]*?[^\s*])?)\*/g, "<em>$1</em>");
      s = s.replace(/~~([^~]+)~~/g, "<del>$1</del>");
      out += s;
    }
    return out;
  }

  function splitRow(row) {
    return row.trim().replace(/^\|/, "").replace(/\|$/, "")
      .split("|").map(function (c) { return c.trim(); });
  }

  function blank(s) { return /^\s*$/.test(s); }

  function renderList(block) {
    var baseIndent = block[0].match(/^(\s*)/)[1].length;
    var ordered = /^\s*\d+[.)]/.test(block[0]);
    var items = [];
    var cur = null;
    for (var k = 0; k < block.length; k++) {
      var m = block[k].match(/^(\s*)([-*+]|\d+[.)])\s+([\s\S]*)$/);
      if (m && m[1].length <= baseIndent) {
        cur = [m[3]];
        items.push(cur);
      } else if (cur) {
        cur.push(block[k].replace(new RegExp("^\\s{0," + (baseIndent + 2) + "}"), ""));
      }
    }
    var tag = ordered ? "ol" : "ul";
    var html = "<" + tag + ">";
    for (var n = 0; n < items.length; n++) {
      var content = items[n].join("\n");
      if (/\n\s*([-*+]|\d+[.)])\s+/.test("\n" + content)) {
        html += "<li>" + render(content) + "</li>";
      } else {
        html += "<li>" + inlineFmt(content.replace(/\n/g, " ")) + "</li>";
      }
    }
    return html + "</" + tag + ">";
  }

  function render(text) {
    var lines = text.replace(/\r\n?/g, "\n").split("\n");
    var out = [];
    var i = 0;
    while (i < lines.length) {
      var l = lines[i];

      if (blank(l)) { i++; continue; }

      // Fenced code block
      var f = l.match(/^\s*(`{3,}|~{3,})/);
      if (f) {
        var fchar = f[1].charAt(0);
        var closeRe = new RegExp("^\\s*" + fchar + "{3,}\\s*$");
        var code = [];
        i++;
        while (i < lines.length && !closeRe.test(lines[i])) { code.push(lines[i]); i++; }
        i++;
        out.push("<pre><code>" + esc(code.join("\n")) + "</code></pre>");
        continue;
      }

      // ATX heading
      var h = l.match(/^(#{1,6})\s+(.*?)\s*#*\s*$/);
      if (h) {
        var lv = h[1].length;
        out.push("<h" + lv + ">" + inlineFmt(h[2]) + "</h" + lv + ">");
        i++;
        continue;
      }

      // Horizontal rule
      if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(l)) { out.push("<hr>"); i++; continue; }

      // Blockquote
      if (/^\s*>/.test(l)) {
        var bq = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) {
          bq.push(lines[i].replace(/^\s*>\s?/, ""));
          i++;
        }
        out.push("<blockquote>" + render(bq.join("\n")) + "</blockquote>");
        continue;
      }

      // GFM table
      if (l.indexOf("|") >= 0 && i + 1 < lines.length &&
          /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/.test(lines[i + 1])) {
        var headers = splitRow(l);
        var aligns = splitRow(lines[i + 1]).map(function (c) {
          var L = c.charAt(0) === ":", R = c.charAt(c.length - 1) === ":";
          return L && R ? "center" : R ? "right" : L ? "left" : "";
        });
        i += 2;
        var rows = [];
        while (i < lines.length && lines[i].indexOf("|") >= 0 && !blank(lines[i])) {
          rows.push(splitRow(lines[i]));
          i++;
        }
        var t = "<table><thead><tr>";
        for (var c = 0; c < headers.length; c++) {
          var a = aligns[c] ? ' style="text-align:' + aligns[c] + '"' : "";
          t += "<th" + a + ">" + inlineFmt(headers[c]) + "</th>";
        }
        t += "</tr></thead><tbody>";
        for (var r = 0; r < rows.length; r++) {
          t += "<tr>";
          for (var c2 = 0; c2 < headers.length; c2++) {
            var a2 = aligns[c2] ? ' style="text-align:' + aligns[c2] + '"' : "";
            t += "<td" + a2 + ">" + inlineFmt(rows[r][c2] || "") + "</td>";
          }
          t += "</tr>";
        }
        out.push(t + "</tbody></table>");
        continue;
      }

      // Raw HTML block: passed through verbatim (CommonMark allows raw HTML).
      if (/^\s*<(\/?[a-zA-Z][\w-]*|!--)/.test(l)) {
        var hb = [];
        while (i < lines.length && !blank(lines[i])) { hb.push(lines[i]); i++; }
        out.push(hb.join("\n"));
        continue;
      }

      // List
      if (/^\s*([-*+]|\d+[.)])\s+/.test(l)) {
        var blk = [];
        while (i < lines.length &&
               (/^\s*([-*+]|\d+[.)])\s+/.test(lines[i]) ||
                (!blank(lines[i]) && /^\s+\S/.test(lines[i])))) {
          blk.push(lines[i]);
          i++;
        }
        out.push(renderList(blk));
        continue;
      }

      // Paragraph
      var para = [];
      while (i < lines.length && !blank(lines[i]) &&
             !/^(#{1,6})\s/.test(lines[i]) &&
             !/^\s*>/.test(lines[i]) &&
             !/^\s*(`{3,}|~{3,})/.test(lines[i]) &&
             !/^\s*([-*+]|\d+[.)])\s+/.test(lines[i]) &&
             !/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(lines[i])) {
        para.push(lines[i]);
        i++;
      }
      out.push("<p>" + inlineFmt(para.join("\n")).replace(/\n/g, "<br>\n") + "</p>");
    }
    return out.join("\n");
  }

  document.getElementById("content").innerHTML = render(SRC);
})();
</script>
</body>
</html>
"""#
}
