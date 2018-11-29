# To pin to a specific version of nixpkgs, you can substitute <nixpkgs> with:
# `(builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/<nixpkgs_commit_hash>.tar.gz")`
{ compiler ? "ghc844"
, rev ? "7b54e50c085501c995e38130eb6f5e3b7a8c2523"
, sha ? "1l3083b0fjhnx5lq89bxjvimp0ax4j8shra2z3h6xnp0bd2rjgvv"
, pkgs ? import (builtins.fetchTarball {
                   url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
                   sha256 = sha; }) {
    config.allowUnfree = true;
  }
}:
  pkgs.haskell.packages.${compiler}.developPackage {
    name = "chainweb";
    root = builtins.filterSource
      (path: type: !(builtins.elem (baseNameOf path) ["result" "dist" "dist-newstyle" ".git" ".stack-work"]))
      ./.;
    overrides = self: super: with pkgs.haskell.lib; {
      # Don't run a package's test suite
      # foo = dontCheck super.chainweb;
      #
      # Don't enforce package's version constraints
      # bar = doJailbreak super.bar;
      #
      # To discover more functions that can be used to modify haskell
      # packages, run "nix repl", type "pkgs = import <nixpkgs> {}", hit
      # enter, then type "pkgs.haskell.lib.", then hit <TAB> to get a
      # tab-completed list of functions.
      configuration-tools = dontCheck super.configuration-tools;
    };
    source-overrides = {
      # Use a specific hackage version (if nixpkgs knows about it)
      # foo = "0.11.3.1";
      configuration-tools = "0.4.0";
      aeson = "1.4.0.0";

      # streaming >=0.2.2 is on Hackage, but nix doesn't know how get it from there
      streaming = pkgs.fetchFromGitHub {
        owner = "haskell-streaming";
        repo = "streaming";
        rev = "cf4ae245a0c31432776c9ae6c11312c25a8c6c88";
        sha256 = "1b8m1ia2qp3rh09cyacsx9cjb20hdk7vlylc166wmnpwl46g4dvx";
      };

      # Use a particular commit from github
      refined = pkgs.fetchFromGitHub {
        owner = "nikita-volkov";
        repo = "refined";
        rev = "cd3d99a6a9dff6adfc6dfceb06697ae56261ea6d";
        sha256 = "0ihgr7ldqjx7f3nzpf7g587s0i9acix9xwm9wwp0v6rs4jcdbbm7";
      };

      yet-another-logger = pkgs.fetchFromGitHub {
        owner = "alephcloud";
        repo = "hs-yet-another-logger";
        rev = "5706c1bb57e18f2793da21808868d947f74005f0";
        sha256 = "1lkg6p8s3j48q6cq27k9sldd1f8aqd6b77rsa0vbbzsi69idqb17";
      };
    };
  }