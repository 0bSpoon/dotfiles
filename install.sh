#!/bin/sh

# chezmoi install script
# contains code from and inspired by
# https://github.com/client9/shlib
# https://github.com/goreleaser/godownloader

set -e

BINDIR="${BINDIR:-bin}"
TAGARG="latest"
LOG_LEVEL=2

tmpdir="$(mktemp -d)"
trap 'rm -rf -- "${tmpdir}"' EXIT
trap 'exit' INT TERM

usage() {
  this="${1}"
  cat <<EOF >&2
Usage: ${this} [options]

Options:
  -b, --bindir <dir>  Specify the directory to install chezmoi into (default: ${BINDIR})
  -t, --tag <tag>     Specify the tag to install (default: ${TAGARG})
  -v, --verbose       Increase verbosity (default: ${LOG_LEVEL})
  -h, --help          Show this help message
EOF
  return 1
}

get_libc() {
  if is_command ldd; then
    case "$(ldd --version 2>&1 | tr '[:upper:]' '[:lower:]')" in
      *glibc* | *"gnu libc"*)
        printf "glibc"
        return
        ;;
      *musl*)
        printf "musl"
        return
        ;;
    esac
  fi
  if is_command getconf; then
    case "$(getconf GNU_LIBC_VERSION 2>&1)" in
      *glibc*)
        printf "glibc"
        return
        ;;
    esac
  fi
  log_crit "unable to determine libc" >&2
  exit 1
}

real_tag() {
  tag="${1}"
  log_debug "checking GitHub for tag ${tag}"
  release_url="https://github.com/twpayne/chezmoi/releases/${tag}"
  json="$(http_get "${release_url}" "Accept: application/json")"
  if [ -z "${json}" ]; then
    log_err "real_tag error retrieving GitHub release ${tag}"
    return 1
  fi
  real_tag="$(printf '%s\n' "${json}" | tr -s '\n' ' ' | sed 's/.*"tag_name":"//' | sed 's/".*//')"
  if [ -z "${real_tag}" ]; then
    log_err "real_tag error determining real tag of GitHub release ${tag}"
    return 1
  fi
  if [ -z "${real_tag}" ]; then
    return 1
  fi
  log_debug "found tag ${real_tag} for ${tag}"
  printf '%s' "${real_tag}"
}

http_get() {
  tmpfile="$(mktemp)"
  http_download "${tmpfile}" "${1}" "${2}" || return 1
  body="$(cat "${tmpfile}")"
  rm -f "${tmpfile}"
  printf '%s\n' "${body}"
}

http_download_curl() {
  local_file="${1}"
  source_url="${2}"
  header="${3}"
  if [ -z "${header}" ]; then
    code="$(curl -w '%{http_code}' -fsSL -o "${local_file}" "${source_url}")"
  else
    code="$(curl -w '%{http_code}' -fsSL -H "${header}" -o "${local_file}" "${source_url}")"
  fi
  if [ "${code}" != "200" ]; then
    log_debug "http_download_curl received HTTP status ${code}"
    return 1
  fi
  return 0
}

http_download_wget() {
  local_file="${1}"
  source_url="${2}"
  header="${3}"
  if [ -z "${header}" ]; then
    wget -q -O "${local_file}" "${source_url}" || return 1
  else
    wget -q --header "${header}" -O "${local_file}" "${source_url}" || return 1
  fi
}

http_download() {
  log_debug "http_download ${2}"
  if is_command curl; then
    http_download_curl "${@}" || return 1
    return
  elif is_command wget; then
    http_download_wget "${@}" || return 1
    return
  fi
  log_crit "http_download unable to find wget or curl"
  return 1
}

hash_sha256() {
  target="${1}"
  if is_command sha256sum; then
    hash="$(sha256sum "${target}")" || return 1
    printf '%s' "${hash}" | cut -d ' ' -f 1
  elif is_command shasum; then
    hash="$(shasum -a 256 "${target}" 2>/dev/null)" || return 1
    printf '%s' "${hash}" | cut -d ' ' -f 1
  elif is_command sha256; then
    hash="$(sha256 -q "${target}" 2>/dev/null)" || return 1
    printf '%s' "${hash}"
  elif is_command openssl; then
    hash="$(openssl dgst -sha256 "${target}")" || return 1
    printf '%s' "${hash}" | cut -d ' ' -f 2  # Corrected field number to 2
  else
    log_crit "hash_sha256 unable to find command to compute SHA256 hash"
    return 1
  fi
}


hash_sha256_verify() {
  target="${1}"
  checksums="${2}"
  basename="${target##*/}"

  want="$(grep "${basename}" "${checksums}" 2>/dev/null | tr '\t' ' ' | cut -d ' ' -f 1)"
  if [ -z "${want}" ]; then
    log_err "hash_sha256_verify unable to find checksum for ${target} in ${checksums}"
    return 1
  fi

  got="$(hash_sha256 "${target}")"
  if [ "${want}" != "${got}" ]; then
    log_err "hash_sha256_verify checksum for ${target} did not verify ${want} vs ${got}"
    return 1
  fi
}

untar() {
  tarball="${1}"
  case "${tarball}" in
    *.tar.gz | *.tgz) tar -xzf "${tarball}" ;;
    *.tar) tar -xf "${tarball}" ;;
    *.zip) unzip -- "${tarball}" ;;
    *)
      log_err "untar unknown archive format for ${tarball}"
      return 1
      ;;
  esac
}

is_command() {
  type "${1}" >/dev/null 2>&1
}

log_debug() {
  [ 3 -le "${LOG_LEVEL}" ] || return 0
  printf 'debug %s\n' "${*}" >&2
}

log_info() {
  [ 2 -le "${LOG_LEVEL}" ] || return 0
  printf 'info %s\n' "${*}" >&2
}

log_err() {
  [ 1 -le "${LOG_LEVEL}" ] || return 0
  printf 'error %s\n' "${*}" >&2
}

log_crit() {
  [ 0 -le "${LOG_LEVEL}" ] || return 0
  printf 'critical %s\n' "${*}" >&2
}


main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -b | --bindir)
                BINDIR="$2"
                shift 2
                ;;
            -t | --tag)
                TAGARG="$2"
                shift 2
                ;;
            -v | --verbose)
                LOG_LEVEL="$2"
                shift 2
                ;;
            -h | --help)
                usage "$0"
                ;;
            *)
                usage "$0"
                ;;
        esac
    done

    # Determine the real tag if 'latest' is specified.
    if [ "$TAGARG" = "latest" ]; then
      TAGARG=$(real_tag "latest")
    fi

    # Determine OS and ARCH
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | tr '[:upper:]' '[:lower:]')

    # Handle x86_64 and aarch64
    case "$ARCH" in
      x86_64) ARCH="amd64" ;;
      aarch64) ARCH="arm64" ;;
    esac
    
    # Determine LIBC
    LIBC=$(get_libc)
    
    # Construct the URL
    DOWNLOAD_URL="https://github.com/twpayne/chezmoi/releases/download/${TAGARG}/chezmoi_${TAGARG}_${OS}_${ARCH}.tar.gz"
    CHECKSUM_URL="https://github.com/twpayne/chezmoi/releases/download/${TAGARG}/chezmoi_${TAGARG}_checksums.txt"

    log_info "Downloading from ${DOWNLOAD_URL}"
    
    # Download the tarball and checksums
    http_download "${tmpdir}/chezmoi.tar.gz" "${DOWNLOAD_URL}"
    http_download "${tmpdir}/checksums.txt" "${CHECKSUM_URL}"
    
    # Verify checksum
    hash_sha256_verify "${tmpdir}/chezmoi.tar.gz" "${tmpdir}/checksums.txt"

    # Extract
    untar "${tmpdir}/chezmoi.tar.gz" -C "${tmpdir}"

    # Install
    install -Dm755 "${tmpdir}/chezmoi" "${BINDIR}/chezmoi"
    
    log_info "chezmoi ${TAGARG} installed to ${BINDIR}/chezmoi"

}

main "${@}"