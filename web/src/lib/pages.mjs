export const DESIGN_HREF_TO_SLUG = Object.freeze({
  "Home C.dc.html": "",
  "Home A.dc.html": "",
  "Home B.dc.html": "",
  "Quick Start.dc.html": "quick-start",
  "Architecture.dc.html": "architecture",
  "Backup.dc.html": "backup",
  "CLI.dc.html": "cli",
  "Changelog.dc.html": "changelog",
  "Configuration.dc.html": "configuration",
  "Design System.dc.html": "design",
  "Dev Environment.dc.html": "dev-environment",
  "Grok Bot.dc.html": "grok-bot",
  "Herdr.dc.html": "herdr",
  "Lifecycle.dc.html": "lifecycle",
  "Projects.dc.html": "projects",
  "Skills.dc.html": "skills",
  "Supervision.dc.html": "supervision",
  "Testing.dc.html": "testing",
  "Upstream Review.dc.html": "upstream-review",
  "Usability System.dc.html": "usability",
  "Vs Firstmate.dc.html": "vs-firstmate",
  "404.dc.html": "404",
});

export const DOCS_NAV = Object.freeze([
  {
    heading: "Getting started",
    items: [
      { slug: "quick-start", label: "Quick start" },
      { slug: "projects", label: "Projects" },
      { slug: "dev-environment", label: "Dev environment" },
    ],
  },
  {
    heading: "Docs",
    items: [
      { slug: "architecture", label: "Architecture" },
      { slug: "supervision", label: "Supervision protocol" },
      { slug: "lifecycle", label: "Lifecycle & telemetry" },
      { slug: "configuration", label: "Configuration" },
      { slug: "backup", label: "Backup & restore" },
      { slug: "herdr", label: "herdr" },
    ],
  },
  {
    heading: "Reference",
    items: [
      { slug: "skills", label: "Skills" },
      { slug: "cli", label: "CLI · bin/cs-*" },
      { slug: "testing", label: "Testing & CI" },
      { slug: "grok-bot", label: "Grok Bot pack" },
    ],
  },
  {
    heading: "Project",
    items: [
      { slug: "changelog", label: "Changelog" },
      { slug: "vs-firstmate", label: "vs Firstmate" },
      { slug: "upstream-review", label: "Upstream review" },
    ],
  },
]);

export const SITE_NAV = Object.freeze([
  {
    heading: "Site",
    items: [
      { slug: "design", label: "Design system" },
      { slug: "usability", label: "Usability system" },
    ],
  },
]);

export const PAGE_ORDER = Object.freeze([
  ...DOCS_NAV.flatMap((group) => group.items.map((item) => item.slug)),
  ...SITE_NAV.flatMap((group) => group.items.map((item) => item.slug)),
]);

export const USABILITY_TOC = Object.freeze([
  ["skip", "Skip link"],
  ["breadcrumb", "Breadcrumb"],
  ["tocspy", "TOC scroll-spy"],
  ["palette", "Command palette"],
  ["drawer", "Nav drawer"],
  ["shortcuts", "Shortcut sheet"],
  ["popover", "Popover"],
  ["tooltip", "Tooltip"],
  ["tabs", "Tabs"],
  ["inline-edit", "Inline text editor"],
  ["copy", "Copyable command"],
  ["harness", "Harness switch"],
  ["callouts", "Callouts"],
  ["disclosure", "Disclosure"],
  ["confirm", "Two-step confirm"],
  ["stepper", "Run stepper"],
  ["evidence", "Evidence viewer"],
  ["logtail", "Live log tail"],
  ["skeleton", "Skeleton"],
  ["empty", "Empty state"],
  ["status", "Status chips"],
  ["toast", "Toast"],
  ["pager", "Pager"],
]);

const PAGES = [
  {
    slug: "quick-start",
    title: "Quick start",
    description:
      "Eight steps from a bare machine to a consigliere that knows your projects. It only detects gaps; it never installs anything behind your back.",
    topNav: "quick-start",
    sidebar: "docs",
  },
  {
    slug: "projects",
    title: "Projects",
    description:
      "Consigliere never works a repo it does not know about. A project is a registered clone with a standing delivery posture.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "dev-environment",
    title: "Dev environment",
    description:
      "A purely additive dev-tools suite: mise for tooling and tasks, aube where JS package-manager work needs it.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "architecture",
    title: "Architecture",
    description:
      "One boss, one consigliere, autonomous soldiers in isolated herdr worktrees, and a thin harness layer that speaks codex and claude natively.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "supervision",
    title: "Supervision protocol",
    description:
      "One protocol: the bounded foreground checkpoint. One backstop: the Stop hook. Soldiers work unattended; nothing lands without the boss.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "lifecycle",
    title: "Agent lifecycle & telemetry",
    description:
      "How a soldier is born, checked on, and retired, and the optional per-turn record that lets you replay a long session.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "configuration",
    title: "Configuration",
    description:
      "Three trees with three lifetimes: config/ travels with you, host/ belongs to the machine, and data/ state/ projects/ can be thrown away.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "backup",
    title: "Backup & restore",
    description:
      "No tool required. One directory is yours to keep; one is the machine's; the rest can be regenerated.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "herdr",
    title: "herdr",
    description:
      "The one terminal runtime. Soldiers live in its workspaces; the session refuses to dispatch without it.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "skills",
    title: "Skills",
    description:
      "Agent-loaded procedures in skills/. The consigliere reads the one it needs when the situation calls for it.",
    topNav: "skills",
    sidebar: "docs",
  },
  {
    slug: "cli",
    title: "CLI · bin/cs-*",
    description:
      "Every script is a cs-* file in bin/. Read its header before first use; the header is the contract.",
    topNav: "cli",
    sidebar: "docs",
  },
  {
    slug: "testing",
    title: "Testing & CI",
    description:
      "Every hosted check has a local twin. Every test belongs to exactly one lane. Lanes run only when a change can affect them.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "grok-bot",
    title: "Grok Bot pack",
    description:
      "A vendored, pinned port of grok-ship for the Grok Bot platform. Not one of consigliere's terminal harnesses.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "changelog",
    title: "Changelog",
    description:
      "Milestones on main. Wire this page to git tags or a CHANGELOG.md when one exists.",
    topNav: "changelog",
    sidebar: "docs",
  },
  {
    slug: "vs-firstmate",
    title: "Consigliere vs Firstmate",
    description:
      "A from-scratch personal rewrite, not a fork. Improvements upstream are ported editorially, never merged or cherry-picked.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "upstream-review",
    title: "Upstream review",
    description:
      "Firstmate keeps improving. Consigliere ports what is worth porting, editorially, and writes it down.",
    topNav: "docs",
    sidebar: "docs",
  },
  {
    slug: "design",
    title: "Design system",
    description:
      "Noir editorial. A serif for what the boss reads, a monospace for what the machine reads, one taupe accent, and hairlines instead of boxes.",
    topNav: "design",
    sidebar: "site",
    wide: true,
  },
  {
    slug: "usability",
    title: "Usability system",
    description:
      "The interaction vocabulary for this site and the ones that follow it. Escape always closes, focus is always visible, nothing moves unless the boss asked it to.",
    topNav: "design",
    sidebar: "site",
    wide: true,
    toc: USABILITY_TOC.map(([id, title]) => ({ id, title })),
  },
];

export const DOCS_PAGES = Object.freeze(PAGES);

export function pageBySlug(slug) {
  return DOCS_PAGES.find((page) => page.slug === slug);
}

export function navLabel(slug) {
  for (const group of [...DOCS_NAV, ...SITE_NAV]) {
    const item = group.items.find((entry) => entry.slug === slug);
    if (item) return item.label;
  }
  return slug;
}
