# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — PYTHON target (google/tangent) (atheris / libFuzzer). Builds ON TOP of
# the org C/C++ base (ghcr.io/mayhemheroes/base) — the base ships clang (which links the compiled
# ELF launcher + compiles the atheris sdist) and the build-contract ENV. tangent's AD-by-AST-
# transformation only works on the pre-3.8 CPython AST, so mayhem/build.sh builds a PRIVATE
# CPython 3.7.17 under /opt/toolchains/py37 and runs the Atheris harness on it (the base's CPython
# 3.13 cannot differentiate anything with tangent — the transformer breaks in template substitution).
#
# WHY fixed /opt/toolchains/* prefixes (SPEC §6.2 items 8/9, §6.5):
#   pip's default cache/user-site live under $HOME, and the commit build and the PATCH RL re-run use
#   DIFFERENT $HOMEs. We pin the private interpreter, its wheelhouse and installed site dir at FIXED,
#   $HOME-independent paths so (a) they lock uniformly and (b) the CPython the FIRST (online) build
#   compiles + the wheelhouse it fills are found again — by the SAME absolute paths — when build.sh
#   re-runs OFFLINE at the PATCH tier (no recompile, no network).
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never an ENV (an empty value breaks clang).
ARG SOURCE_DATE_EPOCH
# Sanitizer override (the launcher is a thin exec wrapper; Atheris instruments the Python at import).
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Extra apt packages needed to compile CPython 3.7 from source (build-essential is already in the
# base; libffi/ssl/zlib headers give us _ctypes/ssl/zlib — atheris + pip need them). Re-pin the apt
# sources to SOURCE_DATE_EPOCH first for reproducibility when it is set.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      libffi-dev libssl-dev zlib1g-dev libbz2-dev liblzma-dev libsqlite3-dev libreadline-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Toolchain caches at FIXED, lockable, $HOME-independent prefixes ─────
# The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): they must build/read the
# private interpreter and read/refresh the wheelhouse + site dir, so hand /opt/toolchains to 2000.
# PYTHONPATH is baked as ENV so the fuzz target's exec'd python3.7 (and test.sh) find atheris +
# tangent at run time; it points at the py37 site dir + the repo source root.
ENV PYTHONPATH=/opt/toolchains/py37-site:/mayhem \
    PYTHONDONTWRITEBYTECODE=1
RUN install -d -o 2000 -g 2000 /opt/toolchains
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Builds the private CPython 3.7, populates the wheelhouse (online, this first build), installs deps
# offline into the site dir, and compiles the ELF launcher + standalone reproducer + pytest wrapper.
RUN bash mayhem/build.sh

# Run the project's functional tests at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
