#!/usr/bin/env bash

./zig-out/bin/zig-spirv-executor $1 --platform Intel --reducing

if [ "$?" -eq 0 ]; then
    echo NOT INTERESTING
    exit 1
else
    echo INTERESTING
    exit 0
fi
