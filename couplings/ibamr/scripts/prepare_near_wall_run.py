#!/usr/bin/env python3
"""Create a new run directory without changing the official eel vertex file."""
import argparse
import pathlib
import re
import shutil

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('source', type=pathlib.Path)
p.add_argument('run', type=pathlib.Path)
p.add_argument('--reset-check', action='store_true')
a = p.parse_args()
a.run.mkdir(parents=True, exist_ok=False)
upstream = a.source / 'couplings/ibamr/cases/eel2d/upstream'
text = (upstream / 'input2d.in').read_text()
settings = {'viz_dump_interval': '0', 'restart_dump_interval': '0',
            'timer_dump_interval': '0', 'output_interval': '100', 'ENABLE_LOGGING': 'FALSE'}
if a.reset_check:
    settings['END_TIME'] = '0.01'
for key, value in settings.items():
    text, n = re.subn(r'(?m)^\s*' + re.escape(key) + r'\s*=.*$',
                       '   ' + key + ' = ' + value, text)
    if n != 1:
        raise SystemExit('Expected exactly one setting: ' + key)
(a.run / 'input2d').write_text(text)
shutil.copy2(upstream / 'eel2d.vertex', a.run / 'eel2d.vertex')
shutil.copy2(a.source / 'couplings/ibamr/configs/tasks/near_wall.conf', a.run / 'task.conf')
shutil.copy2(a.source / 'couplings/ibamr/configs/training/near_wall.json', a.run / 'settings.json')
print(a.run)
