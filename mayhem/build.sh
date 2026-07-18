#!/usr/bin/env bash
#
# mayhem/build.sh — build the google/tangent Atheris fuzz harness (target
# "fuzz-deriv") + its standalone reproducer, and prepare the project's own test
# suite. Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem.
#
# WHY a private CPython 3.7 (SPEC §6.2 items 8/9, §6.5):
#   tangent does automatic differentiation by source-code AST transformation and
#   was written against the pre-3.8 CPython AST / gast 0.2.2 layout. On the base
#   image's CPython 3.13 (or anything >= 3.8) `tangent.grad` fails immediately in
#   template substitution — the transformer is fundamentally incompatible, so the
#   fuzzer would exercise none of the real AD pipeline. We therefore build a
#   private CPython 3.7.17 under /opt/toolchains/py37 and run the harness on it.
#   Verified: grad works on 3.7 (grad of x*x = 10.0), broken on 3.8+.
#
# Must be idempotent + air-gapped on re-run:
#   1. Build CPython 3.7 ONCE into /opt/toolchains/py37 (skip if already built).
#   2. Populate an in-image wheelhouse under /opt/toolchains/py37-wheelhouse
#      (online, first build), then install atheris + the tangent runtime deps +
#      pytest OFFLINE from it into a fixed site dir on PYTHONPATH. tangent itself
#      stays the editable source tree (repo root on PYTHONPATH) so PATCH edits
#      under tangent/ take effect with no reinstall.
#   3. Compile launcher.c -> the ELF Mayhem target `fuzz-deriv` (+ `-standalone`).
#   4. Compile the pytest ELF runner wrapper `tangent_run_tests` (so the sabotage
#      oracle bites the suite even though it drives a non-system interpreter).
#
# The launcher/wrappers are thin C exec shims; we build them with $DEBUG_FLAGS
# only (DWARF < 4). Atheris instruments the tangent library itself at import.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# NB on SANITIZER_FLAGS (the base exports it as ASan+UBSan, halting): it is NOT applied here. This is
# an Atheris (Python) target — the fuzzed code is the tangent LIBRARY, which Atheris instruments at
# the Python-bytecode level (atheris.instrument_imports), not via C sanitizer flags. The only C we
# compile is the thin exec launcher + test wrapper, which contain no project logic, so sanitizing
# them would add runtime with no bug-finding value. (Same rationale as the cargo-fuzz/JVM targets,
# where instrumentation comes from the language toolchain rather than \$SANITIZER_FLAGS.)

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Toolchain prefixes at FIXED, $HOME-independent paths (SPEC §6.2 item 8) ──
TC=/opt/toolchains
PY_PREFIX="$TC/py37"                 # the private CPython 3.7 install
WHEELHOUSE="$TC/py37-wheelhouse"     # cached wheels/sdists for offline install
SITE="$TC/py37-site"                 # atheris + deps installed here (on PYTHONPATH)
PY37_SRC_CACHE="$TC/py37-src"        # cached CPython source tarball
PY_VER=3.7.17
PY_TGZ="Python-${PY_VER}.tgz"
PY_URL="https://www.python.org/ftp/python/${PY_VER}/${PY_TGZ}"

mkdir -p "$WHEELHOUSE" "$SITE" "$PY37_SRC_CACHE"

PY="$PY_PREFIX/bin/python3.7"

# 1) Build CPython 3.7 ONCE. Skip entirely if the interpreter already exists
#    (idempotent + air-gapped re-run: no network, no recompile).
if [ ! -x "$PY" ]; then
  echo ">> building CPython ${PY_VER} into $PY_PREFIX (first build, online)"
  if [ ! -f "$PY37_SRC_CACHE/$PY_TGZ" ]; then
    curl -fsSL -o "$PY37_SRC_CACHE/$PY_TGZ" "$PY_URL"
  fi
  BUILD_DIR="$(mktemp -d)"
  tar xzf "$PY37_SRC_CACHE/$PY_TGZ" -C "$BUILD_DIR"
  (
    cd "$BUILD_DIR/Python-${PY_VER}"
    # Build the interpreter with the system gcc (clang-19 is fine for atheris but
    # gcc builds vanilla CPython 3.7 most reliably). No PGO (keeps the build fast
    # + deterministic). --with-ensurepip installs pip into the private prefix.
    CC=gcc CXX=g++ ./configure --prefix="$PY_PREFIX" --with-ensurepip=install \
        >/tmp/py37-configure.log 2>&1
    make -j"$MAYHEM_JOBS" >/tmp/py37-make.log 2>&1
    make install >/tmp/py37-install.log 2>&1
  )
  rm -rf "$BUILD_DIR"
else
  echo ">> CPython already built at $PY_PREFIX — reusing (air-gapped re-run path)"
fi

"$PY" --version
"$PY" -c 'import ctypes, ssl, zlib' && echo ">> CPython 3.7 stdlib OK"

# 2a) Wheelhouse: download every dependency ONCE (online). On the air-gapped
#     re-run the directory is already populated, so pip never reaches the network.
#     atheris is an sdist for cp37 (compiled with clang against libFuzzer at
#     install time — hence CC=clang below). tangent's runtime deps are pinned to
#     the versions the transformer was written for (esp. gast==0.2.2).
PKGS=("atheris==2.3.0" "gast==0.2.2" "astor>=0.6" six future numpy autograd pytest)
need_download=0
"$PY" -c "import glob,sys; sys.exit(0 if glob.glob('$WHEELHOUSE/atheris-*') else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip install --upgrade pip setuptools wheel >/tmp/py37-pipup.log 2>&1
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}" >/tmp/py37-download.log 2>&1
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2b) Install deps OFFLINE from the wheelhouse into the fixed site dir. atheris
#     compiles from its sdist here; force clang so it links against libFuzzer.
#     --no-index + --find-links guarantees no PyPI access on the PATCH re-run.
#     Idempotent: skip once the site dir holds atheris + gast + pytest.
if "$PY" -c "import glob,sys,os; sys.exit(0 if (glob.glob('$SITE/atheris*') and glob.glob('$SITE/gast*') and glob.glob('$SITE/pytest*')) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  CC=clang CXX=clang++ "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" \
      --target "$SITE" "${PKGS[@]}"
fi

# tangent is a top-level package at the repo root, so the repo root goes on
# PYTHONPATH ahead of the site dir's copies (there is none of tangent in site).
PYRUN="$SITE:$SRC"

# Record the interpreter + PYTHONPATH for test.sh / the launcher to consume.
cat > "$TC/py37-env.sh" <<EOF
export PYTHON_BIN="$PY"
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
EOF

# Sanity: the harness imports + a real derivative must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" - <<'PY'
import os, sys, tempfile
from importlib.util import module_from_spec, spec_from_loader
import atheris, tangent  # noqa: F401


class _L:
    def __init__(self, m, s):
        self.m, self.s = m, s

    def get_source(self, m):
        if m != self.m:
            raise ImportError(m)
        return self.s


def _to_func(data):
    fn = tempfile.mktemp(suffix='.py')
    mod = os.path.splitext(os.path.basename(fn))[0]
    spec = spec_from_loader(mod, _L(mod, data), origin=fn)
    m = module_from_spec(spec)
    exec(compile(data, mode='exec', filename=fn), m.__dict__)
    sys.modules[mod] = m
    return m.f


src = 'def f(x):\n a = x * x\n b = x / a\n c = a + b\n d = a - c\n return d\n'
val = tangent.grad(_to_func(src))(5.0)
print('imports OK: tangent.grad sanity =', val)
PY

# 3) Compile the ELF launcher target + the standalone reproducer (DWARF < 4).
#    The launcher execs the private $PY on the harness; PYTHONPATH is baked as
#    ENV in the Dockerfile so the Python side finds atheris + tangent at runtime.
HARNESS="$SRC/mayhem/fuzz_deriv.py"
echo ">> compiling fuzz-deriv (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/fuzz-deriv"
# The standalone reproducer is the same launcher: libFuzzer runs a single input
# file once when the harness is given a file path (no fuzzing loop).
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/fuzz-deriv-standalone"

# 4) Compile the pytest oracle wrapper (a NON-system ELF so the sabotage check
#    can neuter it). PYTHON is the private 3.7 interpreter.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/tangent_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/fuzz-deriv" "$SRC/fuzz-deriv-standalone" "$SRC/tangent_run_tests"
