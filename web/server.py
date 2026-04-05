#!/usr/bin/env python3
"""SPQR Agent Manager — local web dashboard for Claude agent workspaces."""

import json
import os
import re
import subprocess
import threading
import time
import uuid
from pathlib import Path

from flask import Flask, Response, jsonify, render_template, request, stream_with_context

app = Flask(__name__)

# ── Job Registry ──────────────────────────────────────────────────
# In-memory map of job_id -> {output, status, returncode}
jobs: dict = {}
jobs_lock = threading.Lock()

# Resolve paths relative to this file
_HERE = Path(__file__).parent
_BIN = _HERE.parent / "bin"
_LIB = _HERE.parent / "lib" / "spqr.sh"


def _script(name: str) -> str:
    """Resolve a SPQR script, preferring dotfiles/bin/ over PATH."""
    local = _BIN / name
    return str(local) if local.exists() else name


_ANSI = re.compile(r"\x1b\[[0-9;]*[mGKHFABCDJrs]")


def _strip_ansi(s: str) -> str:
    return _ANSI.sub("", s)


def spawn_job(cmd: list[str]) -> str:
    """Spawn a subprocess and return a job_id for SSE streaming."""
    job_id = uuid.uuid4().hex
    env = {**os.environ, "TERM": "dumb", "NO_COLOR": "1"}
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )
    except FileNotFoundError as exc:
        with jobs_lock:
            jobs[job_id] = {"output": [f"Error: {exc}\n"], "status": "failed", "returncode": 127}
        return job_id

    with jobs_lock:
        jobs[job_id] = {"proc": proc, "output": [], "status": "running", "returncode": None}

    def _capture() -> None:
        try:
            for raw in proc.stdout:
                line = _strip_ansi(raw)
                with jobs_lock:
                    jobs[job_id]["output"].append(line)
            proc.wait()
            with jobs_lock:
                jobs[job_id]["status"] = "done" if proc.returncode == 0 else "failed"
                jobs[job_id]["returncode"] = proc.returncode
        except Exception as exc:  # noqa: BLE001
            with jobs_lock:
                jobs[job_id]["status"] = "failed"
                jobs[job_id]["output"].append(f"Capture error: {exc}\n")

    threading.Thread(target=_capture, daemon=True).start()
    return job_id


# ── Page Routes ───────────────────────────────────────────────────


@app.route("/")
def legions():
    return render_template("legions.html")


@app.route("/senatus")
def senatus():
    has_linear = bool(os.environ.get("LINEAR_API_KEY"))
    return render_template("senatus.html", has_linear=has_linear)


@app.route("/censor")
def censor():
    return render_template("censor.html")


@app.route("/templates")
def templates():
    return render_template("templates.html")


# ── API: Workspaces ───────────────────────────────────────────────


def _slugify(s: str) -> str:
    s = _ANSI.sub("", s)
    s = re.sub(r"[^a-zA-Z0-9_-]", "-", s)
    return re.sub(r"-+", "-", s).strip("-").lower()


@app.route("/api/workspaces")
def api_workspaces():
    try:
        r = subprocess.run(
            ["docker", "ps", "--filter", "name=spqr-", "--format", "{{json .}}"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        workspaces = []
        for line in r.stdout.strip().splitlines():
            if not line.strip():
                continue
            try:
                c = json.loads(line)
            except json.JSONDecodeError:
                continue
            name = c.get("Names", "")
            branch = name.removeprefix("spqr-")
            # Skip infra containers
            if branch in ("postgres", "caddy"):
                continue
            slug = _slugify(branch)
            workspaces.append(
                {
                    "id": c.get("ID", ""),
                    "name": name,
                    "branch": branch,
                    "is_review": branch.startswith("review-"),
                    "status": c.get("Status", ""),
                    "created": c.get("CreatedAt", ""),
                    "preview_url": f"http://{slug}.localhost:4000",
                }
            )
        return jsonify(workspaces)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": str(exc)}), 500


# ── API: Linear Issues ────────────────────────────────────────────


def _parse_tsv_issues(raw: str) -> list[dict]:
    issues = []
    for line in raw.strip().splitlines():
        line = _strip_ansi(line)
        parts = line.split("\t")
        if len(parts) >= 3 and parts[0].strip():
            issues.append(
                {"id": parts[0].strip(), "state": parts[1].strip(), "title": parts[2].strip()}
            )
    return issues


@app.route("/api/issues")
def api_issues():
    if not os.environ.get("LINEAR_API_KEY"):
        return jsonify([])
    try:
        r = subprocess.run(
            ["zsh", str(_LIB), "--fn", "spqr_linear_my_issues"],
            capture_output=True,
            text=True,
            timeout=20,
        )
        return jsonify(_parse_tsv_issues(r.stdout))
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": str(exc)}), 500


@app.route("/api/issues/search")
def api_issues_search():
    q = request.args.get("q", "").strip()
    if not q or not os.environ.get("LINEAR_API_KEY"):
        return jsonify([])
    try:
        r = subprocess.run(
            ["zsh", str(_LIB), "--fn", "spqr_linear_search", q],
            capture_output=True,
            text=True,
            timeout=20,
        )
        return jsonify(_parse_tsv_issues(r.stdout))
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": str(exc)}), 500


# ── API: GitHub PRs ───────────────────────────────────────────────


@app.route("/api/prs")
def api_prs():
    try:
        r = subprocess.run(
            [
                "gh",
                "pr",
                "list",
                "--json",
                "number,title,author,additions,deletions,changedFiles,reviewRequests,headRefName,createdAt",
                "--limit",
                "50",
            ],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if r.returncode != 0:
            return jsonify({"error": r.stderr.strip() or "gh command failed"}), 500
        data = json.loads(r.stdout) if r.stdout.strip() else []
        return jsonify(data)
    except FileNotFoundError:
        return jsonify({"error": "gh CLI not found — install the GitHub CLI"}), 501
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": str(exc)}), 500


# ── API: DB Templates ─────────────────────────────────────────────


@app.route("/api/templates")
def api_templates_list():
    try:
        r = subprocess.run(
            [
                "docker",
                "exec",
                "spqr-postgres",
                "psql",
                "-U",
                "spqr",
                "-d",
                "postgres",
                "-t",
                "-c",
                "SELECT datname, pg_size_pretty(pg_database_size(datname)) "
                "FROM pg_database "
                "WHERE datistemplate = true AND datname LIKE 'spqrtpl_%' "
                "ORDER BY datname;",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        tpls = []
        for line in r.stdout.strip().splitlines():
            parts = [p.strip() for p in line.split("|")]
            if len(parts) >= 2 and parts[0]:
                full = parts[0]
                name = re.sub(r"^spqrtpl_", "", full)
                tpls.append({"name": name, "full_name": full, "size": parts[1]})
        return jsonify(tpls)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": str(exc)}), 500


# ── API: Action Endpoints ─────────────────────────────────────────


@app.route("/api/senatus", methods=["POST"])
def api_senatus():
    data = request.json or {}
    issue_id = data.get("issue_id", "").strip()
    name = data.get("name", "").strip()
    no_link_deps = bool(data.get("no_link_deps"))

    if not issue_id and not name:
        return jsonify({"error": "issue_id or name required"}), 400

    cmd = [_script("senatus")]
    if issue_id:
        cmd.append(issue_id)
    else:
        cmd += ["--name", name]
    if no_link_deps:
        cmd.append("--no-link-deps")

    return jsonify({"job_id": spawn_job(cmd)})


@app.route("/api/censor", methods=["POST"])
def api_censor():
    data = request.json or {}
    pr = str(data.get("pr_number", "")).strip()
    if not pr:
        return jsonify({"error": "pr_number required"}), 400
    cmd = [_script("censor"), pr]
    if data.get("depth"):
        cmd.append(f"--depth={data['depth']}")
    return jsonify({"job_id": spawn_job(cmd)})


@app.route("/api/proscribe", methods=["POST"])
def api_proscribe():
    data = request.json or {}
    branch = data.get("branch", "").strip()
    if not branch:
        return jsonify({"error": "branch required"}), 400
    cmd = [_script("proscribe"), branch]
    return jsonify({"job_id": spawn_job(cmd)})


@app.route("/api/templates", methods=["POST"])
def api_templates_create():
    data = request.json or {}
    name = data.get("name", "").strip()
    from_url = data.get("from_url", "").strip()
    if not name or not from_url:
        return jsonify({"error": "name and from_url required"}), 400
    cmd = [_script("spqr"), "template", "create", name, "--from", from_url]
    return jsonify({"job_id": spawn_job(cmd)})


@app.route("/api/templates/<name>", methods=["DELETE"])
def api_templates_drop(name: str):
    cmd = [_script("spqr"), "template", "drop", name]
    return jsonify({"job_id": spawn_job(cmd)})


# ── SSE Stream ────────────────────────────────────────────────────


@app.route("/api/stream/<job_id>")
def api_stream(job_id: str):
    def _generate():
        sent = 0
        while True:
            with jobs_lock:
                job = jobs.get(job_id)
            if not job:
                yield f"data: {json.dumps({'error': 'job not found'})}\n\n"
                return

            with jobs_lock:
                batch = job["output"][sent:]
                status = job["status"]

            for line in batch:
                yield f"data: {json.dumps({'line': line})}\n\n"
            sent += len(batch)

            if status != "running":
                yield f"data: {json.dumps({'done': True, 'status': status, 'returncode': job.get('returncode')})}\n\n"
                return

            time.sleep(0.1)

    return Response(
        stream_with_context(_generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/api/jobs/<job_id>")
def api_job_status(job_id: str):
    with jobs_lock:
        job = jobs.get(job_id)
    if not job:
        return jsonify({"error": "not found"}), 404
    return jsonify(
        {
            "status": job["status"],
            "output": "".join(job["output"]),
            "returncode": job.get("returncode"),
        }
    )


# ── Entry Point ───────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description="SPQR Agent Manager")
    p.add_argument("--port", type=int, default=7777)
    p.add_argument("--host", default="127.0.0.1")
    args = p.parse_args()

    print(f"\n  SPQR Agent Manager  \u25b8  http://{args.host}:{args.port}\n")
    app.run(host=args.host, port=args.port, debug=False, threaded=True)
