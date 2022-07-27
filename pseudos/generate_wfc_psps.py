'''
Script for regenerating pseudopotentials missing PP_PSWFC fields with oncvpsp(r).x
Written by Edward Linscott, March 2022
'''

import subprocess
from glob import glob
from pathlib import Path

from koopmans.pseudopotentials import read_pseudo_file

for fname in Path().rglob('*.upf'):
    try:
        pseudo = read_pseudo_file(fname)
    except Exception:
        raise ValueError(f'Failed to read {fname}')

    # Do not touch files not generated by oncvpsp.x
    pp_info = pseudo.find('PP_INFO')
    if 'ONCVPSP ' not in pp_info.text:
        continue

    # Do not touch files that have already got the appropriate fields
    n_wfc = int(pseudo.find('PP_HEADER').get('number_of_wfc'))
    if n_wfc > 0:
        continue

    # Do not touch files that have already got a wfc counterpart
    new_fname = fname.parent / (fname.stem + '_wfc.upf')
    if new_fname.exists():
        continue

    # Printing out info to screen
    print(f'Generating {new_fname}...', end='', flush=True)

    # Generate a oncvpsp.x input file
    with open('tmp.in', 'w') as fd:
        fd.write(pp_info.find('PP_INPUTFILE').text)

    # Work out the appropriate program
    if pseudo.find('PP_HEADER').get('relativistic') == 'full':
        prog = 'oncvpspr.x'
    else:
        prog = 'oncvpsp.x'
    # pp_header.

    # Run oncvpsp.x
    proc = subprocess.run(f'{prog} < tmp.in', shell=True, capture_output=True, text=True)
    flines = proc.stdout.split('\n')
    try:
        istart = flines.index('Begin PSP_UPF') + 1
        iend = flines.index('</UPF>') + 1
    except ValueError:
        print(' failed!')
        continue

    # Save the new pseudo to file
    with open(new_fname, 'w') as fd:
        fd.write('\n'.join(flines[istart:iend]))

    print(' done')

# Remove tmp.in
Path('tmp.in').unlink()
