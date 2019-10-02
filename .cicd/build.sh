#!/bin/bash
set -eo pipefail
. ./.cicd/helpers/general.sh
mkdir -p $BUILD_DIR
CMAKE_EXTRAS="-DCMAKE_BUILD_TYPE='Release' -DCORE_SYMBOL_NAME='SYS'"
if [[ $(uname) == 'Darwin' ]]; then
    # You can't use chained commands in execute
    [[ $TRAVIS == true ]] && export PINNED=false && ccache -s && CMAKE_EXTRAS="-DCMAKE_CXX_COMPILER_LAUNCHER=ccache" && ./$CICD_DIR/platforms/macos-10.14.sh
    ( [[ ! $PINNED == false || $UNPINNED == true ]] ) && CMAKE_EXTRAS="$CMAKE_EXTRAS -DCMAKE_TOOLCHAIN_FILE=$SCRIPTS_DIR/pinned_toolchain.cmake"
    sed -n '/## Build Steps/,/make -j/p' $CONAN_DIR/MACOS-10.14.md | grep -v '```' | grep -v '\*\*' >> $CONAN_DIR/conan-build.sh
    if [[ "$USE_CONAN" == 'true' ]]; then
        bash -c "$CONAN_DIR/conan-build.sh"
    else
        cd $BUILD_DIR
        cmake $CMAKE_EXTRAS ..
        make -j$JOBS
    fi
else # Linux
    ARGS=${ARGS:-"--rm --init -v $(pwd):$MOUNTED_DIR -e UNPINNED -e PINNED -e IMAGE_TAG"}
    . $HELPERS_DIR/file-hash.sh $CICD_DIR/platforms/$BUILD_TYPE/$IMAGE_TAG.dockerfile
    PRE_COMMANDS="cd $MOUNTED_DIR/build"
    # PRE_COMMANDS: Executed pre-cmake
    # CMAKE_EXTRAS: Executed within and right before the cmake path (cmake CMAKE_EXTRAS ..)
    [[ ! $IMAGE_TAG =~ 'unpinned' && ! $IMAGE_TAG =~ 'conan' ]] && CMAKE_EXTRAS="$CMAKE_EXTRAS -DCMAKE_TOOLCHAIN_FILE=$MOUNTED_DIR/scripts/pinned_toolchain.cmake -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
    if [[ $IMAGE_TAG == 'amazon_linux-2' ]]; then
        PRE_COMMANDS="$PRE_COMMANDS && export PATH=/usr/lib64/ccache:\\\$PATH"
    elif [[ $IMAGE_TAG == 'centos-7.6' ]]; then
        PRE_COMMANDS="$PRE_COMMANDS && source /opt/rh/rh-python36/enable && export PATH=/usr/lib64/ccache:\\\$PATH"
    elif [[ $IMAGE_TAG == 'ubuntu-16.04' ]]; then
        PRE_COMMANDS="$PRE_COMMANDS && export PATH=/usr/lib/ccache:\\\$PATH"
    elif [[ $IMAGE_TAG == 'ubuntu-18.04' ]]; then
        PRE_COMMANDS="$PRE_COMMANDS && export PATH=/usr/lib/ccache:\\\$PATH"
    elif [[ $IMAGE_TAG == 'amazon_linux-2-unpinned' ]]; then
        PRE_COMMANDS="$PRE_COMMANDS && export PATH=/usr/lib64/ccache:\\\$PATH"
        CMAKE_EXTRAS="$CMAKE_EXTRAS -DCMAKE_CXX_COMPILER='clang++' -DCMAKE_C_COMPILER='clang'"
    elif [[ $IMAGE_TAG == 'centos-7.6-unpinned' ]]; then
        CMAKE_EXTRAS="$CMAKE_EXTRAS -DLLVM_DIR='/usr/lib64/llvm7.0/lib/cmake/llvm'"
        PRE_COMMANDS="$PRE_COMMANDS && source /opt/rh/devtoolset-8/enable && source /opt/rh/rh-python36/enable && export PATH=/usr/lib64/ccache:\\\$PATH"
    elif [[ $IMAGE_TAG == 'ubuntu-18.04-unpinned' ]]; then
        PRE_COMMANDS="$PRE_COMMANDS && export PATH=/usr/lib/ccache:\\\$PATH"
        CMAKE_EXTRAS="$CMAKE_EXTRAS -DCMAKE_CXX_COMPILER='clang++' -DCMAKE_C_COMPILER='clang' -DLLVM_DIR='/usr/lib/llvm-7/lib/cmake/llvm'"
    elif [[ $IMAGE_TAG == 'amazon_linux-2-conan' ]]; then
        sed -n '/## Build Steps/,/make -j/p' $CONAN_DIR/AMAZON_LINUX-2.md | grep -v '```' | grep -v '\*\*' >> $CONAN_DIR/conan-build.sh
    elif [[ $IMAGE_TAG == 'centos-7.6-conan' ]]; then
        sed -n '/## Build Steps/,/make -j/p' $CONAN_DIR/CENTOS-7.6.md | grep -v '```' | grep -v '\*\*' >> $CONAN_DIR/conan-build.sh
    elif [[ $IMAGE_TAG == 'ubuntu-18.04-conan' ]]; then
        sed -n '/## Build Steps/,/make -j/p' $CONAN_DIR/UBUNTU-18.04.md | grep -v '```' | grep -v '\*\*' >> $CONAN_DIR/conan-build.sh
    fi
    BUILD_COMMANDS="cmake $CMAKE_EXTRAS .. && make -j$JOBS"
    # Docker Commands
    if [[ $BUILDKITE == true ]]; then
        # Generate Base Images
        $CICD_DIR/generate-base-images.sh
        [[ $ENABLE_INSTALL == true ]] && COMMANDS="cp -r $MOUNTED_DIR /root/eosio && cd /root/eosio/build &&"
        COMMANDS="$COMMANDS $BUILD_COMMANDS"
        [[ $ENABLE_INSTALL == true ]] && COMMANDS="$COMMANDS && make install"
    elif [[ $TRAVIS == true ]]; then
        ARGS="$ARGS -v /usr/lib/ccache -v $HOME/.ccache:/opt/.ccache -e JOBS -e TRAVIS -e CCACHE_DIR=/opt/.ccache"
        COMMANDS="ccache -s && $BUILD_COMMANDS"
    fi
    COMMANDS="$PRE_COMMANDS && $COMMANDS"
    [[ "$USE_CONAN" == 'true' ]] && COMMANDS="$MOUNTED_DIR/.conan/conan-build.sh"
    echo "$ docker run $ARGS $(buildkite-intrinsics) $FULL_TAG bash -c \"$COMMANDS\""
    eval docker run $ARGS $(buildkite-intrinsics) $FULL_TAG bash -c \"$COMMANDS\"
fi
