"""Time the BM3D smoke test on every nightly heavy leg (task #128).

Reads the logs of runs that already finished; starts nothing. Tests in one
file run one after another, so the BM3D test's time is its result line's
timestamp minus the previous test's (TTempSmooth). That includes a few
seconds of ffprobe and test overhead, and a timeout row is a floor (the job
was killed), not a time.

Usage: python3 bm3d_times.py [--runs N] [--repo OWNER/NAME]
Logs are cached in $BM3D_LOG_DIR (default: a temporary directory).
Needs an authenticated `gh`.
"""
import argparse, datetime, json, os, re, subprocess, tempfile

p = argparse.ArgumentParser()
p.add_argument("--runs", type=int, default=40)
p.add_argument("--repo")
a = p.parse_args()
repo = a.repo or json.loads(subprocess.check_output(
    ["gh", "repo", "view", "--json", "nameWithOwner"]))["nameWithOwner"]
out = os.environ.get("BM3D_LOG_DIR") or tempfile.mkdtemp(prefix="bm3d-logs-")
os.makedirs(out, exist_ok=True)

esc = re.compile(r"\x1b\[[0-9;]*m")
ts = lambda s: datetime.datetime.fromisoformat(s[:26])
runs = json.loads(subprocess.check_output(
    ["gh", "run", "list", "--repo", repo, "--workflow", "nightly.yml",
     "--limit", str(a.runs), "--json", "databaseId,createdAt"]))
for run in runs:
    jobs = json.loads(subprocess.check_output(
        ["gh", "run", "view", str(run["databaseId"]), "--repo", repo,
         "--json", "jobs"]))["jobs"]
    for j in jobs:
        if "heavy" not in j["name"] or j["conclusion"] in ("skipped", "cancelled", None):
            continue
        path = os.path.join(out, f"{j['databaseId']}.log")
        if not os.path.exists(path):
            r = subprocess.run(["gh", "api", "--allow-escape-sequences",
                                f"repos/{repo}/actions/jobs/{j['databaseId']}/logs"],
                               capture_output=True)
            open(path, "wb").write(r.stdout)
        prev = bm = None
        res = ""
        for line in open(path, errors="replace"):
            line = esc.sub("", line)
            if "integration_new_passes_test.dart: New pipeline passes" not in line:
                continue
            if "TTempSmooth runs end-to-end" in line:
                prev = ts(line)
            if "BM3D runs end-to-end" in line:
                bm = ts(line)
                res = "FAIL" if "❌" in line else "ok"
        d = f"{(bm - prev).total_seconds():6.0f}" if bm and prev else "     -"
        print(run["createdAt"][:10], run["databaseId"], f"{j['name']:<28}", d, res,
              flush=True)
