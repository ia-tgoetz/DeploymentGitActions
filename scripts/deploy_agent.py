"""Claude DevOps Agent — troubleshoots Ignition Edge deployment failures.

Invoked from .github/workflows/deploy.yml when a deploy step fails. Runs a
tool-use loop against claude-sonnet-4-6, investigates the failure, and
appends lessons to scripts/memory.md.
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import anthropic

MODEL = "claude-sonnet-4-6"
MAX_ITERATIONS = 15
MAX_TOKENS = 4096

REPO_ROOT = Path(__file__).resolve().parent.parent
MEMORY_FILE = REPO_ROOT / "scripts" / "memory.md"

# --- File-read safety perimeter ---------------------------------------------

ALLOWED_ROOTS = [
    Path(os.environ.get("GITHUB_WORKSPACE", REPO_ROOT)).resolve(),
    Path("/var/log").resolve(),
]

DENIED_SUBSTRINGS = (
    ".env",
    ".runner",
    ".credentials",
    "id_rsa",
    "id_ed25519",
    "/.ssh/",
    "/etc/shadow",
    "/etc/passwd",
    "/root/",
    "secret",
    "_token",
    "private_key",
)


def _validate_file_path(file_path: str) -> tuple[bool, str]:
    """Return (allowed, error_message) for a tool-supplied path."""
    try:
        resolved = Path(file_path).resolve()
    except (OSError, ValueError) as e:
        return False, f"Path invalid: {e}"

    resolved_str = str(resolved).lower()
    for pattern in DENIED_SUBSTRINGS:
        if pattern in resolved_str:
            return False, f"Denied: matches blocked pattern '{pattern}'"

    for root in ALLOWED_ROOTS:
        try:
            resolved.relative_to(root)
            return True, ""
        except ValueError:
            continue

    return False, (
        f"Denied: path outside allowed roots "
        f"({[str(r) for r in ALLOWED_ROOTS]})"
    )


# --- Tool definitions --------------------------------------------------------

TOOLS = [
    {
        "name": "get_docker_logs",
        "description": (
            "Retrieve the last N lines of logs from a Docker container. "
            "Use this first when investigating Ignition gateway failures. "
            "If you don't know the container name, run 'docker ps -a' via "
            "another tool first — the gateway container name is derived from "
            "the IPC hostname."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "container_name": {
                    "type": "string",
                    "description": "Container name from 'docker ps'.",
                },
                "tail": {
                    "type": "integer",
                    "description": "Lines to return (1-500).",
                    "minimum": 1,
                    "maximum": 500,
                },
            },
            "required": ["container_name", "tail"],
        },
    },
    {
        "name": "check_disk_space",
        "description": "Run 'df -h' on the host to check disk usage.",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "read_local_file",
        "description": (
            "Read a file from the IPC's filesystem. RESTRICTED: only paths "
            "inside the repo working directory or /var/log/ are allowed. "
            "Files matching credential/secret patterns are blocked. "
            "Returns last 20000 chars to protect context."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "Absolute path under repo or /var/log/.",
                },
            },
            "required": ["file_path"],
        },
    },
    {
        "name": "record_lesson",
        "description": (
            "Append a troubleshooting rule or pipeline-optimization "
            "suggestion to the persistent memory file. Use sparingly — only "
            "for novel, generalizable insights not already in <memory>. The "
            "memory file is committed to a PUBLIC repo, so never include "
            "credentials, hostnames, IPs, or PII."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "lesson_type": {
                    "type": "string",
                    "enum": ["Troubleshooting Rule", "Optimization Strategy"],
                },
                "content": {
                    "type": "string",
                    "description": "Markdown-formatted lesson body.",
                },
            },
            "required": ["lesson_type", "content"],
        },
    },
]


# --- Tool execution ----------------------------------------------------------

def _exec_get_docker_logs(args: dict) -> str:
    container = args["container_name"]
    tail = max(1, min(500, int(args.get("tail", 50))))
    try:
        result = subprocess.run(
            ["docker", "logs", "--tail", str(tail), container],
            capture_output=True, text=True, timeout=30, check=True,
        )
        return (result.stdout or result.stderr) or "(no output)"
    except subprocess.CalledProcessError as e:
        return f"docker logs failed: {(e.stderr or '').strip() or e}"
    except subprocess.TimeoutExpired:
        return "Error: docker logs timed out after 30s"
    except FileNotFoundError:
        return "Error: docker CLI not found on PATH"


def _exec_check_disk_space(_: dict) -> str:
    try:
        result = subprocess.run(
            ["df", "-h"], capture_output=True, text=True, timeout=10, check=True,
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        return f"df failed: {(e.stderr or '').strip() or e}"


def _exec_read_local_file(args: dict) -> str:
    file_path = args["file_path"]
    allowed, err = _validate_file_path(file_path)
    if not allowed:
        return f"Refused: {err}"
    try:
        content = Path(file_path).read_text(errors="replace")
        return content[-20000:] if len(content) > 20000 else content
    except FileNotFoundError:
        return f"File not found: {file_path}"
    except PermissionError:
        return f"Permission denied: {file_path}"
    except Exception as e:
        return f"Read error: {e}"


def _exec_record_lesson(args: dict) -> str:
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    entry = (
        f"\n### {args['lesson_type']}: {timestamp}\n"
        f"{args['content']}\n"
        f"---\n"
    )
    MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    with MEMORY_FILE.open("a", encoding="utf-8") as f:
        f.write(entry)
    return f"Recorded {args['lesson_type']} to {MEMORY_FILE.name}."


TOOL_HANDLERS = {
    "get_docker_logs": _exec_get_docker_logs,
    "check_disk_space": _exec_check_disk_space,
    "read_local_file": _exec_read_local_file,
    "record_lesson": _exec_record_lesson,
}


def execute_tool(name: str, args: dict) -> str:
    handler = TOOL_HANDLERS.get(name)
    if handler is None:
        return f"Error: unknown tool '{name}'"
    try:
        return handler(args)
    except Exception as e:
        return f"Tool execution error in '{name}': {e}"


# --- Context loading ---------------------------------------------------------

def _load_text(path: str) -> str:
    try:
        return Path(path).read_text(errors="replace")
    except FileNotFoundError:
        return ""


def _load_memory() -> str:
    if MEMORY_FILE.exists():
        return MEMORY_FILE.read_text(errors="replace")
    return "(No lessons recorded yet.)"


def _load_failure_context() -> str:
    parts = []
    for label, path in [
        ("Health Check Logs", "health-check-log.txt"),
        ("Image Load Logs", "load-image-log.txt"),
    ]:
        content = _load_text(path)
        if content:
            parts.append(f"=== {label} ===\n{content.strip()}\n")
    return "\n".join(parts) if parts else "(No log files captured.)"


def _build_system_prompt(memory: str) -> str:
    return f"""You are a senior DevOps engineer responsible for an Ignition 8.3 Edge deployment pipeline running on field IPCs. A deployment just failed. You have tools to investigate the host, read logs, and record lessons to a persistent memory file.

Your job: diagnose the root cause concisely, then decide whether to record a generalizable lesson.

CRITICAL SECURITY RULES (non-negotiable):
- The `record_lesson` tool writes to a file COMMITTED TO A PUBLIC GITHUB REPO. Treat its content as public.
- NEVER include credentials, secrets, API keys, passwords, tokens, IPs, hostnames, paths under home directories, or PII in lesson content.
- NEVER attempt to read .env, .credentials, .runner, SSH keys, or any path matching credential patterns. The read_local_file tool will refuse — do not retry refused paths.

OPERATING RULES:
- Hard limit: {MAX_ITERATIONS} tool-use iterations. Be efficient — investigate, conclude, and stop.
- Lessons should capture novel, generalizable insights — not facts derivable from code or git history.
- Do NOT duplicate anything already in your <memory> context. Update or skip rather than re-add.
- If the failure has no general lesson (transient flake, environmental quirk), state your diagnosis and stop without recording.

<memory>
{memory}
</memory>"""


# --- Main loop ---------------------------------------------------------------

def main() -> int:
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY env var not set", file=sys.stderr)
        return 1

    client = anthropic.Anthropic(api_key=api_key)

    memory = _load_memory()
    failure_context = _load_failure_context()
    system_prompt = _build_system_prompt(memory)

    messages = [
        {
            "role": "user",
            "content": (
                "The deployment workflow failed. Here is what was captured "
                f"before you woke up:\n\n{failure_context}\n\n"
                "Investigate the root cause and decide whether a new lesson "
                "is warranted."
            ),
        }
    ]

    print(f"[agent] starting (model={MODEL}, max_iters={MAX_ITERATIONS})")

    for iteration in range(1, MAX_ITERATIONS + 1):
        try:
            response = client.messages.create(
                model=MODEL,
                max_tokens=MAX_TOKENS,
                # Cache the (large, stable) system prompt across iterations.
                # Memory + safety rules don't change within one invocation,
                # so each subsequent iteration reads the prefix from cache.
                system=[{
                    "type": "text",
                    "text": system_prompt,
                    "cache_control": {"type": "ephemeral"},
                }],
                tools=TOOLS,
                messages=messages,
            )
        except anthropic.APIError as e:
            print(f"[agent] API error iter={iteration}: {e}", file=sys.stderr)
            return 2

        usage = response.usage
        print(
            f"[agent] iter={iteration} stop={response.stop_reason} "
            f"in={usage.input_tokens} out={usage.output_tokens} "
            f"cache_read={usage.cache_read_input_tokens or 0}"
        )

        if response.stop_reason == "end_turn":
            for block in response.content:
                if block.type == "text":
                    print("\n[agent] FINAL ANALYSIS:\n" + block.text)
            return 0

        if response.stop_reason == "refusal":
            print("[agent] model refused to continue", file=sys.stderr)
            return 3

        if response.stop_reason != "tool_use":
            print(
                f"[agent] unexpected stop_reason: {response.stop_reason}",
                file=sys.stderr,
            )
            return 4

        # Append assistant turn (must include ALL blocks, not just tool_use)
        messages.append({"role": "assistant", "content": response.content})

        # Execute each tool_use block in this turn
        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                preview = json.dumps(block.input)[:120]
                print(f"[agent] tool_use: {block.name}({preview})")
                result = execute_tool(block.name, block.input)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": result,
                })

        messages.append({"role": "user", "content": tool_results})

    print(
        f"[agent] hit max iterations ({MAX_ITERATIONS}); stopping",
        file=sys.stderr,
    )
    return 5


if __name__ == "__main__":
    sys.exit(main())
