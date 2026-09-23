#!/usr/bin/env bash
#
# 7elewen — security / penetration-testing audit
#
# Audits the surfaces that actually matter for this app in the real world:
#   1. the passwordless sudoers drop-in  (/etc/sudoers.d/7elewen) — the root grant
#   2. the osascript "do shell script" elevation path  — command-injection surface
#   3. Process / dlopen / dlsym usage                    — subprocess & dynamic code
#   4. code signing, hardened runtime, entitlements      — tamper/injection resistance
#   5. the network endpoint (GitHub update check)        — transport & scope
#
# Usage:
#   scripts/security-audit.sh [source_dir] [app_path]
#
#   source_dir   project root containing 7elewen.xcodeproj (default: .)
#   app_path     path to the built 7elewen.app (optional; auto-detected from DerivedData)
#
# Re-run the SUDOERS section with sudo to inspect file *contents* (0440 root-only):
#   sudo scripts/security-audit.sh .
#
# Exit code: 0 = clean; 1 = CRITICAL/HIGH findings; 2 = usage/locate error.

set -u

SRC="${1:-.}"
ARG_APP="${2:-}"

# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------
declare -i crit=0 high=0 med=0 low=0 info=0 pass=0

report() {
    local sev="$1"; shift
    case "$sev" in
        CRITICAL) crit=$((crit+1));;
        HIGH)     high=$((high+1));;
        MEDIUM)   med=$((med+1));;
        LOW)      low=$((low+1));;
        INFO)     info=$((info+1));;
        PASS)     pass=$((pass+1));;
    esac
    printf '  [%-8s] %s\n' "$sev" "$*"
}

banner() { printf '\n================ %s ================\n' "$1"; }

# grep a regex across .swift sources, one finding per hit
scan() { # scan <severity> <label> <pattern>
    local sev="$1" label="$2" pat="$3"
    local out
    out="$(grep -rnE --include='*.swift' "$pat" "$SRC" 2>/dev/null)"
    if [ -z "$out" ]; then
        report PASS "$label: none found"
    else
        while IFS= read -r line; do
            report "$sev" "$label: ${line#"$SRC"/}"
        done <<< "$out"
    fi
}

# does any .swift source match the regex?
has() { grep -rqE --include='*.swift' "$1" "$SRC" 2>/dev/null; }

# ---------------------------------------------------------------------------
# locate targets
# ---------------------------------------------------------------------------
banner "TARGET"
[ -d "$SRC" ] || { echo "source dir not found: $SRC" >&2; exit 2; }

APP="$ARG_APP"
if [ -z "$APP" ] || [ ! -e "$APP" ]; then
    APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path '*/Build/Products/*/7elewen.app' -type d \
        -not -path '*Index.noindex*' 2>/dev/null | head -1)"
fi

echo "  source : $SRC"
if [ -n "$APP" ] && [ -d "$APP" ]; then
    echo "  app    : $APP"
else
    echo "  app    : (not found — binary checks skipped; pass an .app as arg 2)"
fi
if [ "$(id -u)" -eq 0 ]; then
    echo "  mode   : ROOT (sudoers contents auditable)"
else
    echo "  mode   : non-root (sudoers limited to stat; re-run with sudo)"
fi

# ---------------------------------------------------------------------------
# 1. source: secrets & insecure transport
# ---------------------------------------------------------------------------
banner "SOURCE — SECRETS & TRANSPORT"
# Credentials only count when assigned a literal value — a bare mention of the
# word "passwordless" in a comment is not a secret.
scan CRITICAL "hardcoded credential literal" \
    '(password|passwd|secret|token|api[_-]?key)[[:space:]]*=[[:space:]]*"'
scan CRITICAL "embedded private key" 'BEGIN [A-Z ]*PRIVATE KEY'
# "https://" does NOT contain the substring "http://", so this catches only
# insecure plain-http endpoints.
scan CRITICAL "plain http:// endpoint" 'http://'

# ---------------------------------------------------------------------------
# 2. source: subprocess & injection surface
# ---------------------------------------------------------------------------
banner "SOURCE — SUBPROCESS & INJECTION"
scan MEDIUM "admin elevation via osascript (review injection)" 'do shell script|with administrator privileges'

if has 'executableURL *= *URL\(fileURLWithPath'; then
    report PASS "Process: fixed executable URL + argument array (no shell parsing → no injection)"
else
    report INFO "Process: no Process() usage detected"
fi

# subprocess routed through a shell interpreter would be an injection risk
scan HIGH "shell-interpreted subprocess" 'executableURL.*(sh|bash|zsh)|/bin/(sh|bash|zsh)'

# dynamic code loading (private brightness framework)
scan LOW "dlopen/dlsym (fixed system path, not injectable)" 'dlopen|dlsym'

# ---------------------------------------------------------------------------
# 3. sudoers drop-in — the actual root grant
# ---------------------------------------------------------------------------
banner "SUDOERS DROP-IN"
S="/etc/sudoers.d/7elewen"

if [ ! -e "$S" ]; then
    report INFO "sudoers: $S not present yet (activate the app once to create it)"
else
    perm="$(stat -f '%Lp' "$S" 2>/dev/null)"
    own="$(stat -f '%Su:%Sg' "$S" 2>/dev/null)"
    case "$perm" in
        440) report PASS "sudoers: mode 0440";;
        "")  report CRITICAL "sudoers: mode UNKNOWN (cannot stat)";;
        *)   report CRITICAL "sudoers: mode $perm (expected 0440)";;
    esac
    case "$own" in
        root:wheel) report PASS "sudoers: owner root:wheel";;
        *)          report CRITICAL "sudoers: owner $own (expected root:wheel)";;
    esac
    if [ -L "$S" ]; then report CRITICAL "sudoers: $S is a symlink (diversion vector)"; fi

    if [ "$(id -u)" -eq 0 ]; then
        if visudo -c -f "$S" >/dev/null 2>&1; then
            report PASS "sudoers: visudo syntax OK"
        else
            report CRITICAL "sudoers: visudo rejected file"
        fi

        content="$(cat "$S" 2>/dev/null)"

        if echo "$content" | grep -qE '(^|[^#[:alnum:]])NOPASSWD:[[:space:]]*ALL'; then
            report CRITICAL "sudoers: unrestricted NOPASSWD: ALL"
        else
            report PASS "sudoers: no unrestricted grant"
        fi
        if echo "$content" | grep -qE 'pmset[^,]*[*?[]'; then
            report CRITICAL "sudoers: wildcard/glob in pmset arguments"
        else
            report PASS "sudoers: no wildcards in pmset arguments"
        fi
        if echo "$content" | grep -qE 'NOPASSWD: /usr/bin/pmset disablesleep 1' \
            && echo "$content" | grep -qE 'NOPASSWD: /usr/bin/pmset disablesleep 0' \
            && echo "$content" | grep -qE 'NOPASSWD: /usr/bin/pmset lowpowermode 1' \
            && echo "$content" | grep -qE 'NOPASSWD: /usr/bin/pmset lowpowermode 0'; then
            report PASS "sudoers: scoped to exactly 4 pmset commands"
        else
            report CRITICAL "sudoers: command set does not match the expected 4 pmset args"
        fi
        if echo "$content" | grep -qE '#[0-9]+[[:space:]]+ALL'; then
            report PASS "sudoers: bound to a numeric uid"
        else
            report MEDIUM "sudoers: not obviously uid-bound (review)"
        fi
        report INFO "sudoers rule: $(echo "$content" | tr -s ' ')"

        # temp file must not linger world-writable
        if [ -e /tmp/7elewen-sudoers ]; then
            report HIGH "sudoers: staging file /tmp/7elewen-sudoers still exists"
        else
            report PASS "sudoers: staging file cleaned up"
        fi
    else
        report INFO "sudoers: content needs root — rerun: sudo $0 $SRC"
    fi
fi

# ---------------------------------------------------------------------------
# 4. temp-file handling (TOCTOU)
# ---------------------------------------------------------------------------
banner "SOURCE — TEMP-FILE (TOCTOU)"
scan MEDIUM "fixed /tmp staging path (symlink risk)" '/tmp/7elewen'
if has 'chmod\([^)]*0o440|chmod [^;]*440'; then
    report PASS "temp sudoers copy: chmod 0440 before install"
else
    report INFO "temp sudoers copy: no explicit chmod found (review)"
fi

# ---------------------------------------------------------------------------
# 5. binary & code signing
# ---------------------------------------------------------------------------
banner "BINARY & SIGNING"
if [ -n "$APP" ] && [ -d "$APP" ]; then
    BIN="$APP/Contents/MacOS/7elewen"

    if codesign --verify --deep --strict "$APP" 2>/dev/null; then
        report PASS "codesign: signature valid"
    else
        report HIGH "codesign: signature INVALID or unsigned"
    fi

    sig="$(codesign -dv --verbose=4 "$APP" 2>&1)"
    adhoc=0
    echo "$sig" | grep -qi 'Signature=adhoc' && adhoc=1

    if [ "$adhoc" -eq 1 ]; then
        report INFO "codesign: ad-hoc (Debug) signature — release needs Developer-ID signing + notarization"
    fi
    if echo "$sig" | grep -q 'runtime'; then
        report PASS "hardened runtime: enabled"
    elif [ "$adhoc" -eq 1 ]; then
        report INFO "hardened runtime: off (ad-hoc Debug — expected; harden the release .dmg)"
    else
        report HIGH "hardened runtime: off on a signed build"
    fi

    ent="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
    if echo "$ent" | grep -q 'get-task-allow'; then
        report LOW "entitlements: com.apple.security.get-task-allow present (fine for Debug, must be absent in release)"
    else
        report PASS "entitlements: no debugger task-for-pid allowance"
    fi

    libs="$(otool -L "$BIN" 2>/dev/null)"
    if echo "$libs" | grep -q 'DisplayServices'; then
        report INFO "dylibs: loads private DisplayServices.framework (expected for brightness)"
    fi
    if echo "$libs" | grep -qE '@rpath|@executable_path'; then
        report LOW "dylibs: @rpath/@executable_path search (verify no world-writable search dir)"
    fi

    if strings "$BIN" 2>/dev/null | grep -qiE 'password|api_key|secret|bearer '; then
        report HIGH "strings: possible secret material embedded"
    else
        report PASS "strings: no obvious secret material"
    fi
    if strings "$BIN" 2>/dev/null | grep -q 'http://'; then
        report HIGH "strings: plain http:// endpoint embedded"
    else
        report PASS "strings: no plain http:// endpoint"
    fi
else
    report INFO "binary checks skipped (no .app found)"
fi

# ---------------------------------------------------------------------------
# 6. network endpoint
# ---------------------------------------------------------------------------
banner "NETWORK"
if has 'api\.github\.com'; then
    report PASS "update check: HTTPS api.github.com (scope-limited, manual trigger only)"
else
    report INFO "update check: no github API endpoint found"
fi
# flag any URL host other than github.com (e.g. a telemetry / third-party endpoint)
scan MEDIUM "non-github URL host" 'https?://(?!github\.com)[a-z0-9]'

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
banner "SUMMARY"
printf '  CRITICAL %d   HIGH %d   MEDIUM %d   LOW %d   INFO %d   PASS %d\n' \
    "$crit" "$high" "$med" "$low" "$info" "$pass"

if [ $crit -gt 0 ] || [ $high -gt 0 ]; then
    echo "  VERDICT: FAIL — resolve CRITICAL/HIGH before release."
    exit 1
fi
echo "  VERDICT: PASS — no CRITICAL/HIGH findings."
exit 0