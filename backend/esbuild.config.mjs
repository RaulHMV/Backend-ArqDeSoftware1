import { build } from "esbuild";
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const handlersDir = join(__dirname, "src", "handlers");

// Cada archivo en src/handlers/*.ts se bundlea a dist/<name>/index.js
const entries = readdirSync(handlersDir)
  .filter((f) => f.endsWith(".ts"))
  .map((f) => f.replace(/\.ts$/, ""));

await Promise.all(
  entries.map((name) =>
    build({
      entryPoints: [join(handlersDir, `${name}.ts`)],
      outfile: join(__dirname, "dist", name, "index.js"),
      bundle: true,
      platform: "node",
      target: "node20",
      format: "cjs",
      minify: false,
      sourcemap: false,
      // El runtime de Lambda nodejs20 trae el AWS SDK v3, pero lo bundleamos
      // para fijar versiones y evitar sorpresas.
      external: [],
    }).then(() => console.log(`built ${name}`))
  )
);

console.log(`\nBundled ${entries.length} handlers.`);
