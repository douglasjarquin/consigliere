import { DOCS_NAV, SITE_NAV } from "./pages.mjs";
import { MADE_URL } from "./seo.mjs";
import { sitePath } from "./site-path.mjs";

export function paletteItems() {
  const pages = [...DOCS_NAV, ...SITE_NAV].flatMap((group) =>
    group.items.map((item) => ({
      title: item.label,
      href: sitePath(item.slug),
      kind: group.heading.toLowerCase(),
    })),
  );
  return [
    ...pages,
    { title: "Toggle lights", href: "#toggle-theme", kind: "command" },
    { title: "made ↗", href: MADE_URL, kind: "sister" },
  ];
}
