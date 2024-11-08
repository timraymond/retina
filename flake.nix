{
  description = "A simple Go package";

  # Nixpkgs / NixOS version to use.
  inputs.nixpkgs.url = "nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs }:
    let

      # to work with older version of flakes
      lastModifiedDate = self.lastModifiedDate or self.lastModified or "19700101";

      # Generate a user-friendly version number.
      version = builtins.substring 0 8 lastModifiedDate;

      # System types to support.
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Nixpkgs instantiated for supported system types.
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });

    in
    {

      # Provide some binary packages for selected system types.
      packages = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
          bpf2go = pkgs.buildGoModule {
            pname = "bpf2go";
            version = "latest";

            src = pkgs.fetchFromGitHub {
              owner = "cilium";
              repo = "ebpf";
              rev = "v0.16.0";
              sha256 = "sha256-8WUmFbXOZuMex1R6X00DUzEe0QO0KRdsKxA0AJ7WfNw=";
            };

            vendorHash = "sha256-b4bd7K7e7YIpFma2zkRzQe3VO8UUuaoQqlS5G2t6qFE=";

            buildPhase = "go install ./cmd/bpf2go";
          };
        in rec {
          retina-agent = pkgs.buildGoModule {
            pname = "retina-agent";
            inherit version;
            # In 'nix develop', we don't need a copy of the source tree
            # in the Nix store.
            src = ./.;

            subPackages = [
              "./controller"
              "./init/retina"
            ];

            nativeBuildInputs = with pkgs; [
              clang
              bpftools
              libbpf
              llvm_16
              mockgen
              bpf2go
            ];

            preBuild = ''
              rm -rf ./hack/tools
              go generate -skip="mockgen" -mod=readonly -x ./pkg/plugin/...
            '';

            postInstall = ''
              mv $out/bin/controller $out/bin/retina-agent
              mv $out/bin/retina $out/bin/retina-agent-init
            '';

            checkPhase = "";

            # This hash locks the dependencies of this package. It is
            # necessary because of how Go requires network access to resolve
            # VCS.  See https://www.tweag.io/blog/2021-03-04-gomod2nix/ for
            # details. Normally one can build with a fake hash and rely on native Go
            # mechanisms to tell you what the hash should be or determine what
            # it should be "out-of-band" with other tooling (eg. gomod2nix).
            # To begin with it is recommended to set this, but one must
            # remember to bump this hash when your dependencies change.
            # vendorHash = pkgs.lib.fakeHash;

            vendorHash = "sha256-5YWM+8TpGUCW47pSa0nQiCLNoH9RRgy6bUG3py2/XB4=";
          };
          retina-agent-image = pkgs.dockerTools.buildImage {
            name = "retina-agent";

            copyToRoot = [
              retina-agent
              pkgs.clang
              pkgs.libbpf
            ];

            runAsRoot = ''
              mkdir -p /retina
              mv /bin/retina-agent /retina/controller
            '';
            config = {
              Entrypoint = [ "/retina/controller" ];
            };
          };
          retina-agent-init-image = pkgs.dockerTools.buildImage {
            name = "retina-agent-init";
            config = {
              Entrypoint = [ "${retina-agent}/bin/retina-agent-init" ];
            };
          };
        });

      # Add dependencies that are only needed for development
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [ go gopls gotools go-tools ];
          };
        });

      # The default package for 'nix build'. This makes sense if the
      # flake provides only one package or there is a clear "main"
      # package.
      defaultPackage = forAllSystems (system: self.packages.${system}.retina-agent);
    };
}
