#!/usr/bin/env zsh
set -euo pipefail

BUN_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBKIT_SRC="${BUN_DIR}/src/bun.js/WebKit"
BUILD_TYPE="${BUILD_TYPE:-Debug}"
WEBKIT_BUILD="${WEBKIT_SRC}/WebKitBuild/${BUILD_TYPE}"
CONFIGURE_ONLY="${CONFIGURE_ONLY:-0}"
OSX_DEPLOYMENT_TARGET="${OSX_DEPLOYMENT_TARGET:-11.7}"

find_icu_prefix() {
    local prefix
    for prefix in \
        "${ICU_PREFIX:-}" \
        /opt/local \
        /opt/homebrew/opt/icu4c \
        /usr/local/opt/icu4c
    do
        if [[ -n "${prefix}" && -f "${prefix}/include/unicode/uidna.h" && -d "${prefix}/lib" ]]; then
            printf '%s\n' "${prefix}"
            return 0
        fi
    done
    return 1
}

find_tool() {
    local explicit="$1"
    shift
    local candidate

    if [[ -n "${explicit}" && -x "${explicit}" ]]; then
        printf '%s\n' "${explicit}"
        return 0
    fi

    for candidate in "$@"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
        if command -v "${candidate}" >/dev/null 2>&1; then
            command -v "${candidate}"
            return 0
        fi
    done

    return 1
}

if ! ICU_PREFIX="$(find_icu_prefix)"; then
    echo "error: ICU not found. Set ICU_PREFIX or install icu4c via MacPorts/Homebrew." >&2
    exit 1
fi

if ! CC="$(find_tool "${CC:-}" /opt/local/bin/clang-mp-16 clang)"; then
    echo "error: C compiler not found. Set CC explicitly." >&2
    exit 1
fi

if ! CXX="$(find_tool "${CXX:-}" /opt/local/bin/clang++-mp-16 clang++)"; then
    echo "error: C++ compiler not found. Set CXX explicitly." >&2
    exit 1
fi

if ! AR="$(find_tool "${AR:-}" /opt/local/bin/llvm-ar-mp-16 llvm-ar ar)"; then
    echo "error: archiver not found. Set AR explicitly." >&2
    exit 1
fi

if ! NINJA_BIN="$(find_tool "${NINJA_BIN:-}" /usr/local/bin/ninja /opt/local/bin/ninja ninja ninja-build)"; then
    echo "error: ninja not found. Set NINJA_BIN explicitly." >&2
    exit 1
fi

export CC
export CXX
export AR
export ICU_INCLUDE_DIR="${ICU_PREFIX}/include"
export ICU_LIBRARY_DIR="${ICU_PREFIX}/lib"
export ICU_INCLUDE_DIRS="${ICU_PREFIX}/include"
export ICU_LIBRARY_DIRS="${ICU_PREFIX}/lib"
export CMAKE_PREFIX_PATH="${ICU_PREFIX}"
export CFLAGS="${CFLAGS:-} -DBUN_EXTERNAL_ICU=1"
export CXXFLAGS="${CXXFLAGS:-} -DBUN_EXTERNAL_ICU=1"
export PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

unset SDKROOT
unset CPATH
unset C_INCLUDE_PATH
unset CPLUS_INCLUDE_PATH
unset OBJC_INCLUDE_PATH
unset LIBRARY_PATH
unset DYLD_LIBRARY_PATH
unset DYLD_FALLBACK_LIBRARY_PATH
unset HOMEBREW_PREFIX
unset HOMEBREW_CELLAR
unset HOMEBREW_REPOSITORY

echo "=== step 1: cmake configure $(date) ==="
echo "ICU prefix: ${ICU_PREFIX}"
echo "CC: ${CC}"
echo "CXX: ${CXX}"
echo "AR: ${AR}"
echo "Ninja: ${NINJA_BIN}"
rm -rf "${WEBKIT_BUILD}"

cmake \
    -S "${WEBKIT_SRC}" \
    -B "${WEBKIT_BUILD}" \
    -DPORT:STRING="JSCOnly" \
    -DENABLE_STATIC_JSC:BOOL=ON \
    -DCMAKE_BUILD_TYPE:STRING="${BUILD_TYPE}" \
    -DUSE_THIN_ARCHIVES:BOOL=OFF \
    -DENABLE_FTL_JIT:BOOL=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON \
    -DUSE_BUN_JSC_ADDITIONS:BOOL=ON \
    -DENABLE_BUN_SKIP_FAILING_ASSERTIONS:BOOL=ON \
    -DALLOW_LINE_AND_COLUMN_NUMBER_IN_BUILTINS:BOOL=ON \
    -DPTHREAD_JIT_PERMISSIONS_API:BOOL=ON \
    -DUSE_PTHREAD_JIT_PERMISSIONS_API:BOOL=ON \
    -DENABLE_REMOTE_INSPECTOR:BOOL=ON \
    -DUSE_VISIBILITY_ATTRIBUTE:BOOL=ON \
    -DUSE_APPLE_ICU:BOOL=OFF \
    -DBUN_EXTERNAL_ICU:BOOL=ON \
    -DCMAKE_C_COMPILER:FILEPATH="${CC}" \
    -DCMAKE_CXX_COMPILER:FILEPATH="${CXX}" \
    -DCMAKE_AR:FILEPATH="${AR}" \
    -DCMAKE_C_COMPILER_AR:FILEPATH="${AR}" \
    -DCMAKE_CXX_COMPILER_AR:FILEPATH="${AR}" \
    -DCMAKE_MAKE_PROGRAM:FILEPATH="${NINJA_BIN}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING="${OSX_DEPLOYMENT_TARGET}" \
    -DCMAKE_PREFIX_PATH:PATH="${ICU_PREFIX}" \
    -DICU_ROOT:PATH="${ICU_PREFIX}" \
    -DICU_INCLUDE_DIRS:PATH="${ICU_PREFIX}/include" \
    -DICU_LIBRARY_DIRS:PATH="${ICU_PREFIX}/lib" \
    -DICU_I18N_LIBRARY_RELEASE:FILEPATH="${ICU_PREFIX}/lib/libicui18n.dylib" \
    -DICU_UC_LIBRARY_RELEASE:FILEPATH="${ICU_PREFIX}/lib/libicuuc.dylib" \
    -DICU_DATA_LIBRARY_RELEASE:FILEPATH="${ICU_PREFIX}/lib/libicudata.dylib" \
    -G Ninja

if [[ "${CONFIGURE_ONLY}" == "1" ]]; then
    echo "=== configure only; skipping build $(date) ==="
    exit 0
fi

echo "=== step 2: ninja build jsc $(date) ==="
cmake --build "${WEBKIT_BUILD}" --config "${BUILD_TYPE}" --target jsc

echo "=== done $(date) ==="
