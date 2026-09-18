"""Compare four continuous CFD steps with two steps + native restart + two.

This only verifies CFD/case state, not learner state or paired-run recovery.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--ranks', type=int, default=16)
    args = parser.parse_args()
    if not 1 <= args.ranks <= 32:
        parser.error('ranks must be in 1..32')
    run = args.run.resolve()
    run.mkdir(parents=True, exist_ok=False)
    checkpoint = run / 'checkpoint'
    checkpoint.mkdir()
    source = args.source / 'couplings/ibamr/cases/eel2d/upstream'
    text = (source / 'input2d.in').read_text()
    for key, value in {'viz_dump_interval': '0', 'restart_dump_interval': '0',
                       'timer_dump_interval': '0', 'ENABLE_LOGGING': 'FALSE'}.items():
        text, count = re.subn(r'(?m)^\s*' + key + r'\s*=.*$', '   ' + key + ' = ' + value, text)
        if count != 1:
            raise ValueError('expected one input setting: ' + key)
    env = os.environ.copy()
    env.update(OMP_NUM_THREADS='1', OPENBLAS_NUM_THREADS='1')
    results = []
    for mode in ('write', 'resume'):
        directory = run / mode
        directory.mkdir()
        (directory / 'input2d').write_text(text)
        shutil.copy2(source / 'eel2d.vertex', directory / 'eel2d.vertex')
        command = ['mpiexec', '--bind-to', 'none', '-n', str(args.ranks),
                   str(args.binary.resolve()), mode, 'input2d', str(checkpoint)]
        with (directory / 'process.log').open('w') as log:
            result = subprocess.run(command, cwd=directory, env=env, stdin=subprocess.DEVNULL,
                                    stdout=log, stderr=subprocess.STDOUT)
        (directory / 'exit.status').write_text(str(result.returncode) + '\n')
        if result.returncode:
            raise RuntimeError(f'{mode} failed ({result.returncode}): {directory / "process.log"}')
        results.append([float(x) for x in (directory / 'restart-probe.txt').read_text().split()])
    left, right = results
    if len(left) != len(right) or not left:
        raise AssertionError('missing or mismatched CFD comparison values')
    # Physical/force/probe values may differ through iterative solver histories.
    # Time, phase and commanded frequency must retain their saved values exactly.
    exact = {0, 7, 8, 9, 16, 17}
    failures = []
    for index, (a, b) in enumerate(zip(left, right)):
        if not math.isfinite(a) or not math.isfinite(b):
            failures.append([index, a, b, 'nonfinite'])
        elif (a != b if index in exact else not math.isclose(a, b, rel_tol=1e-6, abs_tol=1e-8)):
            failures.append([index, a, b, abs(a-b)])
    summary = {'ranks': args.ranks, 'compared_values': len(left),
               'maximum_absolute_difference': max(abs(a-b) for a, b in zip(left, right)),
               'relative_tolerance': 1e-6, 'absolute_tolerance': 1e-8,
               'checkpoint_bytes': sum(p.stat().st_size for p in checkpoint.rglob('*') if p.is_file()),
               'failures': failures}
    (run / 'comparison.json').write_text(json.dumps(summary, indent=2) + '\n')
    if failures:
        raise AssertionError(f'CFD restart differences: {failures}')
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
