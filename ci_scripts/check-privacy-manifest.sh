#!/bin/sh
set -eu

# Usage: ci_scripts/check-privacy-manifest.sh [repo-root]
#
# Cross-references the required-reason APIs the sources under Turnip/ reference
# against the categories Turnip/Resources/PrivacyInfo.xcprivacy declares. An
# App Store Connect or TestFlight upload of a build that calls one of these
# APIs without declaring its category is rejected at processing time with
# ITMS-91053, enforced rather than warned since 2024-05-01.
#
# Nothing else in this pipeline would catch it. CI builds and tests but never
# produces a distribution archive, so the manifest is never submitted for
# validation and the first observation of a missing declaration is the first
# upload. The audit table in docs/PRIVACY.md carried a prose instruction to
# re-run it by hand, and a prose instruction is not a gate: a feature can add a
# required-reason API, rename nothing, break no build, and leave the table
# asserting the API is unused.
#
# Matching is deliberately conservative. Patterns are matched against whole
# source files including comments and string literals, so a doc comment that
# merely names an API forces its category to be declared. That costs one dict
# in the manifest; the opposite error costs a rejected upload.
#
# Two spellings are deliberately absent, because they collide with APIs that
# are not required-reason: bare `creationDate` and `modificationDate`
# (FileAttributeKey) read identically to `PHAsset.creationDate`, which is
# PhotoKit metadata on user-granted assets. Every other spelling on Apple's
# list is matched, including the `fileModificationDate` accessor an
# attributesOfItem result carries, so the gap is only a bare FileAttributeKey
# subscript.
#
# Over-declaration is reported but does not fail: Apple rejects undeclared
# usage, not an unused declaration, so a declaration outliving its call site is
# a staleness note rather than a release blocker.
#
# Exit codes: 0 every referenced category is declared, 1 at least one is not,
# a declaration carries no approved reason, or the manifest does not parse,
# 2 the check itself could not run.

fail() {
  echo "check-privacy-manifest: $*" >&2
  exit 2
}

root=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
manifest=$root/Turnip/Resources/PrivacyInfo.xcprivacy
tree=$root/Turnip

[ -f "$manifest" ] || fail "no privacy manifest at $manifest"
[ -d "$tree" ] || fail "no Turnip directory at $tree"
command -v plutil >/dev/null 2>&1 || fail "plutil is unavailable; this check needs macOS"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if ! plutil -lint -- "$manifest" >/dev/null 2>&1; then
  echo "Turnip/Resources/PrivacyInfo.xcprivacy is not a valid property list." >&2
  plutil -lint -- "$manifest" 2>&1 | sed 's/^/    /' >&2
  echo "  A manifest Xcode cannot parse is dropped from the build, which reaches" >&2
  echo "  App Store Connect as declaring nothing at all." >&2
  exit 1
fi

# Address each declaration's NSPrivacyAccessedAPIType by key path. Reading the
# structure rather than the XML is what keeps the manifest's own comment from
# satisfying this check, and a grep over the extracted JSON would reintroduce
# that same class one step in: a category name would count from anywhere
# inside NSPrivacyAccessedAPITypes, including a reason array, a free-text
# reason string, or a dict carrying no NSPrivacyAccessedAPIType key at all.
#
# An entry satisfies its category only once it also carries a reason. Apple
# requires at least one string in NSPrivacyAccessedAPITypeReasons, so an empty
# array that counted as a declaration would leave this gate green on a build
# that is rejected anyway.
#
# A missing key path is read from plutil's exit status rather than from empty
# output: plutil reports "Could not extract value" on stdout, so capturing the
# output of a failed extraction yields that sentence as the value.
extract() {
  if value=$(plutil -extract "$1" raw -o - -- "$manifest" 2>/dev/null); then
    printf '%s' "$value"
  fi
}

: >"$workdir/declared"
: >"$workdir/reasonless"
index=0
while plutil -extract "NSPrivacyAccessedAPITypes.$index" json -o - -- "$manifest" >/dev/null 2>&1; do
  declared_type=$(extract "NSPrivacyAccessedAPITypes.$index.NSPrivacyAccessedAPIType")
  first_reason=$(extract "NSPrivacyAccessedAPITypes.$index.NSPrivacyAccessedAPITypeReasons.0")
  index=$((index + 1))
  case $declared_type in
    NSPrivacyAccessedAPICategory*) ;;
    *) continue ;;
  esac
  if [ -n "$first_reason" ]; then
    echo "$declared_type" >>"$workdir/declared"
  else
    echo "$declared_type" >>"$workdir/reasonless"
  fi
done
sort -u "$workdir/declared" -o "$workdir/declared"

# One row per required-reason API spelling this tree could contain:
#
#   <ERE matched against Turnip/><TAB><categories that satisfy it><TAB><sample>
#
# A row is satisfied when ANY of its categories is declared. The getattrlist
# family appears under both the file-timestamp and the disk-space reason tables,
# and the manifest is where the developer records which one applies. POSIX
# spellings are anchored on a non-identifier character so a Swift method whose
# name merely ends in the same letters does not match.
#
# The third field is a call site the row's pattern is meant to match, and it is
# this gate's only unused column. test-check-privacy-manifest.sh reads the table
# back and drives one case per row from it, so a row whose pattern and sample
# disagree — the typo this gate fails open on — is what fails, and a row added
# without a sample fails for want of one. Keeping the sample beside the pattern
# is what makes that coverage automatic instead of a claim.
api_table=$(cat <<'TABLE'
UserDefaults	UserDefaults	let store = UserDefaults.standard
NSUserDefaults	UserDefaults	let store = NSUserDefaults.standardUserDefaults()
activeInputModes	ActiveKeyboards	let modes = UITextInputMode.activeInputModes
systemUptime	SystemBootTime	let t = ProcessInfo.processInfo.systemUptime
mach_absolute_time	SystemBootTime	let t = mach_absolute_time()
creationDateKey	FileTimestamp	let v = try url.resourceValues(forKeys: [.creationDateKey])
contentModificationDateKey	FileTimestamp	let v = try url.resourceValues(forKeys: [.contentModificationDateKey])
NSURLCreationDateKey	FileTimestamp	let k = NSURLCreationDateKey
NSURLContentModificationDateKey	FileTimestamp	let k = NSURLContentModificationDateKey
NSFileCreationDate	FileTimestamp	let d = attrs[NSFileCreationDate]
NSFileModificationDate	FileTimestamp	let d = attrs[NSFileModificationDate]
(^|[^A-Za-z0-9_])fileModificationDate	FileTimestamp	let d = (attrs as NSDictionary).fileModificationDate()
volumeAvailableCapacity	DiskSpace	let v = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
volumeTotalCapacity	DiskSpace	let v = try url.resourceValues(forKeys: [.volumeTotalCapacityKey])
systemFreeSize	DiskSpace	let n = attrs[.systemFreeSize]
systemSize	DiskSpace	let n = attrs[.systemSize]
NSURLVolume(Available|Total)Capacity	DiskSpace	let k = NSURLVolumeAvailableCapacityKey
NSFileSystem(Free)?Size	DiskSpace	let n = attrs[NSFileSystemFreeSize]
(^|[^A-Za-z0-9_])(f|l)?stat(at)?\(	FileTimestamp	let rc = stat(path, &info)
(^|[^A-Za-z0-9_])f?stat(v)?fs\(	DiskSpace	let rc = statfs(path, &info)
(^|[^A-Za-z0-9_])(f?get)?attrlist(at|bulk)?\(	FileTimestamp DiskSpace	let rc = getattrlist(path, &list, &buf, size, 0)
TABLE
)

: >"$workdir/referenced"
: >"$workdir/violations"
tab=$(printf '\t')

# The manifest's own explanatory comment names the APIs it covers, so scanning
# it as a source file would report every declared category as a use of itself.
printf '%s\n' "$api_table" | while IFS="$tab" read -r pattern categories sample; do
  [ -n "$pattern" ] || continue
  # -I skips binary files: image assets live under Turnip/, and a short
  # anchored pattern can match compressed bytes, which grep reports as
  # "Binary file ... matches" — a hit with no call site behind it.
  hits=$(grep -rnIE -- "$pattern" "$tree" 2>/dev/null |
    grep -v '/PrivacyInfo\.xcprivacy:' || :)
  [ -n "$hits" ] || continue

  satisfied=no
  for category in $categories; do
    echo "NSPrivacyAccessedAPICategory$category" >>"$workdir/referenced"
    if grep -qx "NSPrivacyAccessedAPICategory$category" "$workdir/declared"; then
      satisfied=yes
    fi
  done
  if [ "$satisfied" = no ]; then
    {
      echo "Undeclared required-reason API matching: $pattern"
      for category in $categories; do
        echo "  declare NSPrivacyAccessedAPICategory$category with its approved reason code"
      done
      echo "$hits" | sed "s|^$root/||" | sed 's/^/    /' | head -5
    } >>"$workdir/violations"
  fi
done

if [ -s "$workdir/reasonless" ] || [ -s "$workdir/violations" ]; then
  echo "Turnip/Resources/PrivacyInfo.xcprivacy does not satisfy every required-reason API referenced under Turnip/." >&2
  echo "An upload of this build is rejected with ITMS-91053 (Missing API declaration)." >&2
  if [ -s "$workdir/reasonless" ]; then
    sort -u "$workdir/reasonless" -o "$workdir/reasonless"
    while read -r category; do
      echo "  Declared with no approved reason code: $category" >&2
      echo "    NSPrivacyAccessedAPITypeReasons must carry at least one approved reason," >&2
      echo "    so this entry declares nothing and its category stays undeclared." >&2
    done <"$workdir/reasonless"
  fi
  if [ -s "$workdir/violations" ]; then
    sed 's/^/  /' "$workdir/violations" >&2
  fi
  echo "  Add each category to the manifest and update the audit table in docs/PRIVACY.md." >&2
  exit 1
fi

sort -u "$workdir/referenced" -o "$workdir/referenced"
stale=$(comm -23 "$workdir/declared" "$workdir/referenced" || :)
if [ -n "$stale" ]; then
  echo "check-privacy-manifest: declared, but nothing under Turnip/ references it —"
  echo "$stale" | sed 's/^/    /'
  echo "  Not an upload failure. Remove the declaration and its audit row once the API is gone for good."
fi

echo "check-privacy-manifest: every required-reason API referenced under Turnip/ is declared."
