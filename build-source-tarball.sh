#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

if [ -z "${1:-}" ]; then
    echo "usage: $0 <path-to-tarball-root> [--skip-build]"
    exit 1
fi

SKIP_BUILD=0

if [ "${2:-}" == "--skip-build" ]; then
    SKIP_BUILD=1
fi

TARBALL_ROOT=$1
export FULL_TARBALL_ROOT=$(readlink -f $TARBALL_ROOT)

if [ -e "$TARBALL_ROOT" ]; then
    echo "error '$TARBALL_ROOT' exists"
fi

export SCRIPT_ROOT="$(cd -P "$( dirname "$0" )" && pwd)"
SDK_VERSION=$(cat $SCRIPT_ROOT/DotnetCLIVersion.txt)

if [ $SKIP_BUILD -ne 1 ]; then

    if [ -e "$SCRIPT_ROOT/bin" ]; then
        rm -rf "$SCRIPT_ROOT/bin"
    fi

    $SCRIPT_ROOT/clean.sh
    $SCRIPT_ROOT/build.sh /p:ArchiveDownloadedPackages=true /flp:v=detailed
fi

mkdir -p "$TARBALL_ROOT"

echo 'Copying sources to tarball...'

# Use Git to put sources in the tarball. This ensure it's fresh, without having to clean and reset
# the working dir. This helps preserve diagnostic information if the tarball build doesn't work.

# Checkout non-submodule sources into tarball.
git --work-tree="$TARBALL_ROOT" checkout HEAD -- src
# Checkout submodule sources into tarball.
git submodule foreach --quiet --recursive '
    SCRIPT_SUBMODULE_PATH="$toplevel/$path"
    TARBALL_SUBMODULE_PATH="$FULL_TARBALL_ROOT/${SCRIPT_SUBMODULE_PATH#$SCRIPT_ROOT/}"
    mkdir -p "$TARBALL_SUBMODULE_PATH"
    echo "Checking out $(pwd) => $TARBALL_SUBMODULE_PATH ..."
    if [ "$(ls -A)" = ".git" ]; then
        # Checkout fails for an empty tree. (E.g. nuget-client submodule NuGet.Build.Localization.)
        echo "  Nothing to check out from $TARBALL_SUBMODULE_PATH"
    else
        git --work-tree="$TARBALL_SUBMODULE_PATH" checkout -- .
    fi'

echo 'Copying scripts and tools to tarball...'

cp $SCRIPT_ROOT/*.proj $TARBALL_ROOT/
cp $SCRIPT_ROOT/*.props $TARBALL_ROOT/
cp $SCRIPT_ROOT/*.targets $TARBALL_ROOT/
cp $SCRIPT_ROOT/init-tools.msbuild $TARBALL_ROOT/
cp $SCRIPT_ROOT/DotnetCLIVersion.txt $TARBALL_ROOT/
cp $SCRIPT_ROOT/ProdConFeed.txt $TARBALL_ROOT/
cp $SCRIPT_ROOT/smoke-test* $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/keys $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/patches $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/scripts $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/repos $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/tools-local $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/bin/git-info $TARBALL_ROOT/

cp -r $SCRIPT_ROOT/Tools $TARBALL_ROOT/
rm -f $TARBALL_ROOT/Tools/dotnetcli/dotnet.tar
rm -f $TARBALL_ROOT/Tools/dotnetcli/sdk/$SDK_VERSION/nuGetPackagesArchive.lzma
rm -rf $TARBALL_ROOT/Tools/dotnetcli/store
rm -rf $TARBALL_ROOT/Tools/dotnetcli/additionalDeps

cp $SCRIPT_ROOT/support/tarball/build.sh $TARBALL_ROOT/build.sh

mkdir -p $TARBALL_ROOT/prebuilt/nuget-packages
find $SCRIPT_ROOT/packages -name '*.nupkg' -exec cp {} $TARBALL_ROOT/prebuilt/nuget-packages/ \;
find $SCRIPT_ROOT/bin/obj/x64/Release/nuget-packages -name '*.nupkg' -exec cp {} $TARBALL_ROOT/prebuilt/nuget-packages/ \;

echo 'Removing source-built packages from tarball prebuilts...'

for built_package in $(find $SCRIPT_ROOT/bin/obj/x64/Release/blob-feed/packages/ -name '*.nupkg' | tr '[:upper:]' '[:lower:]')
do
    if [ -e $TARBALL_ROOT/prebuilt/nuget-packages/$(basename $built_package) ]; then
        rm $TARBALL_ROOT/prebuilt/nuget-packages/$(basename $built_package)
    fi
done

if [ -z "${SOURCE_BUILD_SKIP_PREBUILT_REPORT:-}" ]; then
    echo 'Creating prebuilt package usage report...'
    (
        # Don't clean up (or ask to clean up).
        export SOURCE_BUILD_SKIP_SUBMODULE_CHECK=1
        "$SCRIPT_ROOT/build.sh" /nologo /t:ReportTarballPrebuiltUsage /p:TarballPrebuiltPackagesPath="$FULL_TARBALL_ROOT/prebuilt/nuget-packages/"
    )
fi

echo 'Recording commits for the source-build repo and all submodules, to aid in reproducibility...'

cat >$TARBALL_ROOT/source-build-info.txt << EOF
source-build:
 $(git rev-parse HEAD) . ($(git describe --always HEAD))

submodules:
$(git submodule status --recursive)
EOF

echo "Done. Tarball created: $TARBALL_ROOT"
