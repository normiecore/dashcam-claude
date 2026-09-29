#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/portable
compiler="${CC:-cc}"
flags=(-std=c11 -Wall -Wextra -Werror -Wconversion -pedantic -I Core)
"$compiler" "${flags[@]}" -O2 Core/RetentionPolicy.c Tests/RetentionPolicyTests.c -lm -o .build/portable/policy-tests
.build/portable/policy-tests
"$compiler" "${flags[@]}" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer Core/RetentionPolicy.c Tests/RetentionPolicyTests.c -lm -o .build/portable/policy-tests-sanitized
# The production policy allocates no memory. LeakSanitizer cannot inspect /proc
# in the hosted runner; address and undefined-behavior instrumentation remain on.
ASAN_OPTIONS=detect_leaks=0 .build/portable/policy-tests-sanitized
if [[ "$(uname -s)" == "Darwin" ]]; then
  "$compiler" "${flags[@]}" -dynamiclib Core/RetentionPolicy.c -o .build/portable/libretention.dylib
else
  "$compiler" "${flags[@]}" -shared -fPIC Core/RetentionPolicy.c -o .build/portable/libretention.so
fi
python3 Tools/simulate.py
