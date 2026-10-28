{ config, lib, pkgs, ... }:

# focus-observer: which app, window and browser tab had the screen, as three opt-in parts.
#   programs.focusObserver.enable            — the resident observer: NSWorkspace + AXObserver focus intervals as OTLP spans.
#   programs.focusObserver.tabs.enable       — the Chrome extension (the browser half): active-tab intervals as OTLP spans.
#   programs.focusObserver.appSampler.enable — the once-a-minute `lsappinfo` sampler: frontmost bundle id + idle seconds as JSONL.
# Spans go to an OTLP/HTTP collector on 127.0.0.1:4318 (FOCUS_OBSERVER_OTLP overrides it for the observer).
#
# ── the observer
# focus-observer: which app has the screen, as intervals rather than samples.
#
# The app sampler (below) polls `lsappinfo front` once a minute. Two costs no
# poller can fix from the inside: an app used for thirty seconds may never be
# sampled at all, and every interval is quantised to the sampling grid. This
# subscribes to NSWorkspace instead, so a focus change is an event with a real
# start and a real end, and to AXObserver for which window inside the app.
#
# It EMITS SPANS, to an OTLP collector (log records and spans side by side).
# That difference is the point rather than a preference: a focus interval has
# a start, an end and a duration, which is a span; a poller's sample has only
# an instant, which is a log record. The rationale, and the line drawn between
# window titles and window contents, live beside the code in
# src/observer.swift.
#
# THIS DOES NOT REPLACE app-attention. That one joins a bundle id to a signed
# App vertex and lands in a JSONL log; this one lands in a trace store. They
# measure the same thing at different resolutions and through different
# pipes, and keeping both is how the cheap one stays a check on the new one.
#
# ── Why the binary is compiled to a stable path instead of run from the store
#
# TCC grants attach to the EXECUTING BINARY, and the shape of that binary
# decides both how narrow the grant is and how long it survives:
#
#   /usr/bin/swift observer.swift   the executable is swift-frontend, so
#                                   granting Accessibility grants it to EVERY
#                                   Swift script this machine ever runs
#   a nix store path                narrow, but the path changes on every
#                                   rebuild, so the grant dies on a routine
#                                   nightly bump
#   a stable path, compiled here    narrow AND stable; re-approve only when
#                                   observer.swift itself changes
#
# The third is the only one that is both. The cost is real and stated: the
# binary is ad-hoc signed (`Identifier=focus-observer`, `TeamIdentifier=not
# set`), so TCC keys it by path and cdhash and the grant needs renewing when
# the source changes — a few times a year. A Developer ID signature would
# remove even that, and is the upgrade path if this ever leaves this machine.
#
# Compilation happens at ACTIVATION, guarded by the source hash, because a
# recompile changes the cdhash and therefore revokes the grant. Rebuilding on
# every switch would mean re-approving on every switch.
#
# `/usr/bin/swiftc` is the same absolute-system-path dependency this tree
# already takes on /usr/bin/lsappinfo, /usr/sbin/ioreg, /usr/bin/curl and
# /usr/bin/awk. Without the Command Line Tools the agent falls back to
# interpreting the source, which still gives app-level spans.
#
# ── the tabs (Chrome extension)
# focus-observer: tabs — the browser half of the focus stack.
#
# The observer says Chrome had the screen, and with Accessibility it
# says which window. Neither can say which TAB: a browser window's AX title IS
# the active tab's title, so it changes without a window change and the
# interval boundaries land in the wrong places. Only the browser knows when a
# tab became active.
#
# THIS IS WHY AN EXTENSION AND NOT A PROXY. A proxy would need a CA in the
# trust store to see URLs at all — a private key that decrypts every TLS
# connection on the machine — and would still see only REQUESTS, having to
# guess which of a page's hundred requests was the one being looked at. The
# extension is both narrower and more accurate. The proxy's real niche is the
# opposite case: native apps that no extension can reach.
#
# Origin and pathname are recorded; query strings and fragments are not. The
# reasoning is beside the code in extension/background.js, and it
# is the same line the Swift observer draws at window titles versus element
# values.
#
# ── Loading it is manual, once, and that is not a gap in this module
#
# Chrome installs unpacked extensions only through chrome://extensions with
# Developer Mode on. The policy route (`ExtensionInstallForcelist`,
# `ExtensionSettings`) needs a hosted CRX and an update URL, and the mandatory
# form of Chrome policy needs a profile in /Library/Managed Preferences — i.e.
# MDM enrolment, which this module does not assume.
#
# So this module's job is to put the extension at a STABLE, DECLARED path and
# keep it current. The one-time load is a click:
#
#   chrome://extensions → Developer mode → Load unpacked →
#   ~/.local/state/chrome-focus/extension
#
# Chrome remembers it across restarts and picks up file changes on reload.
#
# ── the app sampler
# The app-attention sampler: which application actually had the screen.
#
# A terminal-session sampler knows which session is attached and for how long,
# but not whether those minutes went to the terminal, a browser or a chat
# client, so "40 minutes attached" cannot separate working from watching. This
# is that missing axis. A bundle id joins to a signed-app inventory: it
# resolves to an App, and an App carries its Apple-validated signer.
#
# `lsappinfo`, NOT the Accessibility API, and that is the whole design.
#
# The obvious routes — AppleScript against System Events, or an accessibility
# automation tool — both require the Accessibility permission: a broad grant
# that lets a process read and drive EVERY window on the machine. A sampler
# running once a minute forever is exactly the wrong thing to hold that with.
#
# `lsappinfo front` needs none of it. It reads the frontmost application's
# bundle id from Launch Services, which is precisely and only the fact wanted
# here. The narrower capability is the point: this agent can learn which app is
# in front and nothing else, by construction rather than by restraint.
#
# What it records is a bundle id, a display name, a timestamp, and seconds
# since the last input. NOT window titles — a title carries document names,
# subject lines and URLs, which is content, and the same line every other
# ingester on this machine holds.
#
# The idle reading is what separates "this app was frontmost" from "someone
# was here" — see the comment at the printf. It is a DURATION, not an event
# log: how long since any input, never which key or where the pointer went.
let
  cfg = config.programs.focusObserver;
  foStateDir = "${config.xdg.stateHome}/focus-observer";
  binDir = "${foStateDir}/bin";
  bin = "${binDir}/focus-observer";

  src = pkgs.runCommand "focus-observer-src" { } ''
    mkdir -p $out
    cp ${../src/observer.swift} $out/observer.swift
  '';

  runner = pkgs.writeShellScript "focus-observer" ''
    set -uo pipefail

    BIN=${lib.escapeShellArg bin}
    MARK=${lib.escapeShellArg "${binDir}/.prompted"}

    if [ -x "$BIN" ]; then
      # First launch of a NEW build asks for Accessibility once. The dialog is
      # what puts a process into the Accessibility list at all — a program
      # that only calls AXIsProcessTrusted never appears there, so without
      # this there is no way to grant the permission.
      #
      # The marker is cleared by the activation script whenever it rebuilds
      # the binary, which is exactly when the ad-hoc signature changed and the
      # grant needs renewing. So: one prompt per build, never per restart.
      if [ ! -f "$MARK" ]; then
        export FOCUS_OBSERVER_PROMPT=1
        touch "$MARK" 2>/dev/null || true
      fi
      exec "$BIN"
    fi

    # No compiled binary — the Command Line Tools are missing, or activation
    # has not run since this module landed. Interpreting the source still
    # gives app-level spans; it just cannot hold a narrow Accessibility grant,
    # because the executable is then swift-frontend.
    if [ ! -x /usr/bin/swift ]; then
      echo "focus-observer: no /usr/bin/swift (Command Line Tools not installed)" >&2
      exit 0
    fi
    echo "focus-observer: no compiled binary; interpreting (app spans only)" >&2
    exec /usr/bin/swift ${src}/observer.swift
  '';
  cfStateDir = "${config.xdg.stateHome}/chrome-focus";
  extDir = "${cfStateDir}/extension";

  extension = pkgs.runCommand "chrome-focus-extension" { } ''
    mkdir -p $out
    cp ${../extension/manifest.json} $out/manifest.json
    cp ${../extension/background.js} $out/background.js
  '';
  aaStateDir = "${config.xdg.stateHome}/app-attention";

  sampler = pkgs.writeShellScript "app-attention-sampler" ''
    # Not `set -e`: a login window, a fast app switch, or Launch Services
    # mid-restart is a SKIPPED SAMPLE, not a failure worth a red agent — the
    # same contract attention.nix's poller follows.
    set -uo pipefail

    STATE=${lib.escapeShellArg aaStateDir}
    mkdir -p "$STATE"
    LOG="$STATE/log.jsonl"

    front=$(/usr/bin/lsappinfo front 2>/dev/null) || exit 0
    [ -n "$front" ] || exit 0

    # `lsappinfo info -only` prints `"key"="value"`; take the value.
    bundle=$(/usr/bin/lsappinfo info -only bundleid "$front" 2>/dev/null \
      | sed 's/.*="\(.*\)"/\1/')
    name=$(/usr/bin/lsappinfo info -only name "$front" 2>/dev/null \
      | sed 's/.*="\(.*\)"/\1/')

    # No bundle id means nothing joinable — a screensaver, the login window, a
    # process Launch Services has not registered. Writing an empty row would
    # put a vertex-shaped hole in the log.
    [ -n "$bundle" ] || exit 0

    # Seconds since the last keyboard or trackpad input.
    #
    # FRONTMOST IS NOT ATTENTION. Everything above answers just as confidently
    # when the screen is locked, when the lid is shut on a machine that stayed
    # awake, or when everyone went to lunch — so an app left open across a
    # two-hour meeting scored two hours of use, and nothing downstream could
    # tell that from two hours of work.
    #
    # HIDIdleTime is nanoseconds, and it needs NO PERMISSION — which is the
    # same reason `lsappinfo` was chosen over the Accessibility API at the top
    # of this file. The narrowest capability that answers the question.
    #
    # A MISSING READING IS LEFT MISSING rather than defaulted. The ingester
    # reports null for a bucket with no idle coverage, because a 0 here would
    # assert "definitely at the machine" — a claim nothing observed.
    idle=$(/usr/sbin/ioreg -c IOHIDSystem 2>/dev/null \
      | /usr/bin/awk '/HIDIdleTime/ {gsub(/[^0-9]/,"",$NF); print int($NF/1000000000); exit}')

    if [ -n "$idle" ]; then
      printf '{"ts":%s,"bundleId":"%s","name":"%s","idle":%s}\n' \
        "$(date +%s)" "$bundle" "''${name//\"/}" "$idle" >> "$LOG"
    else
      printf '{"ts":%s,"bundleId":"%s","name":"%s"}\n' \
        "$(date +%s)" "$bundle" "''${name//\"/}" >> "$LOG"
    fi

    # Bound the log. At one sample a minute this is ~1,440 lines a day, and the
    # ingester aggregates to 15-minute buckets anyway — so a week of raw
    # samples is far more than anything reads.
    if [ "$(wc -l < "$LOG")" -gt 20000 ]; then
      tail -n 10000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
  '';
in
{
  options.programs.focusObserver = {
    enable = lib.mkEnableOption "the focus-observer LaunchAgent (app and window focus intervals as OTLP spans)";
    tabs.enable = lib.mkEnableOption "the chrome-focus extension, copied to ~/.local/state/chrome-focus/extension for a one-time Load unpacked";
    appSampler.enable = lib.mkEnableOption "the app-attention sampler (frontmost app + idle seconds once a minute, as JSONL)";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      launchd.agents.focus-observer = {
        enable = true;
        config = {
          ProgramArguments = [ "${runner}" ];
          # Resident, unlike every other witness here — that is what subscribing
          # buys and what it costs. It holds one open app interval, one open
          # window interval, and nothing else.
          RunAtLoad = true;
          # ONLY ON FAILURE, which makes three cases come out right with one
          # setting: a missing Swift exits 0 and stays stopped, a SIGTERM at
          # logout exits 0 after flushing and stays stopped, and a genuine crash
          # exits nonzero and comes back.
          KeepAlive = { SuccessfulExit = false; };
          # Bounds a crash loop to one restart every 30s if the above is ever
          # wrong about which exits are clean.
          ThrottleInterval = 30;
          # Two lines a lifetime: one at startup, one at shutdown carrying
          # emitted/dropped counts. Not a data path — the spans go to the
          # collector.
          StandardOutPath = "${foStateDir}/agent.log";
          StandardErrorPath = "${foStateDir}/agent.log";
        };
      };

      home.activation.focusObserverBuild =
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg binDir}

          # Keyed on the SOURCE hash, not on whether the binary exists. Compiling
          # unconditionally would give a new cdhash every switch and revoke the
          # Accessibility grant every switch.
          hash=$(/usr/bin/shasum -a 256 ${src}/observer.swift | cut -d' ' -f1)
          stamp=${lib.escapeShellArg binDir}/.src-$hash

          # The stamp alone is not enough, and the gap was not hypothetical: it
          # records only that the SOURCE is unchanged, so when the build recipe
          # itself was fixed (home#97, the `.new` suffix leaking into the signed
          # identifier) the stamp still matched and the wrong binary stayed
          # installed. The recipe is not in the stamp and cannot easily be —
          # hashing the nix expression would rebuild on every unrelated switch and
          # revoke the grant each time.
          #
          # So the freshness check asserts the PROPERTY instead of a proxy for it:
          # the installed binary must actually carry the identity TCC will key the
          # grant on. Any future build bug that changes that identity self-heals.
          need=1
          if [ -f "$stamp" ] && [ -x ${lib.escapeShellArg bin} ]; then
            id=$(/usr/bin/codesign -dvvv ${lib.escapeShellArg bin} 2>&1 \
              | /usr/bin/awk -F= '/^Identifier=/{print $2}')
            [ "$id" = "focus-observer" ] && need=0
          fi

          if [ "$need" = "1" ] && [ -x /usr/bin/swiftc ]; then
            # Built in a TEMP DIRECTORY under the real name, never as
            # `focus-observer.new`. swiftc derives the ad-hoc signature's
            # identifier from the output FILENAME, so compiling to a `.new` suffix
            # and renaming afterwards produced `Identifier=focus-observer.new` —
            # a binary whose signed identity did not match the program. TCC reads
            # that identity.
            work=$(mktemp -d)
            if $DRY_RUN_CMD /usr/bin/swiftc -O -o "$work/focus-observer" \
                 ${src}/observer.swift 2>${lib.escapeShellArg "${foStateDir}/build.log"}; then
              $DRY_RUN_CMD mv "$work/focus-observer" ${lib.escapeShellArg bin}
              # A new binary is a new cdhash, so the old grant no longer applies.
              # Dropping the marker makes the next launch ask again, which is the
              # only way back into the Accessibility list.
              $DRY_RUN_CMD rm -f ${lib.escapeShellArg binDir}/.src-* \
                                 ${lib.escapeShellArg "${binDir}/.prompted"}
              $DRY_RUN_CMD touch "$stamp"
              echo "focus-observer: rebuilt — re-approve it in System Settings > Privacy & Security > Accessibility"
              $DRY_RUN_CMD rm -rf "$work"
            else
              $DRY_RUN_CMD rm -rf "$work"
              # A failed compile must not fail the switch. The agent falls back to
              # interpreting the source and keeps emitting app-level spans.
              echo "focus-observer: swiftc failed, see ${foStateDir}/build.log; falling back to interpreted"
            fi
          fi
        '';
    })
    (lib.mkIf cfg.tabs.enable {
      # COPIED, not symlinked. Chrome resolves an unpacked extension's directory
      # and reads it on every load; a symlink into /nix/store would pin the
      # extension to one store path, so the next rebuild would leave Chrome
      # pointing at a garbage-collected directory and silently disable it.
      home.activation.chromeFocusExtension =
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg extDir}
          $DRY_RUN_CMD cp -f ${extension}/manifest.json ${extension}/background.js \
            ${lib.escapeShellArg extDir}/
          $DRY_RUN_CMD chmod u+w ${lib.escapeShellArg extDir}/manifest.json \
                                 ${lib.escapeShellArg extDir}/background.js
        '';
    })
    (lib.mkIf cfg.appSampler.enable {
      launchd.agents.app-attention = {
        enable = true;
        config = {
          ProgramArguments = [ "${sampler}" ];
          # Once a minute, so it lines up sample for sample with other
          # once-a-minute samplers and a join needs no interpolation.
          StartInterval = 60;
          RunAtLoad = true;
          # The sampler writes its own JSONL; stdout is only ever an error.
          StandardErrorPath = "${aaStateDir}/agent.log";
        };
      };

      home.activation.appAttentionStateDir =
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg aaStateDir}
        '';
    })
  ];
}
