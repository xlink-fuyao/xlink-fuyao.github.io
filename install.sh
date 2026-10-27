#!/usr/bin/env bash
# xlink installer.
#
#   curl -fsSL <release-origin>/install | bash
#
# `scripts/build-bundle.sh` stamps the release origin into the published copy;
# run this source file directly only with XLINK_ORIGIN set.
#
# Installs the xlink CLI as a Bun-target JS bundle at ~/.xlink/bin/xlink.js,
# with an `xlink` launcher that runs it with `bun`, plus the `xclaude`,
# `xopencode`, `xcodex`, `xchatgpt`, `xdeepseek`, `xgrok`, `xhermes`, `xpi`, and
# `xprime` convenience wrappers. Installs the latest Bun for the user, or
# upgrades an older one. The bundle is checked against the release manifest's
# sha256 and its own `--version` before it replaces an existing installation.
#
# Environment:
#   XLINK_ORIGIN      release origin to install from (default: the build's)
#   XLINK_HOME        install directory (default: ~/.xlink)
#   XLINK_NO_DAEMON=1 skip installing the login auto-start service
#   XLINK_NO_LAUNCH=1 skip the offer to start xlink when the install finishes
#   NO_COLOR=1        plain output
#
# After install, the CLI prompts once for a Fuyao API key on first use and
# keeps itself updated from the same origin.

set -euo pipefail

ORIGIN="${XLINK_ORIGIN:-https://xlink-fuyao.github.io}"
ORIGIN="${ORIGIN%/}"
INSTALL_DIR="${XLINK_HOME:-$HOME/.xlink}"
BIN_DIR="$INSTALL_DIR/bin"
PUBLIC_BIN_DIR="$HOME/.local/bin"
UPDATE_CHANNEL_FILE="$INSTALL_DIR/.update-manifest-url"
WRAPPERS="xclaude:claude xopencode:opencode xcodex:codex xchatgpt:chatgpt xdeepseek:deepseek xgrok:grok xhermes:hermes xpi:pi xprime:prime"
COMMANDS="xlink xclaude xopencode xcodex xchatgpt xdeepseek xgrok xhermes xpi xprime"

white="" green="" gray="" orange="" red="" stdout_reset="" stderr_reset=""
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
  white=$'\033[1;97m'
  green=$'\033[32m'
  gray=$'\033[90m'
  orange=$'\033[38;5;208m'
  stdout_reset=$'\033[0m'
fi
if [ -t 2 ] && [ "${TERM:-}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
  red=$'\033[31m'
  stderr_reset=$'\033[0m'
fi

heading() { printf "%b%s%b\n" "$white" "$1" "$stdout_reset"; }
info() { printf "%s\n" "$1"; }
success() { printf "%b✔ %s%b\n" "$green" "$1" "$stdout_reset"; }
metadata() { printf "%b%s:%b %b%s%b\n" "$gray" "$1" "$stdout_reset" "$white" "$2" "$stdout_reset"; }
next_step() { printf "%bNext:%b %b%s%b\n" "$orange" "$stdout_reset" "$white" "$1" "$stdout_reset"; }
err() { printf "%b✗ %s%b\n" "$red" "$1" "$stderr_reset" >&2; }

case "$ORIGIN" in
  http://*|https://*) ;;
  *)
    err "No release origin. Install with: curl -fsSL <release-origin>/install | bash"
    err "(or set XLINK_ORIGIN when running scripts/install.sh from a checkout)"
    exit 1
    ;;
esac

# An https origin must stay https: refuse any redirect to plain http, which
# would let the network swap both the manifest and the bundle it vouches for.
CURL_PROTO=()
case "$ORIGIN" in
  https://*) CURL_PROTO=(--proto '=https' --proto-redir '=https') ;;
esac

case "$(uname -s)" in
  Darwin|Linux) ;;
  *)
    err "xlink's installer supports macOS and Linux. On Windows, use WSL."
    exit 1
    ;;
esac

if ! command -v curl >/dev/null 2>&1; then
  err "Need curl to install xlink. Please install curl and re-run."
  exit 1
fi

heading "Setting up xlink..."

# --- 1. Ensure the latest Bun ---------------------------------------------------
# xlink supports only the latest Bun release: install it when missing, upgrade
# an older one, and stop if it is still behind (for example a Homebrew or npm
# install that `bun upgrade` cannot update).
latest_bun_version() {
  curl --proto '=https' --proto-redir '=https' -fsSL \
    https://api.github.com/repos/oven-sh/bun/releases/latest 2>/dev/null \
    | tr -d '\n' \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"bun-v\([0-9][0-9A-Za-z.+-]*\)".*/\1/p' \
    | head -n 1
}
# Exits non-zero when Bun at $1 is older than version $2.
bun_is_at_least() {
  "$1" --config=/dev/null --no-env-file -e \
    'process.exit(Bun.semver.order(Bun.version, process.argv[1]) < 0 ? 1 : 0)' "$2" >/dev/null 2>&1
}

LATEST_BUN="$(latest_bun_version || true)"
bun_current=0
if ! command -v bun >/dev/null 2>&1; then
  if ! command -v unzip >/dev/null 2>&1; then
    err "Need unzip to install Bun. Install unzip, then re-run the xlink installer."
    err "On Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y unzip"
    exit 1
  fi
  info "Installing Bun…"
  curl --proto '=https' --proto-redir '=https' -fsSL https://bun.sh/install | bash >/dev/null
  # bun.sh writes to $BUN_INSTALL (default ~/.bun); add it to PATH for the
  # rest of this script.
  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  export PATH="$BUN_INSTALL/bin:$PATH"
  if ! command -v bun >/dev/null 2>&1; then
    err "Bun install finished but bun isn't on PATH. Open a new shell and re-run."
    exit 1
  fi
  bun_current=1
fi
BUN_BIN="$(command -v bun)"
# PATH can contain relative directories; the launcher must keep working after
# the user changes directories. Keep the binary symlink itself intact.
BUN_BIN="$(cd "$(dirname "$BUN_BIN")" && pwd)/$(basename "$BUN_BIN")"

if [ "$bun_current" -eq 0 ]; then
  if [ -z "$LATEST_BUN" ]; then
    # The latest version is unknown, so let Bun check for itself.
    "$BUN_BIN" upgrade >/dev/null 2>&1 && bun_current=1
  elif ! bun_is_at_least "$BUN_BIN" "$LATEST_BUN"; then
    info "Upgrading Bun $("$BUN_BIN" --version) → $LATEST_BUN…"
    "$BUN_BIN" upgrade >/dev/null 2>&1 || true
  fi
fi
if [ -n "$LATEST_BUN" ] && ! bun_is_at_least "$BUN_BIN" "$LATEST_BUN"; then
  err "xlink needs the latest Bun ($LATEST_BUN), but $BUN_BIN is $("$BUN_BIN" --version)."
  err "Upgrade it (bun upgrade, brew upgrade bun, or npm install -g bun@latest), then re-run."
  exit 1
elif [ -z "$LATEST_BUN" ] && [ "$bun_current" -eq 0 ]; then
  err "Could not confirm that $BUN_BIN ($("$BUN_BIN" --version)) is the latest Bun."
  err "Run 'bun upgrade' (or your package manager's upgrade), then re-run."
  exit 1
fi
# The launcher runs Bun with --no-env-file so a project's .env in the launch
# directory never reaches the harness or the proxy, and with an empty --config
# so the directory's bunfig.toml preloads never run.

# --- 2. Download and verify the release ---------------------------------------
mkdir -p "$BIN_DIR"

download_dir="$(mktemp -d "$BIN_DIR/.install.XXXXXX")"
download_manifest="$download_dir/latest.json"
download_bundle="$download_dir/xlink.js"
cleanup_download() {
  rm -rf "$download_dir"
}
trap cleanup_download EXIT

download_with_optional_spinner() {
  url="$1"
  dest="$2"
  label="$3"
  if [ ! -t 1 ] || [ "${TERM:-}" = "dumb" ] || [ -n "${NO_COLOR:-}" ]; then
    curl ${CURL_PROTO[@]+"${CURL_PROTO[@]}"} -fsSL "$url" -o "$dest"
    return
  fi

  curl ${CURL_PROTO[@]+"${CURL_PROTO[@]}"} -fsSL "$url" -o "$dest" &
  download_pid=$!
  spinner_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  spinner_index=0
  while kill -0 "$download_pid" 2>/dev/null; do
    printf "\r%b%s%b %s..." "$orange" "${spinner_frames[$spinner_index]}" "$stdout_reset" "$label"
    spinner_index=$(((spinner_index + 1) % ${#spinner_frames[@]}))
    sleep 0.08
  done
  download_status=0
  wait "$download_pid" || download_status=$?
  printf "\r\033[2K"
  return "$download_status"
}

# Portable SHA-256 of a file (sha256sum on Linux, shasum on macOS, else Bun).
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    "$BUN_BIN" --config=/dev/null --no-env-file -e '
      const hasher = new Bun.CryptoHasher("sha256");
      hasher.update(await Bun.file(process.argv[1]).arrayBuffer());
      console.log(hasher.digest("hex"));
    ' "$1"
  fi
}

if ! download_with_optional_spinner "$ORIGIN/latest.json" "$download_manifest" "Fetching release manifest"; then
  err "Failed to download $ORIGIN/latest.json"
  exit 1
fi
# The manifest is small, fixed-shape JSON written by scripts/build-bundle.sh.
expected_sha="$(
  tr -d '\n' < "$download_manifest" \
    | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([a-fA-F0-9]\{64\}\)".*/\1/p' \
    | tr 'A-F' 'a-f' \
    | head -n 1
)"
if [[ ! "$expected_sha" =~ ^[a-f0-9]{64}$ ]]; then
  err "Release manifest is missing a valid sha256. Existing installation was preserved; please retry."
  exit 1
fi

if ! download_with_optional_spinner "$ORIGIN/xlink.js" "$download_bundle" "Downloading xlink"; then
  err "Failed to download $ORIGIN/xlink.js"
  exit 1
fi
actual_sha="$(file_sha256 "$download_bundle")" || exit 1
if [ "$actual_sha" != "$expected_sha" ]; then
  err "Downloaded bundle failed its integrity check. Existing installation was preserved; please retry."
  exit 1
fi
# Run the new bundle against a throwaway home so the check has no side effects.
if ! downloaded_version="$(HOME="$download_dir" XLINK_HOME="$download_dir" "$BUN_BIN" --config=/dev/null --no-env-file "$download_bundle" --version 2>/dev/null)" || \
   [[ ! "$downloaded_version" =~ ^xlink\ v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  err "Downloaded bundle failed its version check. Existing installation was preserved; please retry."
  exit 1
fi

mv -f "$download_bundle" "$BIN_DIR/xlink.js"

# Keep this install on the origin it came from; the CLI's updater reads it.
printf "%s\n" "$ORIGIN/latest.json" > "$UPDATE_CHANNEL_FILE"
chmod 600 "$UPDATE_CHANNEL_FILE"

# --- 3. Write the launcher and wrappers ---------------------------------------
cat > "$BIN_DIR/xlink" <<EOF
#!/usr/bin/env sh
# xlink launcher — runs the installed Bun-target JS bundle.
exec "$BUN_BIN" --config=/dev/null --no-env-file "$BIN_DIR/xlink.js" "\$@"
EOF
chmod +x "$BIN_DIR/xlink"

for wrapper in $WRAPPERS; do
  name="${wrapper%%:*}"
  harness="${wrapper##*:}"
  cat > "$BIN_DIR/$name" <<EOF
#!/usr/bin/env sh
exec "$BIN_DIR/xlink" $harness "\$@"
EOF
  chmod +x "$BIN_DIR/$name"
done

# Remove old xlink-owned wrappers that used the upstream agent names.
# Current installs must never shadow `claude`, `codex`, or `opencode`; users
# should get the real CLIs unless they explicitly run a xlink wrapper.
remove_legacy_shadow_wrapper() {
  name="$1"
  path="$BIN_DIR/$name"

  [ -e "$path" ] || [ -L "$path" ] || return 0

  if [ -L "$path" ]; then
    target="$(readlink "$path" 2>/dev/null || true)"
    case "$target" in
      "$BIN_DIR/xclaude"|"$BIN_DIR/xcodex"|"$BIN_DIR/xchatgpt"|"$BIN_DIR/xdeepseek"|"$BIN_DIR/xopencode"|"$BIN_DIR/xgrok"|"$BIN_DIR/xhermes"|"$BIN_DIR/xpi"|"$BIN_DIR/xprime"|"$BIN_DIR/xlink"|"$BIN_DIR/xlink.js")
        rm -f "$path"
        ;;
    esac
    return 0
  fi

  if [ -f "$path" ] && grep -Fqs "$BIN_DIR/xlink" "$path"; then
    rm -f "$path"
  fi
}

remove_legacy_shadow_wrapper claude
remove_legacy_shadow_wrapper codex
remove_legacy_shadow_wrapper opencode
remove_legacy_shadow_wrapper grok

# --- 4. Expose the commands on PATH -------------------------------------------
# Keep the bundle and managed wrappers fuyao, while exposing commands from
# the conventional user bin directory. Never replace unrelated commands there.
# Links that earlier installers made elsewhere on PATH still point at $BIN_DIR
# and keep working.
command_bin_dir="$BIN_DIR"
link_command() {
  name="$1"
  public_path="$PUBLIC_BIN_DIR/$name"
  if [ -L "$public_path" ]; then
    case "$(readlink "$public_path" 2>/dev/null || true)" in
      "$BIN_DIR/$name"|*/.xlink/bin/"$name") rm -f "$public_path" ;;
    esac
  fi
  if [ ! -e "$public_path" ] && [ ! -L "$public_path" ]; then
    ln -s "$BIN_DIR/$name" "$public_path" 2>/dev/null || true
  fi
}
if { [ -d "$PUBLIC_BIN_DIR" ] || mkdir -p "$PUBLIC_BIN_DIR" 2>/dev/null; } && [ -w "$PUBLIC_BIN_DIR" ]; then
  link_command xlink
  if [ -L "$PUBLIC_BIN_DIR/xlink" ] && [ "$(readlink "$PUBLIC_BIN_DIR/xlink")" = "$BIN_DIR/xlink" ]; then
    command_bin_dir="$PUBLIC_BIN_DIR"
    for name in $COMMANDS; do
      [ "$name" = xlink ] || link_command "$name"
    done
  fi
fi

# A piped installer cannot change its parent shell's PATH. Report the command
# as ready only when PATH actually resolves to this installation's launcher.
commands_ready=0
resolved_command="$(command -v xlink 2>/dev/null || true)"
if [ -n "$resolved_command" ]; then
  if [ "$resolved_command" = "$command_bin_dir/xlink" ] || [ "$resolved_command" = "$BIN_DIR/xlink" ]; then
    commands_ready=1
  elif [ -L "$resolved_command" ] && [ "$(readlink "$resolved_command")" = "$BIN_DIR/xlink" ]; then
    commands_ready=1
  fi
fi

# --- 5. Persist PATH for new shells -------------------------------------------
path_line="export PATH=\"$command_bin_dir:\$PATH\""
SHELL_RC=""

detect_shell_rc() {
  case "${SHELL:-}" in
    */zsh)
      case "${ZDOTDIR:-}" in
        /*) printf "%s/.zshrc" "$ZDOTDIR" ;;
        *)  printf "%s/.zshrc" "$HOME" ;;
      esac
      ;;
    */bash) printf "%s/.bashrc" "$HOME" ;;
    *)      printf "%s/.profile" "$HOME" ;;
  esac
}

configure_shell_path() {
  rc="$1"
  mkdir -p "$(dirname "$rc")"
  touch "$rc"
  if ! grep -Fqs "$path_line" "$rc"; then
    {
      printf "\n# xlink\n"
      printf "%s\n" "$path_line"
    } >> "$rc"
  fi
}

shell_path_persisted=0
case ":$PATH:" in
  *":$command_bin_dir:"*) ;;
  *)
    case "${SHELL:-}" in
      */zsh|*/bash|*/sh|*/dash|*/ksh|*/ash|"")
        SHELL_RC="$(detect_shell_rc)"
        configure_shell_path "$SHELL_RC"
        shell_path_persisted=1
        ;;
    esac
    # Login Bash reads only the first existing login profile, not .bashrc.
    # Preserve that choice rather than creating a file that shadows it.
    case "${SHELL:-}" in
      */bash)
        login_rc="$HOME/.bash_profile"
        for candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
          if [ -f "$candidate" ]; then
            login_rc="$candidate"
            break
          fi
        done
        configure_shell_path "$login_rc"
        ;;
    esac
    ;;
esac

# --- 6. Verify, then set up the daemon ----------------------------------------
if ! installed_version="$("$BIN_DIR/xlink" --version 2>/dev/null)" || \
   [ "$installed_version" != "$downloaded_version" ]; then
  err "Installed launcher failed its version check. Re-run the installer."
  exit 1
fi
"$BIN_DIR/xlink" __telemetry-install-completed >/dev/null 2>&1 || true

# Install the login service so the shared proxy daemon starts automatically and
# survives restarts. Containers, CI, headless sessions, and minimal
# distributions fall back to portable process mode on the first daemon-backed
# command.
daemon_status=""
if [ -z "${XLINK_NO_DAEMON:-}" ]; then
  case "$(uname -s)" in
    Darwin) service_name="launchd agent" ;;
    *)      service_name="systemd user service" ;;
  esac
  if "$BIN_DIR/xlink" daemon install >/dev/null 2>&1; then
    daemon_status="$service_name (starts at login)"
  else
    daemon_status="on demand (OS auto-start unavailable)"
  fi
fi

# --- 7. Summary ---------------------------------------------------------------
printf "\n"
case "$command_bin_dir/xlink" in
  "$HOME"/*) location_display="~/${command_bin_dir#"$HOME"/}/xlink" ;;
  *) location_display="$command_bin_dir/xlink" ;;
esac

# A piped installer cannot add the launcher to its parent shell's PATH, and the
# printed export is easy to miss. When a person is at a terminal, offer to start
# the installed CLI so the first run needs no PATH setup. Automation can look
# like a terminal too, so the offer times out instead of waiting forever.
offer_launch=0
if [ -z "${XLINK_NO_LAUNCH:-}" ] && [ -z "${CI:-}" ] && \
   [ -z "${CLAUDECODE:-}" ] && [ -z "${CURSOR_AGENT:-}" ] && \
   [ -z "${CODEX_SANDBOX:-}" ] && [ -z "${GEMINI_CLI:-}" ] && \
   [ -t 1 ] && [ "${TERM:-}" != "dumb" ] && { : < /dev/tty; } 2>/dev/null; then
  offer_launch=1
fi

success "xlink successfully installed!"
printf "\n"
metadata "Version" "${downloaded_version#xlink v}"
metadata "Location" "$location_display"
metadata "Updates" "$ORIGIN"
if [ -n "$daemon_status" ]; then
  metadata "Daemon" "$daemon_status"
fi
if [ "$commands_ready" -eq 1 ]; then
  next_step "Run xlink to get started"
elif [ "$shell_path_persisted" -eq 1 ]; then
  next_step "Run $path_line && xlink"
  info "      New terminal: run xlink (PATH added to $SHELL_RC)"
else
  case "${SHELL:-}" in
    */fish) next_step "Run fish_add_path \"$command_bin_dir\"; then run xlink" ;;
    *) next_step "Add $command_bin_dir to your shell's PATH, then run xlink" ;;
  esac
fi
info "      Shortcuts: ${COMMANDS#xlink }"
info "      On first run, xlink asks for your Fuyao API key."
printf "\n"

launch_now=0
if [ "$offer_launch" -eq 1 ]; then
  printf "%bPress Enter to start xlink%b %b(skips in 10s)%b " "$white" "$stdout_reset" "$gray" "$stdout_reset"
  launch_key="x"
  IFS= read -r -s -n 1 -t 10 launch_key < /dev/tty 2>/dev/null || launch_key="x"
  printf "\n"
  [ -z "$launch_key" ] && launch_now=1
fi

if [ "$launch_now" -eq 1 ]; then
  # Bash does not run the EXIT trap across exec; release the download
  # directory here. A piped installer's stdin is the script itself, so the CLI
  # gets the terminal through the inherited stdout descriptor: Bun ignores
  # keyboard input on a separately opened /dev/tty, but reads a dup of the
  # terminal's own descriptor.
  cleanup_download
  trap - EXIT
  export PATH="$command_bin_dir:$PATH"
  exec "$command_bin_dir/xlink" 0<&1
fi
