import { DESIGN_HREF_TO_SLUG } from "./pages.mjs";
import { MADE_URL } from "./seo.mjs";
import { sitePath } from "./site-path.mjs";

const MADE_HREFS = new Set(["../made/Home.dc.html", "../made/Design System.dc.html"]);

export function rewriteHtml(html) {
  return html.replace(/href="([^"]+)"/g, (all, href) => {
    if (
      href.startsWith("#") ||
      href.startsWith("http://") ||
      href.startsWith("https://") ||
      href.startsWith("mailto:")
    ) {
      return all;
    }
    if (MADE_HREFS.has(href)) {
      return `href="${MADE_URL}"`;
    }
    if (Object.hasOwn(DESIGN_HREF_TO_SLUG, href)) {
      const slug = DESIGN_HREF_TO_SLUG[href];
      return `href="${slug ? sitePath(slug) : sitePath()}"`;
    }
    return all;
  });
}

export function tocFromHtml(html) {
  const headings = [];
  const pattern = /<h2 id="([^"]+)"[^>]*>([\s\S]*?)<\/h2>/g;
  for (const match of html.matchAll(pattern)) {
    headings.push({
      id: match[1],
      title: match[2].replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim(),
    });
  }
  return headings;
}
