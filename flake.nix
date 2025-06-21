{
  description = "Claudia - A powerful GUI app and Toolkit for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        # Rust toolchain
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        # System dependencies for Tauri
        systemDeps = with pkgs; [
          # Core build tools
          pkg-config
          openssl
          
          # Linux-specific dependencies
          webkitgtk_4_1
          gtk3
          libayatana-appindicator
          librsvg
          patchelf
          libsoup_3
          
          # Additional dependencies
          glib-networking
          gsettings-desktop-schemas
        ] ++ lib.optionals stdenv.isLinux [
          # Linux-specific
          xdotool
        ] ++ lib.optionals stdenv.isDarwin [
          # macOS-specific
          darwin.apple_sdk.frameworks.Security
          darwin.apple_sdk.frameworks.CoreServices
          darwin.apple_sdk.frameworks.SystemConfiguration
          darwin.apple_sdk.frameworks.WebKit
        ];

        # Frontend dependencies and build using bun
        bunDeps = pkgs.stdenv.mkDerivation {
          pname = "claudia-bun-deps";
          version = "0.1.0";
          
          src = ./.;
          
          nativeBuildInputs = with pkgs; [ bun ];
          
          buildPhase = ''
            export HOME=$TMPDIR
            bun install --frozen-lockfile
          '';
          
          installPhase = ''
            mkdir -p $out
            cp -r node_modules $out/
          '';
          
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = "sha256-CxpU1XRXoM5SOOG7hKbomku7IPEGehh3O87jAaUwfSU=";
        };

        frontend = pkgs.stdenv.mkDerivation {
          pname = "claudia-frontend";
          version = "0.1.0";
          
          src = ./.;
          
          nativeBuildInputs = with pkgs; [
            bun
            nodejs
            typescript
            xvfb-run
          ];
          
          buildPhase = ''
            export HOME=$TMPDIR
            
            # Copy node_modules from deps
            cp -r ${bunDeps}/node_modules .
            chmod -R +w node_modules
            
            # Type check with system TypeScript
            tsc --noEmit
            
            # Build with vite using node directly
            xvfb-run -a node node_modules/vite/bin/vite.js build
          '';
          
          installPhase = ''
            cp -r dist $out
          '';
        };

        # Main Claudia application
        claudia = pkgs.rustPlatform.buildRustPackage {
          pname = "claudia";
          version = "0.1.0";
          
          src = ./src-tauri;
          
          # This will be updated with the correct hash after first build  
          cargoHash = "sha256-r26G5I4SP2iXYpNvrXXLj7C1ZXg6DlVZMm2n0NEHb3o=";
          
          nativeBuildInputs = with pkgs; [
            pkg-config
            rustToolchain
            bun
            nodejs
          ] ++ systemDeps;
          
          buildInputs = systemDeps;
          
          # Set environment variables for Tauri
          preBuild = ''
            export HOME=$TMPDIR
            export TAURI_BUNDLE_IDENTIFIER="claudia.asterisk.so"
            
            # Remove devUrl from tauri.conf.json for production build
            sed -i '/"devUrl":/d' tauri.conf.json
            sed -i '/"beforeDevCommand":/d' tauri.conf.json
            echo "Modified tauri.conf.json for production build"
            
            # Copy the Nix-built frontend
            cp -r ${frontend} ../dist
            echo "Using Nix-built frontend"
          '';
          
          # Skip tests that require a display
          doCheck = false;
          
          # Install the built application
          postInstall = ''
            # The binary should be built by cargo
            if [ -f target/release/claudia ]; then
              install -Dm755 target/release/claudia $out/bin/claudia
            fi
          '';
          
          meta = with pkgs.lib; {
            description = "A powerful GUI app and Toolkit for Claude Code";
            homepage = "https://github.com/getAsterisk/claudia";
            license = licenses.mit;
            maintainers = [ ];
            platforms = platforms.linux ++ platforms.darwin;
          };
        };

      in
      {
        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Rust toolchain
            rustToolchain
            
            # Frontend tools
            bun
            nodejs
            
            # Tauri CLI
            cargo-tauri
            
            # System dependencies
          ] ++ systemDeps ++ [
            # Development tools
            rust-analyzer
            clippy
            rustfmt
            
            # Additional dev tools
            git
            
            # For debugging
            gdb
            lldb
          ];
          
          # Environment variables
          shellHook = ''
            export RUST_SRC_PATH="${rustToolchain}/lib/rustlib/src/rust/library"
            export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig:${pkgs.libsoup_3.dev}/lib/pkgconfig"
            
            # Linux-specific environment setup
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath systemDeps}:$LD_LIBRARY_PATH"
              export XDG_DATA_DIRS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS"
            ''}
            
            echo "Claudia development environment loaded!"
            echo "Available commands:"
            echo "  bun install          - Install frontend dependencies"
            echo "  bun run dev          - Start frontend dev server"
            echo "  bun run build        - Build frontend"
            echo "  cargo tauri dev      - Start Tauri development"
            echo "  cargo tauri build    - Build Tauri application"
          '';
        };
        
        # Packages
        packages = {
          default = claudia;
          claudia = claudia;
          frontend = frontend;
        };
        
        # Apps
        apps.default = flake-utils.lib.mkApp {
          drv = claudia;
        };
        
        # Formatter
        formatter = pkgs.nixpkgs-fmt;
      });
}