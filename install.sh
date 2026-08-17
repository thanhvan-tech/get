#!/usr/bin/env bash
#
# thanhvan installer.
#
#   curl -fsSL https://raw.githubusercontent.com/thanhvan-tech/get/main/install.sh | bash
#
# ===========================================================================
# THIS FILE IS PUBLIC, AND SO IS WHAT IT DOWNLOADS.
#
# It is published to the public thanhvan-tech/get repo so that `curl | bash`
# works with no credentials at all -- no gh, no token, no org membership check.
# It contains NO secrets, and it must never grow one: the CLI it installs is a
# wrapper around four public vendor CLIs and has nothing worth protecting.
#
# The private thanhvan-cli repo is the BUILD SOURCE for the container image.
# What ships to users is this script, the launcher, and a public image.
#
# Source of truth is thanhvan-cli/install/install.sh. Edit it there.
# ===========================================================================
#
# ===========================================================================
# THIS SCRIPT IS PIPED INTO A SHELL. Three consequences, all load-bearing:
#
#  1. EVERYTHING IS INSIDE A FUNCTION, called on the very last line. A truncated
#     download -- dropped connection, proxy timeout -- otherwise leaves bash
#     executing half a command with no indication anything was missing. With the
#     wrapper, a truncated file defines an incomplete function and never calls
#     it, so nothing happens at all.
#
#  2. BASH 3.2, because macOS ships 3.2.57 as /bin/bash and always will (bash 4
#     went GPLv3). No associative arrays, no ${x,,}, no mapfile.
#
#  3. THE PAYLOAD IS CHECKSUM-VERIFIED before it is made executable.
# ===========================================================================

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/thanhvan-tech/get/main"

main() {
  local xdg_data xdg_bin share_dir bin_link
  xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
  xdg_bin="$HOME/.local/bin"
  share_dir="$xdg_data/thanhvan"
  bin_link="$xdg_bin/thanhvan"

  if [ -t 1 ]; then
    C_DIM='\033[2m'; C_RED='\033[31m'; C_GRN='\033[32m'; C_OFF='\033[0m'
  else
    C_DIM=''; C_RED=''; C_GRN=''; C_OFF=''
  fi
  say()  { printf '%b\n' "${C_DIM}thanhvan:${C_OFF} $*" >&2; }
  ok()   { printf '%b\n' "${C_GRN}thanhvan:${C_OFF} $*" >&2; }
  die()  { printf '%b\n' "${C_RED}thanhvan: error:${C_OFF} $*" >&2; exit 1; }

  # --- detect -------------------------------------------------------------
  local os
  case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux)
      if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
          ubuntu|debian) os="$ID" ;;
          *)
            case " ${ID_LIKE:-} " in
              *" debian "*|*" ubuntu "*) os="debian" ;;
              *) die "unsupported distribution '${ID:-unknown}'. thanhvan supports macOS and Debian/Ubuntu." ;;
            esac ;;
        esac
      else
        die "cannot read /etc/os-release."
      fi ;;
    *) die "unsupported operating system '$(uname -s)'." ;;
  esac
  say "$os/$(uname -m)"

  # --- docker -------------------------------------------------------------
  # The one and only prerequisite, and the one thing this script will not
  # install for you: installing a container runtime unattended means a kernel
  # module, a system service and a group membership change, on a machine whose
  # policy this script knows nothing about.
  #
  # Checked here rather than on first use so that the failure arrives now, while
  # the person is still paying attention, instead of halfway through their first
  # `thanhvan gcloud`.
  if ! command -v docker >/dev/null 2>&1; then
    if [ "$os" = "macos" ]; then
      die "Docker is required, and is the only thing thanhvan needs on this machine.
  Install it:  brew install --cask docker      (or orbstack, or colima)
  Then re-run this installer."
    fi
    die "Docker is required, and is the only thing thanhvan needs on this machine.
  Install it:  https://docs.docker.com/engine/install/
  Then re-run this installer."
  fi
  if ! docker info >/dev/null 2>&1; then
    if [ "$os" = "macos" ]; then
      die "Docker is installed but its daemon is not running.
  Start it:  open -a Docker
  Then re-run this installer."
    fi
    die "Docker is installed but its daemon is not running.
  Start it:  sudo systemctl start docker
  If that says permission denied:  sudo usermod -aG docker \$USER  (then log out and back in)
  Then re-run this installer."
  fi
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo present)"

  # --- download -----------------------------------------------------------
  # No credentials, by design. The launcher is a public file in a public repo,
  # and the image it runs is a public package.
  local tmp
  tmp=$(mktemp -d)
  # Clean up on any exit, including the die() paths below.
  trap 'rm -rf "$tmp"' EXIT

  say "downloading"
  curl -fsSL "$BASE_URL/thanhvan"        -o "$tmp/thanhvan" \
    || die "could not download the launcher from $BASE_URL/thanhvan"
  curl -fsSL "$BASE_URL/thanhvan.sha256" -o "$tmp/thanhvan.sha256" \
    || die "could not download the checksum. Refusing to install unverified."

  # --- verify -------------------------------------------------------------
  # Before it is made executable and put on PATH, not after.
  local want got
  want=$(awk '{print $1; exit}' "$tmp/thanhvan.sha256")
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$tmp/thanhvan" | awk '{print $1}')
  else
    # macOS has shasum, not sha256sum.
    got=$(shasum -a 256 "$tmp/thanhvan" | awk '{print $1}')
  fi
  [ -n "$want" ] || die "the checksum file is empty. Refusing to install unverified."
  [ "$want" = "$got" ] || die "checksum mismatch.
  expected $want
  got      $got
  The download is corrupt or has been tampered with. Nothing was installed."
  ok "checksum verified"

  # --- install ------------------------------------------------------------
  # The launcher carries its own version, so there is exactly one place a
  # version is written down and no way for the two to disagree.
  local version version_dir sel=""
  version=$(grep -E '^THANHVAN_VERSION=' "$tmp/thanhvan" | head -1 | cut -d'"' -f2)
  [ -n "$version" ] || die "the downloaded launcher has no THANHVAN_VERSION. Refusing to install."
  version_dir="$share_dir/versions/$version"

  mkdir -p "$share_dir/versions" "$xdg_bin" "$version_dir/bin"
  cp "$tmp/thanhvan" "$version_dir/bin/thanhvan"
  chmod +x "$version_dir/bin/thanhvan"

  # Repoint `current`. THE -n IS THE WHOLE FLAG: without it, ln follows an
  # existing `current` symlink to the directory it names and creates the new
  # link INSIDE it, so `current` keeps selecting the old version and ln exits 0.
  #
  # Staging a link and `mv -f`ing it over `current` has the same bug -- mv stats
  # the destination through the symlink and moves the link into the directory --
  # and `mv -T` is a GNU-ism macOS does not have. This only ever bites on a
  # RE-install, where `current` already exists, which is exactly the run people
  # make to repair a broken one.
  ln -sfn "versions/$version" "$share_dir/current"

  # Read back where it points. The failure above is a silent no-op, and this
  # installer's whole job is that the next command runs what it just installed.
  sel=$(cd -P "$share_dir/current" 2>/dev/null && pwd) || sel=""
  [ "$sel" = "$share_dir/versions/$version" ] || die "installed $version, but
  $share_dir/current selects ${sel:-nothing}. Nothing will run the new version.
  Remove $share_dir/current and re-run this installer."

  ln -sfn "../share/thanhvan/current/bin/thanhvan" "$bin_link"
  ok "thanhvan $version installed to $bin_link"

  # --- PATH ---------------------------------------------------------------
  # Debian's default ~/.profile already adds ~/.local/bin when it exists; macOS
  # does not. Marked block so re-running replaces rather than appends.
  local rc begin end
  begin="# >>> thanhvan >>>"
  end="# <<< thanhvan <<<"
  case "$(basename "${SHELL:-}")" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) if [ "$os" = "macos" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *)    rc="" ;;
  esac

  if [ -n "$rc" ] && ! printf '%s' ":$PATH:" | grep -q ":$xdg_bin:"; then
    if [ ! -f "$rc" ] || ! grep -qF "$begin" "$rc" 2>/dev/null; then
      # $PATH must reach the rc file literally, not expanded at write time.
      # shellcheck disable=SC2016
      printf '\n%s\nexport PATH="%s:$PATH"\n%s\n' "$begin" "$xdg_bin" "$end" >> "$rc"
      ok "added $xdg_bin to PATH in $rc"
    fi
  fi

  # --- hand over ----------------------------------------------------------
  printf '\n' >&2

  # PATH may not include ~/.local/bin in THIS shell yet, so call it by path.
  # exec so setup owns the terminal: it runs four OAuth flows that print a URL
  # and wait for a code, and a subshell would break every one of them.
  if [ -t 0 ]; then
    exec "$bin_link" setup workstation
  else
    # Piped from curl: stdin is the script, not a terminal, so the sign-in flows
    # could not prompt. Say what to run instead of running it badly.
    say "run this next:"
    printf '\n    thanhvan setup workstation\n\n' >&2
    say "(open a new terminal first, so PATH picks up $xdg_bin)"
  fi
}

# The last line, and the reason for the wrapper: a truncated download never
# reaches it.
main "$@"
