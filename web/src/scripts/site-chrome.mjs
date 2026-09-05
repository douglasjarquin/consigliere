const THEME_KEY = "cs-theme";

function currentTheme() {
  return document.documentElement.dataset.theme === "light" ? "light" : "dark";
}

function applyTheme(theme) {
  const next = theme === "light" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  document.body.dataset.theme = next;
  document.documentElement.style.colorScheme = next;
  try {
    localStorage.setItem(THEME_KEY, next);
  } catch {}
  for (const button of document.querySelectorAll("[data-theme-toggle]")) {
    button.textContent = next === "dark" ? "Lights on" : "Lights off";
  }
}

function toggleTheme() {
  applyTheme(currentTheme() === "light" ? "dark" : "light");
}

function isTypingTarget(target) {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName.toLowerCase();
  return tag === "input" || tag === "textarea" || target.isContentEditable;
}

function closeOverlays() {
  for (const overlay of document.querySelectorAll("[data-overlay]")) {
    overlay.hidden = true;
  }
  const search = document.querySelector("[data-open-palette]");
  if (search instanceof HTMLElement) search.setAttribute("aria-expanded", "false");
  const menu = document.querySelector("[data-open-drawer]");
  if (menu instanceof HTMLElement) menu.setAttribute("aria-expanded", "false");
}

function openOverlay(name) {
  closeOverlays();
  const overlay = document.querySelector(`[data-overlay="${name}"]`);
  if (!(overlay instanceof HTMLElement)) return;
  overlay.hidden = false;
  if (name === "palette") {
    const search = document.querySelector("[data-open-palette]");
    if (search instanceof HTMLElement) search.setAttribute("aria-expanded", "true");
    const input = overlay.querySelector("[data-palette-input]");
    if (input instanceof HTMLInputElement) {
      input.value = "";
      renderPalette(overlay, "");
      input.focus();
    }
  }
  if (name === "drawer") {
    const menu = document.querySelector("[data-open-drawer]");
    if (menu instanceof HTMLElement) menu.setAttribute("aria-expanded", "true");
  }
}

function paletteCatalog() {
  const node = document.getElementById("site-palette-data");
  if (!node) return [];
  try {
    const parsed = JSON.parse(node.textContent || "[]");
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function renderPalette(overlay, query) {
  const itemsRoot = overlay.querySelector("[data-palette-items]");
  const empty = overlay.querySelector("[data-palette-empty]");
  const emptyQuery = overlay.querySelector("[data-palette-query]");
  if (!(itemsRoot instanceof HTMLElement) || !(empty instanceof HTMLElement)) return;
  const needle = query.trim().toLowerCase();
  const matches = paletteCatalog()
    .filter(
      (item) =>
        !needle ||
        String(item.title).toLowerCase().includes(needle) ||
        String(item.kind).toLowerCase().includes(needle),
    )
    .slice(0, 8);
  itemsRoot.replaceChildren();
  matches.forEach((item, index) => {
    const link = document.createElement("a");
    link.className = `palette__item${index === 0 ? " is-active" : ""}`;
    link.href = item.href;
    link.dataset.paletteItem = "";
    link.innerHTML = `<span>${item.title}</span><span class="palette__kind">${item.kind}</span>`;
    itemsRoot.append(link);
  });
  empty.hidden = matches.length !== 0;
  if (emptyQuery) emptyQuery.textContent = query;
  overlay.dataset.activeIndex = matches.length ? "0" : "-1";
}

function paletteItems(overlay) {
  return [...overlay.querySelectorAll("[data-palette-item]")];
}

function movePalette(overlay, delta) {
  const items = paletteItems(overlay);
  if (items.length === 0) return;
  const current = Number(overlay.dataset.activeIndex || "0");
  const next = Math.max(0, Math.min(items.length - 1, current + delta));
  overlay.dataset.activeIndex = String(next);
  items.forEach((item, index) => item.classList.toggle("is-active", index === next));
}

function activatePalette(overlay) {
  const items = paletteItems(overlay);
  const current = Number(overlay.dataset.activeIndex || "0");
  const item = items[current];
  if (!(item instanceof HTMLAnchorElement)) return;
  if (item.getAttribute("href") === "#toggle-theme") {
    toggleTheme();
    closeOverlays();
    return;
  }
  window.location.assign(item.href);
}

function neighborHref(direction) {
  const node = document.getElementById("site-page-order");
  if (!node) return "";
  try {
    const order = JSON.parse(node.textContent || "[]");
    const current = document.body.dataset.pageSlug;
    const index = order.findIndex((item) => item?.slug === current);
    if (index < 0) return "";
    const next = direction === "next" ? order[index + 1] : order[index - 1];
    return typeof next?.href === "string" ? next.href : "";
  } catch {
    return "";
  }
}

function enhanceCopyButtons() {
  for (const pre of document.querySelectorAll(".docs-main pre, .home-main pre")) {
    if (!(pre instanceof HTMLElement) || pre.querySelector(".copy-button")) continue;
    pre.style.position = "relative";
    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy-button";
    button.textContent = "copy";
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(pre.innerText.replace(/^copy\n/, ""));
        button.textContent = "copied";
        setTimeout(() => {
          button.textContent = "copy";
        }, 2000);
      } catch {}
    });
    pre.append(button);
  }
}

function spyToc() {
  const links = [...document.querySelectorAll("[data-toc-link]")];
  if (links.length === 0) return;
  const y = window.innerHeight / 3;
  let best = links[0];
  let bestDistance = Infinity;
  for (const link of links) {
    const id = link.getAttribute("href")?.slice(1);
    if (!id) continue;
    const target = document.getElementById(id);
    if (!target) continue;
    const distance = Math.abs(target.getBoundingClientRect().top - y);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = link;
    }
  }
  for (const link of links) {
    const current = link === best;
    link.classList.toggle("is-current", current);
    if (current) link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  }
}

applyTheme(localStorage.getItem(THEME_KEY) || "dark");
enhanceCopyButtons();
spyToc();

for (const button of document.querySelectorAll("[data-theme-toggle]")) {
  button.addEventListener("click", toggleTheme);
}
for (const button of document.querySelectorAll("[data-open-palette]")) {
  button.addEventListener("click", () => openOverlay("palette"));
}
for (const button of document.querySelectorAll("[data-open-drawer]")) {
  button.addEventListener("click", () => openOverlay("drawer"));
}
for (const button of document.querySelectorAll("[data-open-sheet]")) {
  button.addEventListener("click", () => openOverlay("sheet"));
}
for (const button of document.querySelectorAll("[data-close-overlay]")) {
  button.addEventListener("click", closeOverlays);
}
for (const overlay of document.querySelectorAll("[data-overlay]")) {
  overlay.addEventListener("click", (event) => {
    if (event.target === overlay) closeOverlays();
  });
  overlay.querySelector("[data-overlay-panel]")?.addEventListener("click", (event) => {
    event.stopPropagation();
  });
}

const palette = document.querySelector('[data-overlay="palette"]');
const paletteInput = palette?.querySelector("[data-palette-input]");
if (palette instanceof HTMLElement && paletteInput instanceof HTMLInputElement) {
  paletteInput.addEventListener("input", () => renderPalette(palette, paletteInput.value));
  paletteInput.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      movePalette(palette, 1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      movePalette(palette, -1);
    } else if (event.key === "Enter") {
      event.preventDefault();
      activatePalette(palette);
    }
  });
}

window.addEventListener(
  "scroll",
  () => {
    spyToc();
  },
  { passive: true },
);

document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault();
    openOverlay("palette");
    return;
  }
  if (event.key === "Escape") {
    closeOverlays();
    return;
  }
  if (isTypingTarget(event.target)) return;
  if (event.key === "?") openOverlay("sheet");
  else if (event.key.toLowerCase() === "l") toggleTheme();
  else if (event.key.toLowerCase() === "m") openOverlay("drawer");
  else if (event.key === "]" || event.key === "[") {
    const href = neighborHref(event.key === "]" ? "next" : "prev");
    if (href) window.location.assign(href);
  }
});
