#!/usr/bin/env bash
set -e
cd $(dirname $(dirname "${BASH_SOURCE[0]}"))

zig_version=""
if [ -n "$1" ]; then
  zig_version="$1"
  update_repo=true

  if [ "$zig_version" == "master" ]; then
    zig_version=$(curl -fsSL https://ziglang.org/download/index.json | jq -r .master.version)
  fi
else
  zig_version=$(grep 'recommended_zig_version = "' "build.zig" | cut -d'"' -f2)
fi

case $(uname -ms) in
'Darwin x86_64')
  target='macos'
  arch='x86_64'
  ;;
'Darwin arm64')
  target='macos'
  arch='aarch64'
  ;;
'Linux aarch64' | 'Linux arm64')
  target='linux'
  arch='aarch64'
  ;;
'Linux x86_64')
  target='linux'
  arch='x86_64'
  ;;
*)
  printf "error: cannot get platform name from '%s'\n" "${unamestr}"
  exit 1
  ;;
esac

builds_url="https://ziglang.org/builds/zig-${target}-${arch}-${zig_version}.tar.xz"
release_url="https://ziglang.org/download/${zig_version}/zig-${target}-${arch}-${zig_version}.tar.xz"
urls=("${builds_url}")

if [[ "${zig_version}" != *-dev* ]]; then
  urls=("${release_url}" "${builds_url}")
fi

url="${urls[0]}"
dest="$(pwd)/.cache/zig-${zig_version}.tar.xz"
extract_at="$(pwd)/.cache/zig"

mkdir -p ".cache"

update_repo_if_needed() {
  if [ "$update_repo" == "true" ]; then
    files=(
      build.zig
      Dockerfile
      scripts/download-zig.ps1
      .github/workflows/*
    )

    zig_version_previous=$(grep 'recommended_zig_version = "' "build.zig" | cut -d'"' -f2)

    for file in ${files[@]}; do
      sed -i 's/'"${zig_version_previous}"'/'"${zig_version}"'/g' "$file"
    done

    printf "Zig was updated to ${zig_version}. Please commit new files."
  fi
  # symlink extracted zig to  extracted zig.exe
  # TODO: Workaround for https://github.com/ziglang/vscode-zig/issues/164
  ln -sf "${extract_at}/zig" "${extract_at}/zig.exe"
  chmod +x "${extract_at}/zig.exe"
}

if [ -e "${extract_at}/.version" ]; then
  if grep -q "${zig_version}" "${extract_at}/.version"; then
    update_repo_if_needed
    exit 0
  fi
fi

if [ -e "${dest}" ] && ! tar -tf "${dest}" >/dev/null 2>&1; then
  rm -f "${dest}"
fi

if ! [ -e "${dest}" ]; then
  printf -- "-- Downloading Zig v%s\n" "${zig_version}"
  downloaded_url=""

  for candidate in "${urls[@]}"; do
    printf -- "-- Trying %s\n" "${candidate}"
    if curl -f -L -o "${dest}" "${candidate}"; then
      downloaded_url="${candidate}"
      break
    fi
    rm -f "${dest}"
  done

  if [ -z "${downloaded_url}" ]; then
    printf "error: failed to download Zig v%s\n" "${zig_version}"
    exit 1
  fi

  url="${downloaded_url}"
fi

rm -rf "${extract_at}"
mkdir -p "${extract_at}"
tar -xf "${dest}" -C "${extract_at}" --strip-components=1

echo "${url}" > "${extract_at}/.version"

update_repo_if_needed
