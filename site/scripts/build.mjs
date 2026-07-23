import { access, copyFile, cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const client = join(dist, "client");
const server = join(dist, "server");

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

await rm(dist, { recursive: true, force: true });
await mkdir(client, { recursive: true });
await mkdir(server, { recursive: true });

for (const file of ["index.html", "privacy.html", "support.html", "legal.css", "legal.js", "robots.txt", "sitemap.xml"]) {
  const source = join(root, file);
  if (await exists(source)) {
    await copyFile(source, join(client, file));
  }
}
await cp(join(root, "assets"), join(client, "assets"), { recursive: true });

const worker = `export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const response = await env.ASSETS.fetch(request);
    if (response.status !== 404 || url.pathname.includes(".")) return response;
    return env.ASSETS.fetch(new Request(new URL("/index.html", request.url), request));
  }
};
`;
await writeFile(join(server, "index.js"), worker);

for (const file of ["index.html", "privacy.html", "support.html"]) {
  const html = await readFile(join(client, file), "utf8");
  if (!html.includes("<title>") || !html.includes("</html>")) {
    throw new Error(`${file} is not a complete HTML document`);
  }
}

console.log("Built TokenRemain website");
