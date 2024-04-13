#!/usr/bin/env bash

./zig-out/bin/zig-spirv-test-executor $1 --platform ${REDUCE_PLATFORM:-Intel} --reducing

if [ "$?" -eq 0 ]; then
    echo NOT INTERESTING
    exit 1
else
    echo INTERESTING
    exit 0
fi
