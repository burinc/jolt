{
  description = "Jolt, a Clojure implementation on Chez Scheme";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    self.submodules = true;
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      mkJolt =
        pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "jolt";
          version = self.shortRev or "dev";
          src = self;

          nativeBuildInputs = [
            pkgs.chez
            pkgs.pkg-config
            pkgs.xxd
          ];
          buildInputs = [
            pkgs.lz4
            pkgs.zlib
            pkgs.ncurses
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.libuuid ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.libiconv ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            scheme --script host/chez/build-jolt.ss release target/release/jolt
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -m755 target/release/jolt "$out/bin/jolt"
            runHook postInstall
          '';

          meta = {
            description = "Clojure implementation on Chez Scheme";
            homepage = "https://jolt-lang.net";
            license = pkgs.lib.licenses.epl20;
            mainProgram = "jolt";
          };
        };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          jolt = mkJolt pkgs;
        in
        {
          inherit jolt;
          default = jolt;
        }
      );

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.jolt}/bin/jolt";
          meta.description = "Run Jolt";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.chez
            pkgs.stdenv.cc
            pkgs.gnumake
            pkgs.pkg-config
            pkgs.xxd

            # Jolt deps.edn support
            pkgs.git
            pkgs.unzip
            pkgs.openssl

            # Chez/Jolt native-link dependencies
            pkgs.lz4
            pkgs.zlib
            pkgs.ncurses
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.libuuid ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.libiconv ];

          JOLT_CHEZ = "${pkgs.chez}/bin/scheme";
          CHEZ = "${pkgs.chez}/bin/scheme";

          shellHook = ''
            echo "Jolt development environment"
            printf 'Chez: '
            printf '(display (scheme-version)) (newline)\n' | scheme -q
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
