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
      minify: true,
      sourcemap: false,
      // El runtime nodejs20.x ya incluye @aws-sdk v3: marcarlo externo evita
      // bundlear ~3 MB por handler y reduce cold-start.
      external: ["@aws-sdk/*"],
    }).then(() => console.log(`built ${name}`))
  )
);

console.log(`\nBundled ${entries.length} handlers.`);
