import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { llmsTxt, robotsTxt, sitemapXml } from "../src/lib/seo.mjs";

const publicDirectory = path.dirname(fileURLToPath(new URL("../public/robots.txt", import.meta.url)));
mkdirSync(publicDirectory, { recursive: true });
writeFileSync(path.join(publicDirectory, "robots.txt"), robotsTxt());
writeFileSync(path.join(publicDirectory, "sitemap.xml"), sitemapXml());
writeFileSync(path.join(publicDirectory, "llms.txt"), llmsTxt());
