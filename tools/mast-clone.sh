#!/usr/bin/env bash
#
# mast-clone.sh -- populate a top folder with the MAST repos for a given role.
#
# Creates a flat hierarchy under <top>:
#
#   <top>/
#     common/    MAST_common          (the 'common' Python package)
#     unit/      MAST_unit.2024-12-12
#     control/   MAST_control
#     gui/       MAST_gui
#     spec/      MAST_spec
#     claude/    mast-claude-config
#
# Which folders appear is driven by --role and the manifest mast-repos.tsv.
#
# WHY THE LAYOUT WORKS: MAST_common's repo root carries an __init__.py, so the
# repo root *is* the 'common' package. Cloning it into a folder literally named
# 'common' and putting <top> on sys.path makes every existing
# 'from common.X import ...' resolve unchanged -- no source edits, and no need
# for the submodule. The venv at <top>/.venv is how sys.path gets set at runtime.
#
# Usage:
#   mast-clone.sh --top ~/mast --role unit
#   mast-clone.sh --top /opt/mast --role control --https
#   mast-clone.sh --top ~/mast --role all --update
#
# Companion: tools/mast-clone.ps1 (same manifest, same layout, for Windows).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/mast-repos.tsv"
ORG="The-MAST-project"

TOP=""
ROLES=""
TRANSPORT="ssh"
UPDATE=0
DRY_RUN=0
VENV=""      # always <top>/.venv; derived once TOP_ABS is known
UV=""
declare -A BRANCH_OVERRIDE=()

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[mast-clone] $*"; }
warn() { echo "[mast-clone] WARN: $*" >&2; }

usage() {
    sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --top <dir>            Top folder to populate. Created if missing. Required.
  --role <r[,r...]>      One or more of: unit, control, spec, all. Required.
  --ssh                  Clone over SSH (default). Suits dev boxes with keys.
  --https                Clone over HTTPS. Suits provisioning-time on a unit.
  --branch <dir>=<ref>   Override the manifest branch for one folder, e.g.
                         --branch unit=acquisition_tuning. Repeatable.
                         Default comes from the manifest, NOT from the remote's
                         default HEAD -- see mast-repos.tsv for why that matters.
  --update               For folders that already exist, fast-forward them.
                         Without this, existing folders are only fetched.
  --dry-run              Print what would happen; change nothing.
  -h, --help             This help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --top)     TOP="${2:-}"; shift 2 ;;
        --role)    ROLES="${2:-}"; shift 2 ;;
        --ssh)     TRANSPORT="ssh"; shift ;;
        --https)   TRANSPORT="https"; shift ;;
        --update)  UPDATE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --branch)
            ov="${2:-}"
            case "$ov" in
                *=*) BRANCH_OVERRIDE["${ov%%=*}"]="${ov#*=}" ;;
                *)   die "--branch expects <dir>=<ref>, got '$ov'" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument '$1' (try --help)" ;;
    esac
done

[ -n "$TOP" ]   || { usage >&2; die "--top is required"; }
[ -n "$ROLES" ] || { usage >&2; die "--role is required"; }
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
command -v git >/dev/null 2>&1 || die "git is not on PATH"

# Never let git stop to ask for credentials. Provisioning runs unattended (WinRM
# task, SSH session, cron), where there is no terminal to prompt on: git would
# try to open /dev/tty, fail, and only then report a confusing
# "could not read Username" after a detour through the credential helper.
# With this set, a missing credential fails immediately and says so.
export GIT_TERMINAL_PROMPT=0

# Pinned tool versions come from the manifest too, as '#!<key>\t<value>' lines,
# so the sh and ps1 halves cannot drift. They start with '#', so the repo-row
# parser below skips them.
UV_VERSION="$(awk -F'\t' '/^#!uv-version\t/ {print $2; exit}' "$MANIFEST" | tr -d '[:space:]')"

# Validate roles against the manifest so a typo fails loudly instead of
# silently cloning nothing.
KNOWN_ROLES="$(awk -F'\t' '!/^#/ && NF>=3 {print $3}' "$MANIFEST" \
               | tr ',' '\n' | sort -u | tr '\n' ' ')"
SELECTED=""
IFS=',' read -r -a _roles <<< "$ROLES"
for r in "${_roles[@]}"; do
    r="$(echo "$r" | tr -d '[:space:]')"
    [ -n "$r" ] || continue
    if [ "$r" != "all" ] && ! echo " $KNOWN_ROLES " | grep -q " $r "; then
        die "unknown role '$r'; known roles: all ${KNOWN_ROLES}"
    fi
    SELECTED="${SELECTED} ${r}"
done

wants_repo() {  # $1 = comma-separated roles for this manifest row
    local row_roles="$1" r
    for r in $SELECTED; do
        [ "$r" = "all" ] && return 0
        case ",${row_roles}," in *",${r},"*) return 0 ;; esac
    done
    return 1
}

repo_url() {  # $1 = repo name
    if [ "$TRANSPORT" = "ssh" ]; then
        echo "git@github.com:${ORG}/$1.git"
    else
        echo "https://github.com/${ORG}/$1.git"
    fi
}

run() {  # echo-and-execute, honouring --dry-run
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "       would run: $*"
        return 0
    fi
    "$@"
}

info "top       : $TOP"
info "roles     : ${SELECTED# }"
info "transport : $TRANSPORT"
[ "$DRY_RUN" -eq 1 ] && info "DRY RUN -- nothing will be modified"

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$TOP"
fi
TOP_ABS="$(cd -- "$TOP" 2>/dev/null && pwd || echo "$TOP")"

VENV="${TOP_ABS}/.venv"

CLONED=()
while IFS=$'\t' read -r dir repo roles manifest_branch; do
    case "$dir" in ''|\#*) continue ;; esac
    [ -n "${roles:-}" ] || continue
    wants_repo "$roles" || continue

    dest="${TOP_ABS}/${dir}"
    url="$(repo_url "$repo")"
    # Manifest branch is the default; --branch overrides it. Never fall back to
    # the remote default HEAD -- for common and control that is an abandoned
    # 2-commit stub (see mast-repos.tsv).
    branch="${BRANCH_OVERRIDE[$dir]:-${manifest_branch:-}}"
    [ -n "$branch" ] || die "$dir: no branch in manifest and no --branch override"
    CLONED+=("$dir")

    if [ -d "$dest/.git" ]; then
        # Idempotent re-run. Never merge implicitly -- local work is sacred.
        actual="$(git -C "$dest" remote get-url origin 2>/dev/null || echo '')"
        case "$actual" in
            *"${repo}"*) : ;;
            *) warn "$dir: origin is '$actual', expected a ${repo} remote -- skipping" ; continue ;;
        esac
        info "$dir: exists, fetching"
        run git -C "$dest" fetch --prune origin
        if [ "$UPDATE" -eq 1 ]; then
            if [ "$DRY_RUN" -eq 0 ] && [ -n "$(git -C "$dest" status --porcelain)" ]; then
                warn "$dir: working tree dirty -- not fast-forwarding"
            else
                info "$dir: fast-forwarding"
                run git -C "$dest" merge --ff-only @{u} || warn "$dir: not a fast-forward, left alone"
            fi
        fi
    elif [ -e "$dest" ]; then
        warn "$dir: '$dest' exists but is not a git clone -- skipping"
        continue
    else
        info "$dir: cloning $repo (branch $branch)"
        run git clone --branch "$branch" "$url" "$dest"
    fi
done < "$MANIFEST"

# --- sanity check: the file the whole scheme rests on ---------------------
#
# MAST_common's root __init__.py is what makes 'common' an importable package.
# If it is missing, the clone landed on the wrong branch (the 2-commit 'main'
# stub) and every 'from common.X import ...' in the fleet will fail. Catch it
# here, at provisioning time, instead of at service start on a dark unit.
if [ "$DRY_RUN" -eq 0 ] && [ -d "${TOP_ABS}/common" ] && [ ! -f "${TOP_ABS}/common/__init__.py" ]; then
    die "common/__init__.py is missing -- 'common' is not an importable package.
       The clone almost certainly landed on the wrong branch.
       On branch: $(git -C "${TOP_ABS}/common" rev-parse --abbrev-ref HEAD 2>/dev/null)
       Expected the branch pinned in $(basename "$MANIFEST")."
fi

# --- venv creation and population ------------------------------------------
#
# uv does both jobs: 'uv venv' creates, 'uv pip install' populates. It is
# required rather than optional -- falling back to python -m venv + pip would
# resolve a different dependency set than the one uv locks onto, so a fleet
# provisioned by two different paths would drift, which is the whole thing
# these scripts exist to prevent.
#
# Requirements are installed per cloned repo. MAST_common ships only
# requirements-dev.txt (no runtime deps of its own), so it contributes nothing
# here; unit/control/gui/spec each carry a pinned requirements.txt.
bootstrap_uv() {
    # Pinned + checksum-verified, deliberately NOT 'curl ... | sh':
    #   - the pipe executes whatever the URL serves at that moment, unreviewed;
    #   - it installs "latest", so machines provisioned weeks apart get
    #     different resolvers and the fleet drifts.
    # We fetch the release artifact GitHub hosts, verify it against the .sha256
    # published beside it, and unpack a single static binary.
    local ver="$1" dest="$2" asset url tmpd sum_expected sum_actual
    case "$(uname -s)" in
        Linux)  asset="uv-x86_64-unknown-linux-gnu.tar.gz" ;;
        Darwin) asset="uv-aarch64-apple-darwin.tar.gz" ;;
        *)      die "cannot bootstrap uv on this platform: $(uname -s); install uv yourself" ;;
    esac
    url="https://github.com/astral-sh/uv/releases/download/${ver}/${asset}"
    tmpd="$(mktemp -d)"
    info "bootstrapping uv ${ver} from ${url}"
    curl -fsSL --retry 3 -o "${tmpd}/${asset}"        "$url"        || die "download failed: $url"
    curl -fsSL --retry 3 -o "${tmpd}/${asset}.sha256" "${url}.sha256" || die "checksum download failed"
    sum_expected="$(awk '{print $1}' "${tmpd}/${asset}.sha256")"
    sum_actual="$(sha256sum "${tmpd}/${asset}" | awk '{print $1}')"
    if [ "$sum_expected" != "$sum_actual" ]; then
        rm -rf "$tmpd"
        die "uv checksum MISMATCH -- refusing to install.
       expected: ${sum_expected}
       actual:   ${sum_actual}"
    fi
    info "uv checksum verified (sha256 ${sum_actual})"
    mkdir -p "$dest"
    tar -xzf "${tmpd}/${asset}" -C "$tmpd" || die "extract failed"
    # Archive layout is <name>/uv; take the binary wherever it landed.
    find "$tmpd" -type f -name uv -perm -u+x -exec cp {} "${dest}/uv" \; || die "uv binary not found in archive"
    rm -rf "$tmpd"
    [ -x "${dest}/uv" ] || die "uv not executable after bootstrap"
}

if [ -n "$VENV" ]; then
    # uv is acquired, never optional: the venv is always built, so a missing uv
    # would simply mean a broken run. If it is not on PATH we fetch the pinned
    # version into <top>/.tools -- checksum-verified, never "latest", never a
    # remote script piped into a shell.
    if command -v uv >/dev/null 2>&1; then
        UV="$(command -v uv)"
    elif [ -x "${TOP_ABS}/.tools/uv" ]; then
        UV="${TOP_ABS}/.tools/uv"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "       would bootstrap uv ${UV_VERSION} into ${TOP_ABS}/.tools"
        UV="${TOP_ABS}/.tools/uv"
    else
        bootstrap_uv "$UV_VERSION" "${TOP_ABS}/.tools"
        UV="${TOP_ABS}/.tools/uv"
    fi
    if [ ! -d "$VENV" ]; then
        info "creating venv ${VENV}"
        if [ "$DRY_RUN" -eq 0 ]; then
            "$UV" venv --seed "$VENV" || die "uv venv failed"
        else
            echo "       would run: $UV venv --seed $VENV"
        fi
    else
        info "venv ${VENV} exists, reusing"
    fi

    # Interpreter path differs by platform: POSIX bin/, Windows Scripts/.
    VPY=""
    for cand in "$VENV/bin/python" "$VENV/Scripts/python.exe"; do
        [ -x "$cand" ] && VPY="$cand" && break
    done
    if [ "$DRY_RUN" -eq 1 ] && [ -z "$VPY" ]; then VPY="$VENV/bin/python"; fi
    [ -n "$VPY" ] || die "no interpreter under '$VENV' after creation"

    # ONE resolve, not one per repo. A compound role (control = control +
    # gui) puts several requirements files into a single venv, and those
    # files can pin the same package differently -- control and gui
    # currently disagree on astropy, httpx, pydantic, pymongo and rich.
    # Installing them one after another would silently let the last file
    # win, leaving a service running versions it was never tested against.
    # Passing every -r in one invocation makes uv resolve them together and
    # fail loudly on a contradiction, which is the only safe outcome: repos
    # that share a machine must agree on shared pins.
    REQ_ARGS=()
    REQ_NAMES=""
    for d in "${CLONED[@]}"; do
        req="${TOP_ABS}/${d}/requirements.txt"
        # MAST_control shipped this as 'required.txt' until the rename;
        # accept the old name so a not-yet-updated clone still provisions.
        if [ ! -f "$req" ] && [ -f "${TOP_ABS}/${d}/required.txt" ]; then
            req="${TOP_ABS}/${d}/required.txt"
            warn "${d}: using legacy 'required.txt' -- rename it to requirements.txt"
        fi
        [ -f "$req" ] || continue
        REQ_ARGS+=(-r "$req")
        REQ_NAMES="${REQ_NAMES}${REQ_NAMES:+, }${d}"
    done
    if [ ${#REQ_ARGS[@]} -eq 0 ]; then
        info "no requirements files among the cloned repos"
    else
        info "installing requirements from: ${REQ_NAMES}"
        if [ "$DRY_RUN" -eq 0 ]; then
            "$UV" pip install --python "$VPY" "${REQ_ARGS[@]}" \
                || die "uv pip install failed.
   If it reports conflicting versions, two repos sharing this machine pin
   the same package differently; reconcile the requirements files rather
   than installing them separately."
        else
            echo "       would run: $UV pip install --python $VPY ${REQ_ARGS[*]}"
        fi
    fi
fi

# --- sys.path wiring ------------------------------------------------------
#
# A .pth in the venv beats exporting PYTHONPATH: it survives into systemd
# units and any IDE/pytest runner using that interpreter, none of which
# inherit a login shell's environment.
if [ -n "$VENV" ]; then
    sp=""
    for cand in "$VENV"/lib/python*/site-packages "$VENV"/Lib/site-packages; do
        [ -d "$cand" ] && sp="$cand" && break
    done
    if [ -z "$sp" ]; then
        warn "no site-packages under '$VENV' -- skipping mast.pth"
    else
        info "writing ${sp}/mast.pth -> ${TOP_ABS}"
        if [ "$DRY_RUN" -eq 0 ]; then
            printf '%s\n' "$TOP_ABS" > "${sp}/mast.pth"
        fi
    fi
fi

# --- VS Code multi-root workspace -----------------------------------------
#
# Opening <top> as a plain folder makes VS Code read only <top>/.vscode, so the
# per-repo .vscode directories (control, spec, gui and unit each ship one) are
# ignored. A multi-root workspace is the one arrangement where every repo keeps
# its own folder-scoped settings.json and its launch.json entries, with no
# copying or merging: the repos stay the source of truth.
#
# Written only when absent -- people customise these, and silently clobbering a
# hand-edited workspace on every --update would be its own bug.
WS="${TOP_ABS}/mast.code-workspace"
if [ -e "$WS" ]; then
    info "$(basename "$WS") exists, leaving it alone"
elif [ "$DRY_RUN" -eq 1 ]; then
    echo "       would write ${WS}"
else
    info "writing ${WS}"
    {
        printf '{\n  "folders": [\n'
        n=${#CLONED[@]}; i=0
        for d in "${CLONED[@]}"; do
            i=$((i+1))
            if [ "$i" -lt "$n" ]; then printf '    { "path": "%s" },\n' "$d"
            else                       printf '    { "path": "%s" }\n'  "$d"; fi
        done
        printf '  ],\n  "settings": {\n'
        # Absolute, because <top>/.venv is a sibling of the folder roots rather
        # than inside one, so VS Code cannot auto-discover it. This file is
        # generated per machine, so a machine-specific path here is fine.
        printf '    "python.defaultInterpreterPath": "%s/bin/python",\n' "$VENV"
        # Relative to each folder root, i.e. <top>. This is what makes Pylance
        # resolve 'common' in every folder: mast.pth fixes runtime, but static
        # analysis does not reliably follow .pth files.
        printf '    "python.analysis.extraPaths": [".."],\n'
        printf '    "files.exclude": { ".venv": true, ".tools": true }\n'
        printf '  },\n'
        # Recommendations only prompt; they never install. Installing is
        # provisioning's job (code --install-extension), not this script's --
        # a unit may have no editor at all. Listed because the repos' own
        # settings depend on them: Pylance for the language server, ruff as the
        # configured formatter, debugpy for the "type": "debugpy" launch
        # configs, PowerShell for the one PS launch config.
        printf '  "extensions": {\n    "recommendations": [\n'
        printf '      "ms-python.python",\n'
        printf '      "ms-python.vscode-pylance",\n'
        printf '      "ms-python.debugpy",\n'
        printf '      "charliermarsh.ruff",\n'
        printf '      "ms-vscode.PowerShell"\n'
        printf '    ]\n  }\n}\n'
    } > "$WS"
fi

# --- shadowing guard ------------------------------------------------------
#
# With <top> on sys.path the sibling folders become importable top-level names,
# and three of them collide with real modules: spec/spec.py, unit/src/unit.py,
# control/control/. Python resolves these correctly ONLY because those repo
# roots have no __init__.py (a dir without one is a mere namespace portion, and
# a real module found anywhere on the path beats it). If someone ever adds an
# __init__.py to a consumer repo root, that repo silently shadows its own
# module. Fail loudly here rather than debugging it at 3am.
shadow_problems=0
for d in "${CLONED[@]}"; do
    [ "$d" = "common" ] && continue          # common's root __init__.py is required
    if [ -f "${TOP_ABS}/${d}/__init__.py" ]; then
        warn "${d}/__init__.py exists -- it will shadow '${d}' as a package and break imports"
        shadow_problems=1
    fi
done

echo
if [ "$shadow_problems" -eq 1 ]; then
    warn "shadowing problems detected (see above)"
fi
info "done. ${#CLONED[@]} folder(s) under ${TOP_ABS}"
