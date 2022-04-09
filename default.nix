{ system ? builtins.currentSystem
, inputs ? (builtins.getFlake (builtins.toString ./.)).inputs
, lib ? inputs.nixpkgs.lib
, debug ? false
}:
let
  trace = if debug then builtins.trace else (msg: value: value);

  # cf. Tweaked version of nixpkgs/maintainers/scripts/check-hydra-by-maintainer.nix
  maybeBuildable = v:
    let result = builtins.tryEval
      (
        if lib.isDerivation v then
        # Skip packages whose closure fails on evaluation.
        # This happens for pkgs like `python27Packages.djangoql`
        # that have disabled Python pkgs as dependencies.
          builtins.seq v.outPath [ v ]
        else [ ]
      );
    in if result.success then result.value else [ ];

  isUnfreeRedistributable = licenses:
    lib.lists.any (l: (!l.free or true) && (l.redistributable or false)) licenses;

  hasLicense = pkg:
    pkg ? meta.license;

  hasUnfreeRedistributableLicense = pkg:
    hasLicense pkg &&
    isUnfreeRedistributable (lib.lists.toList pkg.meta.license);

  configs = import ./configs.nix;
  nixpkgsInstances = lib.mapAttrs
    (configName: config: import inputs.nixpkgs ({ inherit system; } // config))
    configs;

  extraPackages = [
    [ "blas" ]
    [ "cudatoolkit" ]
    [ "cudnn" ]
    [ "lapack" ]
    [ "mpich" ]
    [ "nccl" ]
    [ "opencv" ]
    [ "openmpi" ]
    [ "ucx" ]
    [ "blender" ]
    [ "colmapWithCuda" ]
    [ "suitesparse" ]
    [ "cholmod-extra" ]
    [ "truecrack-cuda" ]
    [ "ethminer-cuda" ]
    [ "gpu-screen-recorder" ]
    [ "xgboost" ]
  ];

  pythonAttrs =
    let
      matrix = lib.cartesianProductOfSets
        {
          pkg = [
            "caffe"
            "chainer"
            "cupy"
            "jaxlib"
            "Keras"
            "libgpuarray"
            "mxnet"
            "opencv4"
            "pytorch"
            "pycuda"
            "pyrealsense2WithCuda"
            "torchvision"
            "TheanoWithCuda"
            "tensorflowWithCuda"
            "tensorflow-probability"

          ] ++ [
            # These need to be rebuilt because of MKL
            "numpy"
            "scipy"
          ];
          ps = [
            "python39Packages"
            "python310Packages"
          ];
        };

      mkPath = { pkg, ps }: [ ps pkg ];
    in
    builtins.map
      mkPath
      matrix;

  hasFridhPR = nixpkgs: nixpkgs.cudaPackages ? "overrideScope'";

  cudaPackages = lib.concatMap
    (cfg:
      let
        nixpkgs = nixpkgsInstances.${cfg};
        jobs = builtins.map
          (pkg: {
            inherit cfg; path = [ "cudaPackages" pkg ];
          })
          (builtins.attrNames (nixpkgs.cudaPackages));
      in
      if hasFridhPR nixpkgs then jobs else [ ]
    )
    (builtins.attrNames configs);

  checks =
    let
      matrix = lib.cartesianProductOfSets
        {
          cfg = builtins.attrNames configs;
          path = extraPackages ++ pythonAttrs;
        }
      ++ cudaPackages;
      supported = builtins.concatMap
        ({ cfg, path }:
          let
            jobName = lib.concatStringsSep "_" ([ cfg ] ++ path);
            package = lib.attrByPath path [ ] nixpkgsInstances.${cfg};
            mbSupported = maybeBuildable package;
          in
          if mbSupported == [ ]
          then [ ]
          else [{ inherit jobName; package = (builtins.head mbSupported); }])
        matrix;
      kvPairs = builtins.map
        ({ jobName, package }: lib.nameValuePair jobName package)
        supported;
    in
    lib.listToAttrs kvPairs;

  # List packages that we never want to be even marked as "broken"
  # These will be checked just for x86_64-linux and for one release of python
  neverBreak = lib.mapAttrs
    (cfgName: pkgs:
      let
        # removed packages (like cudatoolkit_6) are just aliases that `throw`:
        notRemoved = pkg: (builtins.tryEval (builtins.seq pkg true)).success;
        # used to grep things by prefixae
        # now want to keep the job list short
        # without rewriting much stuff (so keep grepping, but filter by elem)
        chosenCudaPackages = [
          "cudnn"
          "cudatoolkit"
          "cutensor"
        ];
        isCuPackage = name: package: (notRemoved package) && (builtins.elem name chosenCudaPackages);
        cuPackages = lib.filterAttrs isCuPackage pkgs;
        stablePython = "python39Packages";
        pyPackages = lib.genAttrs [
          "pytorch"
          "cupy"
          "jaxlib"
          "tensorflowWithCuda"
        ]
          (name: pkgs.${stablePython}.${name});
      in
      {
        inherit pyPackages;
      } // cuPackages)
    nixpkgsInstances;
in
{
  # Export the whole tree
  legacyPackages = nixpkgsInstances.vanilla;

  # Returns the recursive set of unfree but redistributable packages as checks
  inherit checks neverBreak;
}
