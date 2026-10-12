#!/bin/sh
set -eu

# Usage: ci_scripts/test-check-privacy-manifest.sh
#
# check-privacy-manifest.sh fails open on a typo. Misspell one pattern and the
# API it covers goes unmatched, its category goes unreported, and the gate
# still prints that every referenced category is declared — so the build stays
# green on the exact violation the gate exists to stop, and the next
# observation is an ITMS-91053 rejection at upload.
#
# The per-row cases are read out of the gate's own table rather than written
# here, so the set of rows covered cannot drift from the set of rows that
# exist. Each row supplies a sample call site in its third field; the case
# writes that sample into a tree declaring nothing and requires the gate to
# name that row's pattern and every category the row maps to. A pattern that
# no longer matches its own sample fails, and a row carrying no sample fails
# for want of one.
#
# Each case builds a throwaway tree with its own manifest and sources and runs
# the gate against it with an explicit root, so no case can see the repo's real
# manifest or be affected by what the others wrote.

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
gate=$here/check-privacy-manifest.sh
[ -x "$gate" ] || { echo "no executable gate at $gate" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
tab=$(printf '\t')

write_manifest() {
  out=$1/Turnip/Resources/PrivacyInfo.xcprivacy
  shift
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' '<dict>' \
    '  <key>NSPrivacyTracking</key>' '  <false/>' \
    '  <key>NSPrivacyAccessedAPITypes</key>' '  <array>' >"$out"
  for category in "$@"; do
    printf '    <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategory%s</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>TEST.1</string></array></dict>\n' \
      "$category" >>"$out"
  done
  printf '%s\n' '  </array>' '</dict>' '</plist>' >>"$out"
}

# The entries of NSPrivacyAccessedAPITypes read from stdin, for the cases whose
# subject is the shape of a declaration rather than which category it names.
write_raw_manifest() {
  out=$1/Turnip/Resources/PrivacyInfo.xcprivacy
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' '<dict>' \
      '  <key>NSPrivacyTracking</key>' '  <false/>' \
      '  <key>NSPrivacyAccessedAPITypes</key>' '  <array>'
    cat
    printf '%s\n' '  </array>' '</dict>' '</plist>'
  } >"$out"
}

new_root() {
  dir=$(mktemp -d "$tmp/case.XXXXXX")
  mkdir -p "$dir/Turnip/Resources" "$dir/Turnip/Sources"
  printf 'let placeholder = 1\n' >"$dir/Turnip/Sources/Thing.swift"
  write_manifest "$dir"
  echo "$dir"
}

write_src() {
  printf '%s\n' "$2" >"$1/Turnip/Sources/Thing.swift"
}

# check <label> <expected-exit> <root> [+substring-required | -substring-forbidden ...]
check() {
  label=$1
  want=$2
  root=$3
  shift 3
  if out=$("$gate" "$root" 2>&1); then got=0; else got=$?; fi
  ok=yes
  detail=''
  if [ "$got" != "$want" ]; then
    ok=no
    detail="exit $got, expected $want"
  fi
  for spec in "$@"; do
    needle=${spec#?}
    case $spec in
      +*)
        case $out in
          *"$needle"*) ;;
          *) ok=no; detail="${detail:+$detail; }output is missing: $needle" ;;
        esac
        ;;
      -*)
        case $out in
          *"$needle"*) ok=no; detail="${detail:+$detail; }output should not contain: $needle" ;;
        esac
        ;;
    esac
  done
  if [ "$ok" = yes ]; then
    passed=$((passed + 1))
    echo "  ok   $label"
  else
    failed=$((failed + 1))
    echo "  FAIL $label — $detail"
    printf '%s\n' "$out" | sed 's/^/         | /'
  fi
}

fail_case() {
  failed=$((failed + 1))
  echo "  FAIL $1 — $2"
}

satisfied='every required-reason API referenced under Turnip/ is declared'
stale='declared, but nothing under Turnip/ references it'

# The gate's table, read back from the gate. An extraction that silently
# yielded nothing would run no per-row case and still report zero failures, so
# an empty read is a could-not-run rather than a pass.
rows=$tmp/api_table
sed -n "/^api_table=\$(cat <<'TABLE'\$/,/^TABLE\$/p" "$gate" |
  sed '1d;$d' >"$rows"
if [ ! -s "$rows" ]; then
  echo "could not read the api_table heredoc out of $gate" >&2
  exit 2
fi

echo "test-check-privacy-manifest:"
echo "  $(wc -l <"$rows" | tr -d ' ') pattern rows read from check-privacy-manifest.sh"

# One case per pattern row, driven by the row's own sample call site, with the
# row's categories undeclared. The assertion names the row's pattern, so a
# pattern that stops matching its sample fails even when a different row's
# pattern happens to match the same line.
while IFS="$tab" read -r pattern categories sample; do
  [ -n "$pattern" ] || continue
  if [ -z "${categories:-}" ]; then
    fail_case "row '$pattern'" "no categories in the row's second field"
    continue
  fi
  if [ -z "${sample:-}" ]; then
    fail_case "row '$pattern'" "no sample call site in the row's third field"
    continue
  fi
  root=$(new_root)
  write_src "$root" "$sample"
  set -- "row '$pattern' undeclared" 1 "$root" \
    "+Undeclared required-reason API matching: $pattern" \
    '+Turnip/Sources/Thing.swift'
  # Split through a command substitution rather than an unquoted expansion:
  # zsh does not field-split the latter, which silently collapses the one row
  # that maps to two categories into a single unmatchable name.
  for category in $(printf '%s\n' "$categories"); do
    set -- "$@" "+declare NSPrivacyAccessedAPICategory$category"
  done
  check "$@"
done <"$rows"

# A tree that calls nothing and declares nothing is the gate's quiet case: no
# violation and no staleness note, so a later note means something changed.
root=$(new_root)
check 'no required-reason API in use, nothing declared' 0 "$root" \
  "+$satisfied" -'Undeclared' "-$stale"

# The positive half of the per-row cases: the same call site, with its category
# declared and carrying a reason, is neither a violation nor stale.
root=$(new_root)
write_manifest "$root" FileTimestamp
write_src "$root" 'let d = (attrs as NSDictionary).fileModificationDate()'
check 'a declared category in use is neither a violation nor stale' 0 "$root" \
  "+$satisfied" "-$stale" -'Undeclared'

# Anchoring: an identifier that merely ends in a matched spelling is not a call
# to it, and a gate that fired on one would cost a declaration with no call
# site behind it.
root=$(new_root)
write_src "$root" 'func readattrlist() {} // and let d = profileModificationDate'
check 'identifier merely ending in a spelling does not match' 0 "$root" \
  "+$satisfied" -'Undeclared'

# A declared category nothing calls is a note, not a failure: Apple rejects
# undeclared usage, not an unused declaration.
root=$(new_root)
write_manifest "$root" DiskSpace
check 'declaration with no call site is a note, not a failure' 0 "$root" \
  "+$stale" '+NSPrivacyAccessedAPICategoryDiskSpace' "+$satisfied"

# Declarations are addressed by key path, not grepped out of the extracted
# JSON. Each of the next three manifests parses, mentions the category name
# somewhere inside NSPrivacyAccessedAPITypes, and declares nothing Apple would
# accept — the direction that matters, because a grep green-lights a build that
# gets ITMS-91053.
root=$(new_root)
write_raw_manifest "$root" <<'XML'
    <dict><key>NSPrivacyAccessedAPITypeReasons</key><array><string>NSPrivacyAccessedAPICategoryUserDefaults</string></array></dict>
XML
write_src "$root" 'let store = UserDefaults.standard'
check 'a category named only inside a reasons array declares nothing' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryUserDefaults'

root=$(new_root)
write_raw_manifest "$root" <<'XML'
    <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryDiskSpace</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>Needed for NSPrivacyAccessedAPICategoryUserDefaults too</string></array></dict>
XML
write_src "$root" 'let store = UserDefaults.standard'
check 'a free-text reason naming another category does not declare it' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryUserDefaults'

root=$(new_root)
write_raw_manifest "$root" <<'XML'
    <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string><key>NSPrivacyAccessedAPITypeReasons</key><array/></dict>
XML
write_src "$root" 'let store = UserDefaults.standard'
check 'a declaration with an empty reasons array fails' 1 "$root" \
  '+Declared with no approved reason code: NSPrivacyAccessedAPICategoryUserDefaults' \
  '+declare NSPrivacyAccessedAPICategoryUserDefaults'

# ...and the same entry with a reason is accepted, so the case above turns on
# the empty array rather than on the hand-written manifest.
root=$(new_root)
write_raw_manifest "$root" <<'XML'
    <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array></dict>
XML
write_src "$root" 'let store = UserDefaults.standard'
check 'the same declaration carrying a reason is accepted' 0 "$root" \
  "+$satisfied" -'Undeclared' -'no approved reason'

# A reasonless declaration is a failure even when nothing calls the API: the
# entry is invalid where an unused but well-formed declaration is only stale.
root=$(new_root)
write_raw_manifest "$root" <<'XML'
    <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryDiskSpace</string><key>NSPrivacyAccessedAPITypeReasons</key><array/></dict>
XML
check 'a reasonless declaration fails with no call site behind it' 1 "$root" \
  '+Declared with no approved reason code: NSPrivacyAccessedAPICategoryDiskSpace'

# The manifest's own comment names the APIs it covers, so scanning it as a
# source file would report every declared category as a use of itself.
root=$(new_root)
cat >>"$root/Turnip/Resources/PrivacyInfo.xcprivacy" <<'XML'
<!-- UserDefaults, systemUptime, .creationDateKey -->
XML
check 'the manifest is not scanned as a source file' 0 "$root" \
  "+$satisfied" -'Undeclared'

# Image assets live under Turnip/ and a short anchored pattern can match
# compressed bytes, which is a hit with no call site behind it.
root=$(new_root)
printf 'UserDefaults\000\001\002binary\n' >"$root/Turnip/Resources/blob.bin"
check 'a binary asset carrying the bytes is skipped' 0 "$root" \
  "+$satisfied" -'Undeclared'

# ...and skipping binaries must not blind the scan to the same string in source.
root=$(new_root)
printf 'UserDefaults\000\001\002binary\n' >"$root/Turnip/Resources/blob.bin"
write_src "$root" 'let store = UserDefaults.standard'
check 'the same string in a source file still matches' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryUserDefaults'

# With the declarations key absent the gate re-derives the audit table from the
# tree: every in-use category is reported and nothing else is.
root=$(new_root)
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0">' \
  '<dict><key>NSPrivacyTracking</key><false/></dict>' '</plist>' \
  >"$root/Turnip/Resources/PrivacyInfo.xcprivacy"
write_src "$root" 'let s = UserDefaults.standard; let t = ProcessInfo.processInfo.systemUptime; let k: URLResourceKey = .creationDateKey'
check 'declarations key absent reports exactly the categories in use' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryUserDefaults' \
  '+declare NSPrivacyAccessedAPICategorySystemBootTime' \
  '+declare NSPrivacyAccessedAPICategoryFileTimestamp' \
  -'NSPrivacyAccessedAPICategoryDiskSpace' \
  -'NSPrivacyAccessedAPICategoryActiveKeyboards'

# A manifest Xcode cannot parse is dropped from the build, which reaches App
# Store Connect as declaring nothing at all — a failure, not a note.
root=$(new_root)
printf '%s\n' '<plist version="1.0"><dict>' >"$root/Turnip/Resources/PrivacyInfo.xcprivacy"
check 'a manifest that does not parse fails' 1 "$root" \
  '+is not a valid property list'

# Exit 2 is the check itself not running, which must stay distinguishable from
# exit 1: a missing manifest is not a clean tree.
root=$(new_root)
rm "$root/Turnip/Resources/PrivacyInfo.xcprivacy"
check 'a missing manifest is a could-not-run' 2 "$root" \
  '+no privacy manifest at'

echo "test-check-privacy-manifest: $passed passed, $failed failed."
[ "$failed" -eq 0 ]
