import { cp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const output = resolve(packageRoot, "dist");
const destination = resolve(packageRoot, "../../FloralMD/Vendor/Excalidraw");
const excalidrawPackage = resolve(packageRoot, "node_modules/@excalidraw/excalidraw");

// Excalidraw resolves its drawing fonts through EXCALIDRAW_ASSET_PATH at runtime,
// so Vite does not discover them as module assets. Keep the complete upstream
// font tree beside the generated chunks for fully offline drawing and SVG export.
await cp(resolve(excalidrawPackage, "dist/prod/fonts"), resolve(output, "fonts"), {
  recursive: true
});
await cp(
  resolve(packageRoot, "node_modules/react/LICENSE"),
  resolve(output, "React-LICENSE.txt")
);

async function normalizeGeneratedText(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      await normalizeGeneratedText(path);
    } else if (/\.(?:css|html|js|txt)$/.test(entry.name)) {
      const source = await readFile(path, "utf8");
      await writeFile(path, source.replace(/[\t ]+$/gm, ""));
    }
  }
}

// Upstream locale and diagram chunks contain trailing spaces in template
// literals. Normalizing generated text keeps repository whitespace checks
// useful without changing runtime semantics.
await normalizeGeneratedText(output);

for (const entry of await readdir(destination)) {
  if (entry === "Excalidraw-LICENSE.txt" || entry === "Excalidraw-VERSION.txt") continue;
  await rm(resolve(destination, entry), { recursive: true, force: true });
}
await cp(output, destination, { recursive: true });
