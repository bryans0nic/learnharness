// Deploy changelog, one JSON line per deploy in logs/changelog.jsonl (logs/ is gitignored, so each machine keeps its own):
//   { at: ISO time, from: sha, to: sha, changes: [{ title, body? }] }   newest change first
// Used by the deploy scripts:
//   node scripts/record-deploy.mjs record <oldSha> <newSha>   after a deploy succeeds
//   node scripts/record-deploy.mjs backfill [deploy.log]      fills in past deploys from the deploy log (safe to repeat)
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

export const CHANGELOG = "logs/changelog.jsonl";

export function changesBetween(from, to) {
  try {
    const out = execFileSync("git", ["log", "--no-merges", "--format=%s%x1f%b%x1e", `${from}..${to}`], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    return out.split("\x1e").map((c) => c.trim()).filter(Boolean).map((c) => {
      const [title, body = ""] = c.split("\x1f");
      return body.trim() ? { title, body: body.trim() } : { title };
    });
  } catch {
    return []; // a sha that's no longer in this checkout
  }
}

export function record(entry, file = CHANGELOG) {
  mkdirSync(dirname(file), { recursive: true });
  appendFileSync(file, JSON.stringify(entry) + "\n");
}

// "2026-10-05 12:00:00 deployed abc1234..def5678: subject" (Mac), or "deploying a..b: subject" followed by
// "deployed b and restarted ..." (Pi, Windows; a bare "deploying" with no such line is a failed build, so it's skipped).
export function backfill(logFile, file = CHANGELOG) {
  if (!existsSync(logFile)) return 0;
  const seen = new Set(existsSync(file) ? readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l).to) : []);
  const lines = readFileSync(logFile, "utf8").split("\n");
  let added = 0;
  lines.forEach((line, i) => {
    const m = line.match(/^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (deployed|deploying) (\w+)\.\.(\w+): (.*)$/);
    if (!m) return;
    const [, time, verb, from, to, subject] = m;
    if (verb === "deploying" && !lines.slice(i + 1).some((l) => l.includes(` deployed ${to.slice(0, 7)} and restarted`))) return;
    if ([...seen].some((s) => s.startsWith(to))) return;
    const changes = changesBetween(from, to);
    record({ at: new Date(time.replace(" ", "T")).toISOString(), from, to, changes: changes.length ? changes : [{ title: subject }] }, file);
    seen.add(to);
    added++;
  });
  return added;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd, a, b] = process.argv.slice(2);
  if (cmd === "record" && a && b) {
    const rev = (s) => execFileSync("git", ["rev-parse", s], { encoding: "utf8" }).trim();
    record({ at: new Date().toISOString(), from: rev(a), to: rev(b), changes: changesBetween(a, b) });
  } else if (cmd === "backfill") {
    console.log(`added ${backfill(a ?? "logs/deploy.log")} past deploys`);
  } else {
    console.error("usage: record-deploy.mjs record <old> <new> | backfill [deploy.log]");
    process.exit(2);
  }
}
