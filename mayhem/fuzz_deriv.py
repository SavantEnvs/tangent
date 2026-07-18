#!/opt/toolchains/py37/bin/python3.7
"""Atheris fuzz harness for google/tangent (target name ``fuzz-deriv`` preserved).

NOTE ON THE SHEBANG: it MUST point at the private CPython 3.7 that mayhem/build.sh
installs (not /usr/bin/env python3). Mayhem runs libFuzzer in FORK mode, and the
fork driver re-execs ``sys.argv[0]`` — which, because the launcher ELF execs
``python3.7 fuzz_deriv.py``, is THIS file's path. If the shebang resolved to the
base image's CPython 3.13 the re-exec'd child would have no atheris and a tangent
that cannot differentiate anything, so every fork job would die instantly at #0
(0 edges). Pinning the shebang to the py37 interpreter makes fork children work.

tangent performs automatic differentiation by *source-code transformation*: it
parses a Python function's source into an AST, runs it through a pipeline
(quoting -> ANF -> CFG -> forward/reverse AD -> template substitution ->
optimization -> compile) and hands back a new derivative function. This harness
feeds fuzzer-controlled Python source into that pipeline via ``tangent.grad`` so
libFuzzer drives the transformer toward new code paths.

Because ``tangent`` builds its AD transforms against a specific CPython AST /
``gast`` layout, the image pins CPython 3.7 + gast 0.2.2 (the version the
transformer was written for); on 3.8+ the AST changed and ``tangent.grad`` no
longer works at all. See mayhem/build.sh.

Run modes (driven by the compiled launcher ``fuzz-deriv`` / ``-standalone``):
  * fuzzing      -- ``python3.7 fuzz_deriv.py [libFuzzer args]``
  * single input -- ``python3.7 fuzz_deriv.py <file>`` (libFuzzer runs it once)
"""
import inspect
import os
import random
import sys
import tempfile
from importlib.util import module_from_spec, spec_from_loader
from typing import Callable, Optional

import atheris
import fuzz_helpers

# Instrument the library under test so the fuzzer gets coverage feedback. Scope
# it to `tangent` (+ gast/astor, its AST backends) so fork-mode children don't
# pay a multi-second numpy/autograd instrumentation startup on every job.
with atheris.instrument_imports(include=['tangent', 'gast', 'astor']):
    import tangent


# Default source used to prime the custom mutator (a function tangent can
# actually differentiate on the pinned interpreter).
def _seed_fn(x):
    a = x * x
    b = x / a
    c = a + b
    d = a - c
    return d


def_src = bytes(inspect.getsource(_seed_fn), 'utf-8')


class ShowSourceLoader:
    """Loader that exposes the fuzzed source so ``inspect.getsource`` works.

    tangent refuses to differentiate a function whose source it cannot read
    (functions defined via ``exec`` have none), so we register a module with a
    loader that returns the fuzzed text.
    """

    def __init__(self, modname: str, source: str) -> None:
        self.modname = modname
        self.source = source

    def get_source(self, modname: str) -> str:
        if modname != self.modname:
            raise ImportError(modname)
        return self.source


def to_func(data: str) -> Callable:
    fname = tempfile.mktemp(suffix='.py')
    modname = os.path.splitext(os.path.basename(fname))[0]
    if modname in sys.modules:
        del sys.modules[modname]
    loader = ShowSourceLoader(modname, data)
    spec = spec_from_loader(modname, loader, origin=fname)
    mod = module_from_spec(spec)
    co = compile(data, mode='exec', filename=fname)
    exec(co, mod.__dict__)  # noqa: S102 - intentional: run the fuzzed module
    sys.modules[modname] = mod
    return mod.f


@atheris.instrument_func
def build_function(fdp: fuzz_helpers.EnhancedFuzzedDataProvider) -> Optional[Callable]:
    try:
        func_def_code = fdp.ConsumeRemainingBytes().decode('utf-8')
        return to_func(func_def_code)
    # NB: catch BaseException, not Exception. ``to_func`` EXECs the fuzzer-
    # controlled module body, so an input like ``exit()`` / ``sys.exit()`` /
    # ``raise SystemExit`` raises SystemExit (a BaseException) which would
    # otherwise terminate the whole fuzzer process -- libFuzzer reports that as
    # a spurious "fuzz target exited" crash on every fork job.
    except BaseException:
        return None


# libFuzzer values seeds/mutations that at least parse into a callable ``f``;
# fall back to the known-good seed otherwise so the corpus stays productive.
def CustomMutator(data, max_size, seed):
    try:
        inspect.getsource(to_func(data.decode('utf-8')))
    except BaseException:  # exec of fuzzed source may raise SystemExit — see above
        return def_src
    return atheris.Mutate(data, len(data))


# tangent raises TangentParseError for input it declines to differentiate; the
# usual stdlib parse/lookup errors also fire on adversarial source. These are
# expected outcomes, not memory-safety defects, so we swallow them.
_VALUE_MSG_MATCHERS = ('chained', 'exactly one')


@atheris.instrument_func
def TestOneInput(data):
    try:
        grad_func = build_function(fuzz_helpers.EnhancedFuzzedDataProvider(data))
        if grad_func is None:
            return -1
        tangent.grad(grad_func)(5)
    except (tangent.TangentParseError, AttributeError, SyntaxError):
        return -1
    except (TypeError, IndexError):
        # Broadly expected on adversarial source; keep a rare escape hatch so a
        # genuinely surprising instance can still surface as a crash.
        if random.random() > 0.999:
            raise
        return 0
    except ValueError as e:
        if any(m in str(e) for m in _VALUE_MSG_MATCHERS):
            return -1
        raise


def main():
    atheris.Setup(sys.argv, TestOneInput, custom_mutator=CustomMutator)
    atheris.Fuzz()


if __name__ == '__main__':
    main()
