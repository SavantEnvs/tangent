#!/usr/bin/env bash
#
# mayhem/test.sh — RUN google/tangent's own test suite (deps + private CPython 3.7 already built by
# mayhem/build.sh) and emit a CTRF (ctrf.io) summary. exit 0 iff failed==0. PATCH-grade oracle: a
# no-op patch that neuters the transformer breaks the suite's behavioral assertions (asserted AST /
# template-substitution / ANF / CFG results and computed gradient values), so it FAILS here
# (anti-reward-hacking).
#
# It does NOT compile — build.sh built the interpreter, installed pytest + atheris into the in-image
# site dir, and compiled the tangent_run_tests ELF wrapper. We only RUN the suite, routed through
# that compiled NON-system wrapper so the gate's sabotage check (neuter non-system binaries to
# exit(0)) actually perturbs the run (the private /opt/py37 interpreter is non-system, so the neuter
# bites — the suite yields no results under sabotage and the oracle is correctly detected as
# behavioral).
#
# SCOPE: tangent's AD-by-source-transformation runs on the pinned CPython 3.7 (it is broken on 3.8+).
# We run the transformer/gradient tests that need only the pure-Python deps (gast/astor/six/numpy/
# autograd). The three TensorFlow-eager test modules (test_forward_mode, test_reverse_mode,
# test_hessian_vector_products) are EXCLUDED: they require TF 1.x's `tensorflow.contrib.eager`, a
# long-dead API unavailable on any modern/installable TensorFlow — an environment problem, not a
# behavioral gap. The remaining modules still assert the full transform pipeline (parse -> ANF ->
# CFG -> reverse AD -> template substitution -> compile) and real reverse-over-reverse gradient
# values, so they form a strong behavioral oracle.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

SRC="${SRC:-/mayhem}"
cd "$SRC"

# Put the in-image py37 site dir (atheris + pytest + deps) and the tangent source tree on PYTHONPATH.
TC=/opt/toolchains
# shellcheck disable=SC1091
[ -f "$TC/py37-env.sh" ] && source "$TC/py37-env.sh"
export PYTHONPATH="$TC/py37-site:$SRC${PYTHONPATH:+:$PYTHONPATH}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/tangent_run_tests"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing/not executable — mayhem/build.sh must build it first" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

# The behavioral suite. AST/transform modules are fast + deterministic; test_compile/
# test_optimization exercise the compile + optimization passes; a BOUNDED slice of
# test_reverse_over_reverse checks real computed gradient values without running its full
# 10k-case parametrization (keeps the build-time oracle quick + stable).
LOG="$(mktemp)"
"$RUNNER" -p no:cacheprovider -o addopts= -q --no-header \
  tests/test_template.py \
  tests/test_transformers.py \
  tests/test_anf.py \
  tests/test_cfg.py \
  tests/test_comments.py \
  tests/test_annotate.py \
  tests/test_fence.py \
  tests/test_compile.py \
  tests/test_optimization.py \
  tests/test_reverse_over_reverse.py \
  -k "unoptimized and 2.0-2.0-2.0" \
  2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Parse pytest's summary line, e.g. "123 passed, 2 skipped in 0.4s" / "1 failed, 122 passed in ...".
line="$(grep -E '^(=+ )?[0-9].*(passed|failed|error|skipped)' "$LOG" | tail -1)"
get() { echo "$line" | grep -oE "[0-9]+ $1" | grep -oE '^[0-9]+' | head -1; }
passed="$(get passed)";  passed="${passed:-0}"
failed="$(get failed)";  failed="${failed:-0}"
errors="$(get error)";   errors="${errors:-0}"
skipped="$(get skipped)"; skipped="${skipped:-0}"
rm -f "$LOG"

# pytest errors (collection/setup) count as failures for the oracle.
failed=$(( failed + errors ))

# If pytest itself could not run (rc!=0 and no parseable counts), report a failure.
if [ "$(( passed + failed + skipped ))" -eq 0 ] && [ "$rc" -ne 0 ]; then
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

emit_ctrf "pytest" "$passed" "$failed" "$skipped"
