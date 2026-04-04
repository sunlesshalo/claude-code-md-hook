#!/bin/bash
# md-convert.sh — PreToolUse hook for Read tool
# 1. Intercepts reads of PDF/DOCX/XLSX/PPTX/HTML — converts to markdown, caches in .cache/
# 2. Intercepts reads of large .md files (>300 lines) — generates structural index, blocks full read

export HOOK_INPUT=$(cat)

# Find system Python, explicitly bypassing any active venv
find_system_python() {
    for py in \
        /opt/homebrew/bin/python3 \
        /usr/local/bin/python3 \
        /usr/bin/python3 \
        "$LOCALAPPDATA/Programs/Python/Python312/python.exe" \
        "$LOCALAPPDATA/Programs/Python/Python311/python.exe" \
        "python3" \
        "python"
    do
        if [ -x "$py" ] 2>/dev/null || command -v "$py" &>/dev/null; then
            # Make sure it's not a venv python
            venv_py=$("$py" -c "import sys; print(sys.prefix != sys.base_prefix)" 2>/dev/null)
            if [ "$venv_py" = "False" ]; then
                echo "$py"
                return
            fi
        fi
    done
    # Last resort: use whatever python3 is available even if in a venv
    command -v python3 || command -v python
}

export SYSTEM_PYTHON=$(find_system_python)

if [ -z "$SYSTEM_PYTHON" ]; then
    exit 0
fi

"$SYSTEM_PYTHON" - <<'EOF'
import sys, json, os, subprocess, shutil

SYSTEM_PYTHON = os.environ.get('SYSTEM_PYTHON', 'python3')
INDEX_THRESHOLD = 300
CONVERTIBLE = {'.pdf', '.docx', '.xlsx', '.pptx', '.html', '.htm'}

# --- Parse hook input ---
try:
    data = json.loads(os.environ.get('HOOK_INPUT', '{}'))
except Exception:
    sys.exit(0)

tool_input = data.get('tool_input', {})
file_path = tool_input.get('file_path', '')
if not file_path:
    sys.exit(0)

file_path = os.path.abspath(file_path)
if not os.path.isfile(file_path):
    sys.exit(0)

ext = os.path.splitext(file_path)[1].lower()

# --- Only act on convertible formats or markdown files ---
if ext not in CONVERTIBLE and ext not in ('.md', '.markdown'):
    sys.exit(0)

# --- Compute cache dir (always relative to the original file) ---
orig_dir  = os.path.dirname(file_path)
base_name = os.path.basename(file_path)
cache_dir  = os.path.join(orig_dir, '.cache')

# ---------------------------------------------------------------
# STEP 1: Convert if it's a non-markdown format
# ---------------------------------------------------------------
target_file = file_path  # will be overwritten if conversion happens
converted   = False

if ext in CONVERTIBLE:
    # Check for disable flag — skip conversion, pass through to native Read()
    if os.path.isfile('.claude/.noconvert'):
        sys.exit(0)

    cache_file = os.path.join(cache_dir, base_name + '.md')

    # Serve from cache if fresh
    if (os.path.isfile(cache_file) and
            os.path.getmtime(cache_file) > os.path.getmtime(file_path)):
        target_file = cache_file
        converted   = True
    else:
        # --- Locate markitdown CLI ---
        def find_markitdown():
            cmd = shutil.which('markitdown')
            if cmd:
                return cmd
            home = os.path.expanduser('~')
            candidates = [
                os.path.join(home, '.local', 'bin', 'markitdown'),
                os.path.join(home, '.local', 'pipx', 'venvs', 'markitdown', 'bin', 'markitdown'),
                os.path.join(home, 'AppData', 'Roaming', 'Python', 'Scripts', 'markitdown.exe'),
                os.path.join(home, 'AppData', 'Local', 'Programs', 'Python', 'Scripts', 'markitdown.exe'),
            ]
            for path in candidates:
                if os.path.isfile(path):
                    return path
            return None

        def markitdown_importable():
            try:
                result = subprocess.run(
                    [SYSTEM_PYTHON, '-c', 'from markitdown import MarkItDown'],
                    capture_output=True, timeout=10
                )
                return result.returncode == 0
            except Exception:
                return False

        markitdown_cmd = find_markitdown()

        # Auto-install if missing
        if not markitdown_cmd and not markitdown_importable():
            pipx = shutil.which('pipx')
            if pipx:
                try:
                    subprocess.run([pipx, 'install', 'markitdown[pdf]'], capture_output=True, timeout=90)
                except Exception:
                    pass
                markitdown_cmd = find_markitdown()

            if not markitdown_cmd:
                try:
                    subprocess.run(
                        [SYSTEM_PYTHON, '-m', 'pip', 'install', 'markitdown[pdf]', '--user', '--quiet'],
                        capture_output=True, timeout=90
                    )
                except Exception:
                    pass
                markitdown_cmd = find_markitdown()

        # Convert
        os.makedirs(cache_dir, exist_ok=True)
        try:
            if markitdown_cmd:
                result = subprocess.run(
                    [markitdown_cmd, file_path],
                    capture_output=True, text=True, timeout=120
                )
            elif markitdown_importable():
                result = subprocess.run(
                    [SYSTEM_PYTHON, '-c',
                     f'from markitdown import MarkItDown; md = MarkItDown(); r = md.convert("{file_path}"); print(r.text_content)'],
                    capture_output=True, text=True, timeout=120
                )
            else:
                sys.exit(0)

            if result.returncode == 0 and result.stdout.strip():
                with open(cache_file, 'w', encoding='utf-8') as f:
                    f.write(result.stdout)
                target_file = cache_file
                converted   = True
            else:
                sys.exit(0)
        except Exception:
            sys.exit(0)

# ---------------------------------------------------------------
# STEP 2: Check line count of target file
# ---------------------------------------------------------------
try:
    with open(target_file, 'r', encoding='utf-8', errors='replace') as f:
        line_count = sum(1 for _ in f)
except Exception:
    if converted:
        print(json.dumps({'updatedInput': {'file_path': target_file}}))
    sys.exit(0)

# Under threshold: pass through (redirect if converted)
if line_count <= INDEX_THRESHOLD:
    if converted:
        print(json.dumps({'updatedInput': {'file_path': target_file}}))
    sys.exit(0)

# Targeted read in progress (offset or limit provided): pass through
if tool_input.get('offset') is not None or tool_input.get('limit') is not None:
    if converted:
        print(json.dumps({'updatedInput': {'file_path': target_file}}))
    sys.exit(0)

# ---------------------------------------------------------------
# STEP 3: Generate or serve structural index
# ---------------------------------------------------------------
index_file = os.path.join(cache_dir, os.path.basename(target_file) + '.index.md')

if (os.path.isfile(index_file) and
        os.path.getmtime(index_file) > os.path.getmtime(target_file)):
    with open(index_file, 'r', encoding='utf-8') as f:
        index_content = f.read()
else:
    headings = []
    try:
        with open(target_file, 'r', encoding='utf-8', errors='replace') as f:
            for i, line in enumerate(f, 1):
                stripped = line.rstrip()
                if stripped.startswith('#'):
                    headings.append(f"L{i:<5} {stripped}")
    except Exception:
        pass

    if headings:
        index_content = '\n'.join(headings)
    else:
        index_content = f"(No markdown headings found — navigate by line number.)"

    os.makedirs(cache_dir, exist_ok=True)
    with open(index_file, 'w', encoding='utf-8') as f:
        f.write(index_content)

# Build block message
read_path = target_file  # always point Claude at the .md (converted or original)
converted_note = f"Cached markdown: {target_file}\n" if converted else ""
reason = (
    f"File too large for direct read ({line_count} lines).\n"
    f"{converted_note}"
    f"Structural index (headings → line numbers):\n\n"
    f"{index_content}\n\n"
    f"Use Read on '{read_path}' with offset and limit to fetch only the relevant section."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason
    }
}))
sys.exit(0)
EOF
