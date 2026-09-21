{
  description = "";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      systems,
      ...
    }:
    let
      images = import ./images-lock.nix;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      flake.containersImages = nixpkgs.lib.genAttrs (import systems) (s: images.${s} or null);

      perSystem =
        {
          pkgs,
          system,
          lib,
          ...
        }:
        let
          deps = with pkgs; [
            jq
            skopeo
            nix
          ];

          wrap =
            {
              paths ? [ ],
              vars ? { },
              file ? null,
              script ? null,
              name ? "wrap",
            }:
            assert file != null || script != null || abort "wrap needs 'file' or 'script' argument";
            let
              set =
                n: v:
                "--set ${lib.escapeShellArg (lib.escapeShellArg n)} "
                + "'\"'${lib.escapeShellArg (lib.escapeShellArg v)}'\"'";
              args = (map (p: "--prefix PATH : ${p}/bin") paths) ++ (lib.attrValues (lib.mapAttrs set vars));
            in
            pkgs.runCommand name
              {
                f = if file == null then pkgs.writeScript name script else file;
                buildInputs = [ pkgs.makeWrapper ];
              }
              ''
                makeWrapper "$f" "$out" ${toString args}
              '';
        in
        {
          apps.build-images-lock = {
            type = "app";
            program =
              (wrap {
                name = "build-images-lock";
                paths = deps;
                file = ./build-images-lock.sh;
              }).outPath;
          };

          devShells.default = pkgs.mkShell { packages = deps; };

          checks = lib.optionalAttrs (system == "x86_64-linux") (
            let
              entries = images."${system}" or { };
              mkCheck =
                imageRef: entry:
                let
                  imageName = lib.head (lib.splitString ":" imageRef);
                  finalImageTag = lib.last (lib.splitString ":" imageRef);
                  imageDigest = lib.last (lib.splitString "@" entry.ref);
                in
                pkgs.dockerTools.pullImage {
                  inherit imageName imageDigest finalImageTag;
                  sha256 = entry.sha256;
                  os = "linux";
                  arch = "amd64";
                };
            in
            lib.mapAttrs' (
              imageRef: entry:
              lib.nameValuePair (builtins.replaceStrings [ "/" ":" ] [ "-" "-" ] imageRef) (mkCheck imageRef entry)
            ) entries
          );

          formatter = pkgs.nixfmt;
        };
    };
}
