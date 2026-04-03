{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  python3,
  node-gyp,
}:

buildNpmPackage rec {
  pname = "node-pty";
  version = "1.1.0";

  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "node-pty";
    rev = "v${version}";
    hash = "sha256-R0QxTw3tNJvW4aEi+GOF0iZhGgI42HTYJih90CdF18I=";
  };

  npmDepsHash = "sha256-HRv/4NO7CHkPs7ld8lx61n2cty0EhmWVrpH/1Vqh+Nk=";

  nativeBuildInputs = [ python3 node-gyp ];

  # fsevents is macOS-only; strip it from the lockfile to avoid sync errors
  postPatch = ''
    sed -i '/"fsevents"/d' package-lock.json
  '';

  buildPhase = ''
    runHook preBuild
    npm run build
    node-gyp rebuild
    runHook postBuild
  '';

  postInstall = ''
    cp -r build $out/lib/node_modules/node-pty/
  '';

  meta = with lib; {
    description = "Fork pseudoterminals in Node.JS";
    homepage = "https://github.com/microsoft/node-pty";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
