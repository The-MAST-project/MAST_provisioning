#!/usr/bin/env bash
#
# --- help-start ---  (everything to help-end is printed by --help; @SELF@ is
#                      substituted with the name the script was invoked as)
# @SELF@ -- populate a top folder with the MAST repos for a given role.
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
#   @SELF@ --top ~/mast --role unit
#   @SELF@ --top /opt/mast --role control --ssh
#   @SELF@ --top ~/mast --role all --update
#   @SELF@ --top ~/mast --role unit --direct-http   # network with no proxy
#
# Companion: tools/mast-clone.ps1 (same manifest, same layout, for Windows).
# --- help-end ---

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/mast-repos.tsv"
ORG="The-MAST-project"

# HTTPS is the default transport. SSH needs a key on the machine and reaches
# github.com on port 22, which is blocked on the Weizmann network -- working
# around that takes a per-user ~/.ssh/config tunnelling github.com to
# ssh.github.com:443 through bcproxy. A freshly provisioned unit has neither the
# key nor that config, so SSH-by-default made the common case the broken one.
# HTTPS needs no key and rides the proxy set up below. --ssh opts back in for
# dev boxes that do have keys.
TOP=""
ROLES=""
TRANSPORT="https"
UPDATE=0
DRY_RUN=0
DIRECT_HTTP=0
DEFAULT_PROXY="http://bcproxy.weizmann.ac.il:8080"
# Fleet-internal destinations must NOT be sent to the proxy; it cannot reach
# 10.23.x and the request dies there rather than going direct.
DEFAULT_NO_PROXY="localhost,127.0.0.1,10.23.0.0/16"
VENV=""      # always <top>/.venv; derived once TOP_ABS is known
UV=""
# Name of the uv executable on this platform. Under Git Bash/MSYS/Cygwin the
# shell is POSIX but the binary is a Windows .exe, and the difference matters in
# two places: what to look for inside the release archive, and what path to hand
# to 'uv venv' afterwards.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) UV_BIN="uv.exe" ;;
    *)                    UV_BIN="uv" ;;
esac
declare -A BRANCH_OVERRIDE=()

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[mast-clone] $*"; }
warn() { echo "[mast-clone] WARN: $*" >&2; }

# Convert a path for a consumer that is a WINDOWS program rather than this
# shell. Under Git Bash every path here is an MSYS one ('/c/Users/...'), which
# python.exe and VS Code cannot resolve -- and both fail silently: site.py
# skips a .pth line naming a directory that does not exist, and VS Code just
# falls back to some other interpreter. The result is 'common' mysteriously
# not importable and Pylance reporting every third-party import unresolved,
# with nothing logged anywhere.
#
# Apply this ONLY where a path is written into generated config. Everything
# else in this script is consumed by bash, git and uv, which all want the MSYS
# form -- converting globally would break those.
#
# cygpath -m, not -w: it yields 'C:/Users/...', which Windows accepts and which
# needs no backslash escaping when embedded in JSON. (The ps1 half uses
# backslashes and therefore has to double them; not a trap worth copying.)
# On Linux and macOS this is the identity function.
winpath() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) cygpath -m -- "$1" ;;
        *)                    printf '%s' "$1" ;;
    esac
}

usage() {
    # The header comment block doubles as the help text, so the two cannot
    # drift. Delimited by sentinels rather than a line range: the range version
    # ('3,28p') silently dropped the trailing 'Companion:' line the first time
    # a usage example was added above it, and nothing tests --help output.
    #
    # BASH_SOURCE[0], not $0: under 'source' $0 is the parent shell ('bash'),
    # and sed would read that binary instead of this script. basename gives the
    # name actually invoked, so a symlinked or renamed copy prints its own name
    # rather than a hardcoded 'mast-clone.sh'.
    local self
    self="$(basename -- "${BASH_SOURCE[0]}")"
    sed -n '/^# --- help-start/,/^# --- help-end/p' "${BASH_SOURCE[0]}" \
        | sed -e '/^# --- help-start/,+1d' -e '/^# --- help-end/d' \
              -e 's/^# \{0,1\}//' -e "s|@SELF@|${self}|g"
    cat <<'EOF'

Options:
  --top <dir>            Top folder to populate. Created if missing. Required.
  --role <r[,r...]>      One or more of: unit, control, spec, all. Required.
  --https                Clone over HTTPS (default). Needs no key; works on a
                         freshly provisioned unit.
  --ssh                  Clone over SSH. Needs a key, and on the Weizmann
                         network also an ~/.ssh/config tunnelling github.com
                         to ssh.github.com:443 (port 22 is blocked).
  --direct-http          Reach the internet directly, with no proxy. For
                         networks that do not go through the Weizmann bcproxy
                         (off-campus, home, open egress). Without it, HTTPS
                         goes via $https_proxy if exported, else bcproxy.
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
        --direct-http) DIRECT_HTTP=1; shift ;;
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

# Everything this script fetches is external: github.com for the clones and for
# the uv bootstrap download, PyPI for the venv. Direct egress from the Weizmann
# network TIMES OUT rather than being refused, so without a proxy the first
# clone hangs for a couple of minutes before failing -- a slow, confusing
# failure that looks like a hung script rather than a network policy.
#
# Environment variables, NOT 'git config http.proxy': one setting covers all
# three consumers (git, the curl that downloads uv, and uv itself), and nothing
# is left behind in a repo config or the user's ~/.gitconfig afterwards.
#
# Set regardless of --ssh/--https. Even when the clones go over SSH -- which
# ignores http_proxy -- the uv download and 'uv pip install' are still HTTPS and
# still need it.
#
# --direct-http is for networks with no proxy at all -- off-campus, home, or a
# site whose egress is open. Otherwise an already-exported https_proxy wins
# (point somewhere else without touching the script), and failing that the
# Weizmann bcproxy is used.
if [ "$DIRECT_HTTP" -eq 1 ]; then
    # Unset, do not merely skip. An https_proxy inherited from the caller's
    # environment (a profile, a CI job, an outer script) would otherwise still
    # be honoured by git, curl and uv, and --direct-http would quietly do
    # nothing -- on a network where that proxy is unreachable, that is a hang.
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    PROXY_DESC="direct (--direct-http)"
else
    PROXY="${https_proxy:-${HTTPS_PROXY:-$DEFAULT_PROXY}}"
    export http_proxy="$PROXY"  https_proxy="$PROXY"
    export HTTP_PROXY="$PROXY"  HTTPS_PROXY="$PROXY"
    # Keep an operator-supplied no_proxy if there is one; otherwise exempt the
    # fleet-internal ranges, which the proxy cannot reach.
    export no_proxy="${no_proxy:-$DEFAULT_NO_PROXY}"
    export NO_PROXY="$no_proxy"
    PROXY_DESC="$PROXY"
fi

# The manifest does not always arrive LF-only: git checks it out with CRLF
# wherever core.autocrlf is on (any Windows clone), and a Windows editor can
# save it that way regardless. bash's 'read' does not strip the CR, so it lands
# in the LAST field of every row -- 'branch' becomes "master<CR>" and every
# 'git clone --branch' then fails with "Remote branch not found". Which field
# gets hit depends on the column count, so fixing it per-variable is a trap:
# normalize ONCE here and have every parser below read this text instead of
# re-opening the file. (The ps1 half is immune -- Get-Content drops the line
# terminator and each field goes through .Trim().)
MANIFEST_TEXT="$(tr -d '\r' < "$MANIFEST")"

# Pinned tool versions come from the manifest too, as '#!<key>\t<value>' lines,
# so the sh and ps1 halves cannot drift. They start with '#', so the repo-row
# parser below skips them.
UV_VERSION="$(awk -F'\t' '/^#!uv-version\t/ {print $2; exit}' <<< "$MANIFEST_TEXT" | tr -d '[:space:]')"

# Validate roles against the manifest so a typo fails loudly instead of
# silently cloning nothing.
KNOWN_ROLES="$(awk -F'\t' '!/^#/ && NF>=3 {print $3}' <<< "$MANIFEST_TEXT" \
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
info "proxy     : $PROXY_DESC"
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
done <<< "$MANIFEST_TEXT"

# --- disarm the vestigial 'common' submodule ------------------------------
#
# control, gui, spec and unit still declare MAST_common as a submodule, so each
# clone carries a committed gitlink and an empty <repo>/common (or
# <repo>/src/common) mount point. It is inert here -- <top>/common has an
# __init__.py and so is a regular package, which beats an empty directory
# (a mere namespace portion) wherever it appears on sys.path, verified with
# <top>/<repo> deliberately first.
#
# The real hazard is someone running 'git submodule update --init' in one of
# these clones: that materialises a SECOND common, stale the moment <top>/common
# moves, and then which one wins depends on how the process was started.
# 'update = none' makes --init skip it ("Skipping submodule 'common'").
# Note submodule.<name>.active = false is NOT enough -- --init overrides it.
#
# This is local config only, so the working tree stays clean and --update keeps
# working. Removing the gitlink instead would leave every clone permanently
# dirty. Retiring the submodules properly is a separate change in each repo.
if [ "$DRY_RUN" -eq 0 ]; then
    for d in "${CLONED[@]}"; do
        [ "$d" = "common" ] && continue
        if [ -f "${TOP_ABS}/${d}/.gitmodules" ] &&
           grep -q 'submodule "common"' "${TOP_ABS}/${d}/.gitmodules" 2>/dev/null; then
            git -C "${TOP_ABS}/${d}" config --local submodule.common.update none
            info "${d}: pinned submodule.common.update=none (vestigial submodule left unpopulated)"
        fi
    done
fi

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
    local ver="$1" dest="$2" asset url tmpd sum_expected sum_actual found
    case "$(uname -s)" in
        Linux)  asset="uv-x86_64-unknown-linux-gnu.tar.gz" ;;
        Darwin) asset="uv-aarch64-apple-darwin.tar.gz" ;;
        # Git Bash / MSYS2 / Cygwin: a POSIX shell on a WINDOWS platform, so the
        # right artifact is the .zip holding uv.exe, not a linux tarball. This
        # arm is what lets the script finish on a unit -- uname -s there is
        # 'MINGW64_NT-10.0-19044', which fell through to the die below and
        # stopped the run right after the clones, with no venv. --dry-run does
        # not catch it: that path prints "would bootstrap" without ever calling
        # this function.
        MINGW*|MSYS*|CYGWIN*) asset="uv-x86_64-pc-windows-msvc.zip" ;;
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
    case "$asset" in
        *.zip)    command -v unzip >/dev/null 2>&1 || die "unzip is needed to unpack ${asset} but is not on PATH"
                  unzip -q -o "${tmpd}/${asset}" -d "$tmpd" || die "extract failed (unzip)" ;;
        *.tar.gz) tar -xzf "${tmpd}/${asset}" -C "$tmpd"    || die "extract failed (tar)" ;;
        *)        die "no extractor for ${asset}" ;;
    esac
    # Archive layout differs per platform (<name>/uv in the tarballs, uv.exe at
    # the root of the zip), so take the binary wherever it landed. No -perm test:
    # the zip carries no POSIX mode bits, so uv.exe arrives non-executable under
    # MSYS and a -u+x filter would silently match nothing; chmod below fixes it.
    found="$(find "$tmpd" -type f -name "$UV_BIN" | head -1)"
    [ -n "$found" ] || die "uv binary ('$UV_BIN') not found in ${asset}"
    cp "$found" "${dest}/${UV_BIN}" || die "could not install uv into ${dest}"
    chmod +x "${dest}/${UV_BIN}" 2>/dev/null || true
    rm -rf "$tmpd"
    [ -x "${dest}/${UV_BIN}" ] || die "uv not executable after bootstrap"
}

uv_version_of() {  # $1 = a uv binary; echoes its bare version ("0.11.33") or nothing
    "$1" --version 2>/dev/null | awk '{print $2}'
}

if [ -n "$VENV" ]; then
    # uv is acquired, never optional: the venv is always built, so a missing uv
    # would simply mean a broken run. If the PINNED version is not already
    # present we fetch it into <top>/.tools -- checksum-verified, never
    # "latest", never a remote script piped into a shell.
    #
    # The version is checked, not just the presence of a binary. The whole point
    # of pinning uv in the manifest is that the resolver is what decides which
    # dependency versions land in the venv, so accepting whatever uv happens to
    # be on PATH would let two machines provisioned from the same manifest
    # resolve differently -- exactly the drift the pin exists to prevent. A
    # developer box with its own newer uv is the normal case here, not an edge
    # one. The same check covers <top>/.tools/uv, which may be left over from a
    # run made before the manifest bumped the pin.
    UV=""
    for _cand in "$(command -v uv 2>/dev/null || true)" "${TOP_ABS}/.tools/${UV_BIN}"; do
        [ -n "$_cand" ] && [ -x "$_cand" ] || continue
        _cand_ver="$(uv_version_of "$_cand")"
        if [ "$_cand_ver" = "$UV_VERSION" ]; then
            UV="$_cand"
            info "uv        : $UV (${UV_VERSION}, pinned)"
            break
        fi
        info "uv        : ignoring $_cand (${_cand_ver:-unknown}), manifest pins ${UV_VERSION}"
    done
    if [ -z "$UV" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "       would bootstrap uv ${UV_VERSION} into ${TOP_ABS}/.tools"
        else
            bootstrap_uv "$UV_VERSION" "${TOP_ABS}/.tools"
        fi
        UV="${TOP_ABS}/.tools/${UV_BIN}"
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
        if [ -f "$req" ]; then
            REQ_ARGS+=(-r "$req")
            REQ_NAMES="${REQ_NAMES}${REQ_NAMES:+, }${d}"
        fi
        # requirements-dev.txt too: it is where the fleet pins ruff
        # (ruff==0.16.0 in every repo) and pytest. Formatter output differs
        # between ruff versions, so a missing or unpinned ruff quietly breaks
        # the "every repo formats identically" guarantee -- see the note at the
        # top of each repo's ruff.toml.
        dev="${TOP_ABS}/${d}/requirements-dev.txt"
        if [ -f "$dev" ]; then
            REQ_ARGS+=(-r "$dev")
            REQ_NAMES="${REQ_NAMES}${REQ_NAMES:+, }${d}(dev)"
        fi
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
        # winpath: this file is read by python.exe, not by this shell.
        pth_top="$(winpath "$TOP_ABS")"
        info "writing ${sp}/mast.pth -> ${pth_top}"
        if [ "$DRY_RUN" -eq 0 ]; then
            printf '%s\n' "$pth_top" > "${sp}/mast.pth"
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
# Name carries the role(s), so a machine that later gains a second top folder
# for a different role does not end up with two files called the same thing.
ROLE_SLUG="$(echo "${SELECTED# }" | tr " " "\n" | sort | tr "\n" "-" | sed "s/-$//")"
WS="${TOP_ABS}/mast-${ROLE_SLUG}.code-workspace"
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
        #
        # $VPY, not "$VENV/bin/python": the layout differs by platform and was
        # already resolved above. Hardcoding bin/ wrote an interpreter path that
        # does not exist on Windows. winpath because VS Code reads this file.
        printf '    "python.defaultInterpreterPath": "%s",\n' "$(winpath "$VPY")"
        # Relative to each folder root, i.e. <top>. This is what makes Pylance
        # resolve 'common' in every folder: mast.pth fixes runtime, but static
        # analysis does not reliably follow .pth files.
        printf '    "python.analysis.extraPaths": [".."],\n'
        # The Ruff extension ships its own ruff and uses it by default, which
        # would silently ignore the pinned ruff==0.16.0 installed above.
        printf '    "ruff.importStrategy": "fromEnvironment",\n'
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
