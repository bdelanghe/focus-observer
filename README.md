# focus-observer

Which app, window and browser tab had the screen on macOS, as a Home Manager module with three opt-in parts:

| option | what | output |
|---|---|---|
| `programs.focusObserver.enable` | a resident Swift observer subscribed to NSWorkspace (app focus) and AXObserver (window focus); compiled at activation to a stable path so its Accessibility grant is narrow and survives rebuilds | OTLP/HTTP spans to `127.0.0.1:4318` |
| `programs.focusObserver.tabs.enable` | a Chrome MV3 extension, copied to `~/.local/state/chrome-focus/extension` (load it once: chrome://extensions → Developer mode → Load unpacked) | OTLP spans of active-tab intervals (origin + path; never the query string or fragment) |
| `programs.focusObserver.appSampler.enable` | a once-a-minute `lsappinfo front` sampler — no Accessibility permission — with seconds since last input (`HIDIdleTime`) | `~/.local/state/app-attention/log.jsonl` |

Window titles are recorded; window contents are not. See the comments in `nix/module.nix`, `src/observer.swift`
and `extension/background.js` for where each line is drawn and why.

```nix
inputs.focus-observer = { url = "github:bdelanghe/focus-observer"; inputs.nixpkgs.follows = "nixpkgs"; inputs.home-manager.follows = "home-manager"; };
# modules = [ focus-observer.homeManagerModules.default ];
programs.focusObserver = { enable = true; tabs.enable = true; appSampler.enable = true; };
```

## Checks

`nix flake check`: the extension (parses, local collector only, no query strings), and on macOS the module under Home Manager.
