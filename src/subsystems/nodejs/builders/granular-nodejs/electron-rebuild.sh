
# prepare node headers for electron
if [ -n "$electronPackage" ]; then
    export electronDist="$electronPackage/lib/electron"
else
    export electronDist="$nodeModules/$packageName/node_modules/electron/dist"
fi
local ver
ver="v$(cat $electronDist/version | tr -d '\n')"
mkdir $TMP/$ver
cp $electronHeaders $TMP/$ver/node-$ver-headers.tar.gz

# calc checksums
cd $TMP/$ver
sha256sum ./* > SHASUMS256.txt
cd -

# serve headers via http
python -m http.server 45034 --directory $TMP &

# copy electron distribution
cp -r $electronDist $TMP/electron
chmod -R +w $TMP/electron

# configure electron toolchain
${pkgs.jq}/bin/jq ".build.electronDist = \"$TMP/electron\"" package.json \
    | ${pkgs.moreutils}/bin/sponge package.json

${pkgs.jq}/bin/jq ".build.linux.target = \"dir\"" package.json \
    | ${pkgs.moreutils}/bin/sponge package.json

${pkgs.jq}/bin/jq ".build.npmRebuild = false" package.json \
    | ${pkgs.moreutils}/bin/sponge package.json

# execute electron-rebuild if available
export headers=http://localhost:45034/
if command -v electron-rebuild &> /dev/null; then
    pushd $electronAppDir

    electron-rebuild -d $headers
    popd
fi
