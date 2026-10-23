// The required check can't be satisfied by a skipped job (LIMIT-CLOUD2-3):
// ci.yml's `cloud` job, and every job, has no `if:`, and its runner always
// resolves (a self-hosted label when set, else a GitHub-hosted runner).
//   node scripts/check-ci-workflow.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const text = readFileSync(fileURLToPath(new URL("../.github/workflows/ci.yml", import.meta.url)), "utf8");
let failures = 0;
const fail = (m) => (failures++, console.log("FAIL", m));
if (!text.includes("\njobs:\n")) fail("no jobs: section");
const jobsText = text.slice(text.indexOf("\njobs:\n"));
const jobs = jobsText.split(/\n(?=  [A-Za-z0-9_-]+:\s*\n)/).slice(1);
if (!/\n  cloud:\s*\n/.test(jobsText)) fail("there is no `cloud` job");
for (const j of jobs) {
  const name = /^  ([A-Za-z0-9_-]+):/.exec(j)?.[1];
  if (/\n    if:/.test(j)) fail(`job ${name} has an if: and could be skipped`);
  const runs = /\n    runs-on: (.*)/.exec(j)?.[1] ?? "";
  if (!/\|\| 'ubuntu-[0-9.]+'|^ubuntu-|^\[?self-hosted/.test(runs.replace(/\$\{\{\s*|\s*\}\}/g, ""))) fail(`job ${name}'s runs-on (${runs}) may not resolve to a runner`);
}
console.log(failures ? `${failures} failed` : `ci workflow: ${jobs.length} job(s), none skippable`);
process.exit(failures ? 1 : 0);
