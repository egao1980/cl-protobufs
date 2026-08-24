#!/usr/bin/env bash
# Bundle protoc-gen-cl-pb plus its transitive Homebrew-linked shared libraries
# into DESTDIR so the OCI native/ overlay is self-contained (consumers do not
# need Homebrew protobuf/abseil installed).
#
#   Linux:  copy brewish deps next to the plugin, patchelf RPATH to $ORIGIN.
#           (Linuxbrew libs already carry $ORIGIN first in their RUNPATH,
#           so bundled libs find each other in the same directory.)
#   Darwin: copy brewish deps, rewrite load commands to @loader_path,
#           re-sign (install_name_tool invalidates signatures on arm64).
#
# Note: ship the official static protoc release binary alongside; this script
# only bundles the plugin.
set -euo pipefail

plugin=${1:?path to protoc-gen-cl-pb}
destdir=${2:?output directory}

real_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    readlink -f "$1" 2>/dev/null || echo "$1"
  fi
}

brewish() {
  case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
    */cellar/* | */.linuxbrew/*) return 0 ;;
    *linuxbrew* | *homebrew*) return 0 ;;
    *) return 1 ;;
  esac
}

mkdir -p "$destdir"
plugin_name=$(basename "$plugin")
cp -f "$(real_path "$plugin")" "$destdir/$plugin_name"
chmod 755 "$destdir/$plugin_name"

seen=$(mktemp)
queue=$(mktemp)
trap 'rm -f "$seen" "$queue"' EXIT
printf '%s\n' "$destdir/$plugin_name" >"$queue"

bundle_linux() {
  command -v patchelf >/dev/null 2>&1 || {
    echo "ERROR: patchelf required (apt-get install patchelf)" >&2
    exit 1
  }

  while [ -s "$queue" ]; do
    current=$(head -n1 "$queue")
    tail -n +2 "$queue" >"${queue}.tmp" && mv "${queue}.tmp" "$queue"
    grep -Fxq "$current" "$seen" 2>/dev/null && continue
    printf '%s\n' "$current" >>"$seen"

    while IFS= read -r line; do
      # "libfoo.so.1 => /path/libfoo.so.1 (0x...)": $1 is the soname the
      # dynamic linker looks up, $3 is where it resolved.
      soname=$(printf '%s' "$line" | awk '$2 == "=>" { print $1; exit }')
      src=$(printf '%s' "$line" | awk '$2 == "=>" { print $3; exit }')
      [ -n "$soname" ] && [ -n "$src" ] && [ "$src" != "not" ] || continue
      [ -f "$src" ] || continue
      brewish "$src" || continue
      if [ ! -f "$destdir/$soname" ]; then
        cp -f "$(real_path "$src")" "$destdir/$soname"
        chmod 644 "$destdir/$soname"
      fi
      grep -Fxq "$destdir/$soname" "$seen" 2>/dev/null \
        || printf '%s\n' "$destdir/$soname" >>"$queue"
    done < <(ldd "$current" 2>/dev/null || true)
  done

  patchelf --force-rpath --set-rpath '$ORIGIN' "$destdir/$plugin_name"
}

# Print resolved absolute paths of LC_LOAD_DYLIB deps of $1.
# @rpath/NAME entries are resolved against the candidate dirs in $2 (colon-sep).
darwin_deps() {
  local lib=$1 rpath_dirs=$2 dep dir
  otool -L "$lib" 2>/dev/null | tail -n +2 | while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] || continue
    dep=${line%%[[:space:]]*}
    case $dep in
      @rpath/*)
        IFS=':' read -ra dirs <<<"$rpath_dirs"
        for dir in "${dirs[@]}"; do
          if [ -f "$dir/${dep#@rpath/}" ]; then
            printf '%s\n' "$dir/${dep#@rpath/}"
            break
          fi
        done
        ;;
      @*) ;;
      /*) [ -f "$dep" ] && printf '%s\n' "$dep" ;;
      *) ;;
    esac
  done
}

bundle_darwin() {
  local brew_lib=""
  command -v brew >/dev/null 2>&1 && brew_lib="$(brew --prefix)/lib"

  while [ -s "$queue" ]; do
    current=$(head -n1 "$queue")
    tail -n +2 "$queue" >"${queue}.tmp" && mv "${queue}.tmp" "$queue"
    grep -Fxq "$current" "$seen" 2>/dev/null && continue
    printf '%s\n' "$current" >>"$seen"

    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      dreal=$(real_path "$dep")
      brewish "$dreal" || continue
      base=$(basename "$dep")
      if [ ! -f "$destdir/$base" ]; then
        cp -f "$dreal" "$destdir/$base"
        chmod 644 "$destdir/$base"
      fi
      grep -Fxq "$destdir/$base" "$seen" 2>/dev/null \
        || printf '%s\n' "$destdir/$base" >>"$queue"
    done < <(darwin_deps "$current" "$(dirname "$(real_path "$current")"):$brew_lib")
  done

  # Rewrite load commands: any bundled dep (referenced by absolute brew path
  # or @rpath) now resolves via @loader_path in the same directory.
  for f in "$destdir"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    [ "$base" = "$plugin_name" ] || install_name_tool -id "@loader_path/$base" "$f" 2>/dev/null || true
    while IFS= read -r line; do
      line=${line#"${line%%[![:space:]]*}"}
      [ -n "$line" ] || continue
      old=${line%%[[:space:]]*}
      case $old in
        @rpath/*) b=${old#@rpath/} ;;
        /*) brewish "$old" || continue; b=$(basename "$old") ;;
        *) continue ;;
      esac
      [ -f "$destdir/$b" ] || continue
      new="@loader_path/$b"
      [ "$old" = "$new" ] || install_name_tool -change "$old" "$new" "$f"
    done < <(otool -L "$f" 2>/dev/null | tail -n +2)
    # install_name_tool invalidates the ad-hoc signature; arm64 kills
    # binaries with broken signatures at exec/dlopen time.
    codesign --force -s - "$f" 2>/dev/null || true
  done
}

case $(uname -s) in
  Darwin) bundle_darwin ;;
  *) bundle_linux ;;
esac

printf 'Bundled into %s:\n' "$destdir"
ls -l "$destdir"
