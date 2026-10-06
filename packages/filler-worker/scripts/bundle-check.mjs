// Bundle check: build the worker exactly as `wrangler deploy` would (dry run),
// then fail if the bundle pulls in protobufjs (directly or transitively) or
// contains a runtime code generator (`new Function` / `eval(`), which Workers
// refuse at runtime.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const out = mkdtempSync(join(tmpdir(), "filler-worker-bundle-"));
try {
  execFileSync("npx", ["wrangler", "deploy", "--dry-run", "--outdir", out], { stdio: ["ignore", "ignore", "inherit"] });
  const code = readFileSync(join(out, "index.js"), "utf8");
  const map = JSON.parse(readFileSync(join(out, "index.js.map"), "utf8"));
  const problems = [];
  const sources = map.sources ?? [];
  for (const s of sources) if (/protobufjs|@protobufjs|node:fs|beta-filler\/src\/(bin|fileStore)\.ts/.test(s)) problems.push(`bundled module: ${s}`);
  // `new Function(…)`, `Function(…)`, `Function.apply(…)` (protobufjs' codegen form).
  const gen = code.match(/\bnew\s+Function\b|\bFunction\s*\.\s*(?:apply|call)\s*\(|(?:^|[^.\w$])Function\s*\(/m);
  if (gen) problems.push(`bundle contains a runtime code generator: ${gen[0].trim()}`);
  if (/(^|[^.\w])eval\s*\(/.test(code)) problems.push("bundle contains `eval(`");
  console.log(`bundle: ${(code.length / 1024).toFixed(0)} KiB, ${sources.length} source modules`);
  if (problems.length) {
    for (const p of problems) console.error(`✗ ${p}`);
    process.exit(1);
  }
  console.log("✓ no protobufjs, no node:fs / CLI modules, no new Function / eval");
} finally {
  rmSync(out, { recursive: true, force: true });
}
