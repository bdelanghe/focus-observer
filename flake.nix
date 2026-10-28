{
  description = "focus-observer: which app, window and browser tab had the screen on macOS (focus intervals as OTLP spans, a Chrome extension, an lsappinfo sampler), as a Home Manager module";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    # Only for the module-eval check; consumers already carry home-manager and should `follows` it.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      lib = nixpkgs.lib;
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAll = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      homeManagerModules.default = import ./nix/module.nix;

      checks = forAll (pkgs:
        {
          # The extension parses, posts only to the local collector, and records no query string or fragment.
          extension = pkgs.runCommand "focus-observer-extension" { nativeBuildInputs = [ pkgs.nodejs pkgs.jq ]; } ''
            node --check ${./extension/background.js}
            jq -e '.manifest_version == 3 and (.host_permissions == ["http://127.0.0.1:4318/*"])' ${./extension/manifest.json}
            grep -q 'const OTLP = "http://127.0.0.1:4318/v1/traces"' ${./extension/background.js}
            grep -q 'url: u.origin + u.pathname,' ${./extension/background.js}
            touch $out
          '';
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          # Under Home Manager: nothing by default; each part emits exactly its own agent / activation step.
          module-eval =
            let
              hm = extra: (home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [ self.homeManagerModules.default { home = { username = "t"; homeDirectory = "/Users/t"; stateVersion = "24.11"; }; } extra ];
              }).config;
              on = hm { programs.focusObserver = { enable = true; tabs.enable = true; appSampler.enable = true; }; };
              off = hm { };
              enabled = c: lib.filter (n: c.launchd.agents.${n}.enable) (lib.attrNames c.launchd.agents);
            in
            assert enabled off == [ ];
            assert !(off.home.activation ? focusObserverBuild || off.home.activation ? chromeFocusExtension || off.home.activation ? appAttentionStateDir);
            assert lib.sort lib.lessThan (enabled on) == [ "app-attention" "focus-observer" ];
            assert on.home.activation ? focusObserverBuild && on.home.activation ? chromeFocusExtension && on.home.activation ? appAttentionStateDir;
            assert on.launchd.agents.focus-observer.config.KeepAlive.SuccessfulExit == false;
            assert on.launchd.agents.app-attention.config.StartInterval == 60;
            pkgs.runCommand "focus-observer-module-eval" { } ''
              ${pkgs.bash}/bin/bash -n ${builtins.head on.launchd.agents.focus-observer.config.ProgramArguments}
              ${pkgs.bash}/bin/bash -n ${builtins.head on.launchd.agents.app-attention.config.ProgramArguments}
              touch $out
            '';
        });
    };
}
