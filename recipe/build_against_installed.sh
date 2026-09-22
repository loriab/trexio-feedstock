#!/usr/bin/env bash

# Build the Python binding against an already-installed TREXIO library.
#
# This is intentionally independent of Autoconf, Automake, and setup.py.  It is
# suitable for a conda recipe after the C library has been installed into
# $PREFIX.  The generated TREXIO sources must already exist in the source tree
# (a release tarball has them; a developer checkout can generate them with the
# normal Org-mode/CMake developer build).
#
# Optional environment variables:
#   TREXIO_SOURCE_DIR    unpacked TREXIO source (default: $SRC_DIR or script/..)
#   TREXIO_PREFIX        C library installation prefix (default: $PREFIX)
#   TREXIO_INCLUDEDIR    directory containing trexio.h
#   TREXIO_LIBDIR        directory containing libtrexio
#   PYTHON               target Python interpreter (default: python3)
#   SWIG                 SWIG executable (default: swig)
#   CC                   C compiler (default: cc)
#   SP_DIR               installation directory used by conda-build
#   PYTHON_SITE_PACKAGES installation directory when SP_DIR is not set
#   PYTREXIO_BUILD_DIR   retain build products in this directory

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -n ${TREXIO_SOURCE_DIR:-} ]]; then
  source_dir=${TREXIO_SOURCE_DIR}
elif [[ -n ${SRC_DIR:-} ]]; then
  source_dir=${SRC_DIR}
else
  source_dir=$(cd "${script_dir}/.." && pwd)
fi

python_exe=${PYTHON:-python3}
swig_exe=${SWIG:-swig}
cc_exe=${CC:-cc}

trexio_prefix=${TREXIO_PREFIX:-${PREFIX:-}}
if [[ -z ${trexio_prefix} ]]; then
  echo "Set TREXIO_PREFIX (or PREFIX) to the installed TREXIO prefix." >&2
  exit 2
fi

trexio_includedir=${TREXIO_INCLUDEDIR:-${trexio_prefix}/include}
trexio_libdir=${TREXIO_LIBDIR:-${trexio_prefix}/lib}

if [[ -n ${SP_DIR:-} ]]; then
  site_packages=${SP_DIR}
elif [[ -n ${PYTHON_SITE_PACKAGES:-} ]]; then
  site_packages=${PYTHON_SITE_PACKAGES}
else
  site_packages=$(
    "${python_exe}" -c 'import sysconfig; print(sysconfig.get_path("platlib"))'
  )
fi

required_files=(
  "${source_dir}/src/pytrexio.i"
  "${source_dir}/src/numpy.i"
  "${source_dir}/src/trexio_s.h"
  "${source_dir}/src/trexio_private.h"
  "${source_dir}/src/trexio.py"
  "${source_dir}/python/pytrexio/__init__.py"
  "${source_dir}/python/pytrexio/_version.py"
  "${trexio_includedir}/trexio.h"
)
for required_file in "${required_files[@]}"; do
  if [[ ! -f ${required_file} ]]; then
    echo "Required generated/input file not found: ${required_file}" >&2
    exit 2
  fi
done

if [[ ! -f ${trexio_libdir}/libtrexio.so &&
      ! -f ${trexio_libdir}/libtrexio.dylib &&
      ! -f ${trexio_libdir}/libtrexio.a ]]; then
  echo "No libtrexio library found in ${trexio_libdir}" >&2
  exit 2
fi

if [[ -n ${PYTREXIO_BUILD_DIR:-} ]]; then
  build_dir=${PYTREXIO_BUILD_DIR}
  mkdir -p "${build_dir}"
else
  build_dir=$(mktemp -d "${TMPDIR:-/tmp}/pytrexio-build.XXXXXX")
  trap 'rm -rf -- "${build_dir}"' EXIT
fi
mkdir -p "${build_dir}/pytrexio"

python_include=$(
  "${python_exe}" -c 'import sysconfig; print(sysconfig.get_path("include"))'
)
numpy_include=$(
  "${python_exe}" -c 'import numpy; print(numpy.get_include())'
)
extension_suffix=$(
  "${python_exe}" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or ".so")'
)
python_platform=$("${python_exe}" -c 'import sys; print(sys.platform)')

echo "Generating the SWIG wrapper"
"${swig_exe}" \
  -python \
  -I"${source_dir}/src" \
  -I"${trexio_includedir}" \
  -outdir "${build_dir}/pytrexio" \
  -o "${build_dir}/pytrexio_wrap.c" \
  "${source_dir}/src/pytrexio.i"

echo "Compiling the Python extension"
# CPPFLAGS and CFLAGS are intentionally word-split: conda compiler activation
# supplies each as a shell-style list of compiler arguments.
# shellcheck disable=SC2086
${cc_exe} ${CPPFLAGS:-} ${CFLAGS:-} \
  -std=c99 \
  -fPIC \
  -Wno-incompatible-pointer-types \
  -Wno-unused-variable \
  -Wno-unused-but-set-variable \
  -I"${python_include}" \
  -I"${numpy_include}" \
  -I"${source_dir}/src" \
  -I"${trexio_includedir}" \
  -c "${build_dir}/pytrexio_wrap.c" \
  -o "${build_dir}/pytrexio_wrap.o"

case ${python_platform} in
  darwin)
    platform_link_flags=(
      -bundle
      -undefined dynamic_lookup
      "-Wl,-rpath,${trexio_libdir}"
    )
    ;;
  linux*)
    platform_link_flags=(
      -shared
      "-Wl,-rpath,${trexio_libdir}"
    )
    ;;
  *)
    echo "Unsupported Python platform: ${python_platform}" >&2
    exit 2
    ;;
esac

# LDFLAGS and LIBS follow the same conda convention as CPPFLAGS and CFLAGS.
# shellcheck disable=SC2086
${cc_exe} ${LDFLAGS:-} \
  "${platform_link_flags[@]}" \
  -L"${trexio_libdir}" \
  "${build_dir}/pytrexio_wrap.o" \
  -ltrexio \
  ${LIBS:-} \
  -o "${build_dir}/pytrexio/_pytrexio${extension_suffix}"

echo "Installing into ${site_packages}"
install -d "${site_packages}/pytrexio"
install -m 0644 \
  "${source_dir}/src/trexio.py" \
  "${site_packages}/trexio.py"
install -m 0644 \
  "${source_dir}/python/pytrexio/__init__.py" \
  "${source_dir}/python/pytrexio/_version.py" \
  "${build_dir}/pytrexio/pytrexio.py" \
  "${build_dir}/pytrexio/_pytrexio${extension_suffix}" \
  "${site_packages}/pytrexio/"

echo "Installed TREXIO Python binding linked against ${trexio_libdir}/libtrexio"
