'''
Script for the bulk Si example

Written by Edward Linscott, Mar 2021
'''

import matplotlib.pyplot as plt
from koopmans import utils, io
from koopmans.io import jsonio
from ase.dft.dos import DOS
from ase.spectrum.band_structure import BandStructurePlot


def run(from_scratch=True):
    names = ['dscf', 'dfpt', 'dfpt_with_dscf_screening']
    wfs = {}
    for name in names:
        with utils.chdir(name):
            wf = io.read_json(f'si.json')
            wf.from_scratch = from_scratch
            if 'screening' in name:
                wf.calculate_alpha = False
                dscf_alphas = wfs['dscf'].bands.alphas
                wf.alpha_guess = dscf_alphas[len(dscf_alphas) // 2 - 4: len(dscf_alphas) // 2 + 4]
            wf.run()

            # Save workflow to file
            with open('si.kwf', 'w') as fd:
                jsonio.write_json(fd, wf)
        wfs[name] = wf
    return wfs


def plot(wfs):
    calcs = {name: wf.all_calcs[-1] for name, wf in wfs.items()}

    # Setting up figure
    fig, axes = plt.subplots(ncols=2, nrows=1, sharey=True, gridspec_kw={'width_ratios': [3, 1]})

    # Plotting bandstructures
    for (calc, label, plot_kwargs) in ((calcs['dfpt'], 'DFPT', {'color': 'b', 'ls': '-'}),
                                       (calcs['dscf'], r'$\Delta$SCF', {'color': 'r', 'ls': '--'})):
        # Bandstructures
        bsp = BandStructurePlot(calc.results['band structure'])
        bsp.plot(ax=axes[0], **plot_kwargs)

        # Density of states
        dos = DOS(calc)
        axes[1].plot(dos.get_dos(), dos.get_energies(), **plot_kwargs, label=label)

    # Aesthetics
    axes[0].set_ylim([-15, 15])
    axes[1].set_xticks([])
    axes[1].legend(loc=4, ncol=2, bbox_to_anchor=(1, 1), frameon=False)

    # Saving figure and closing
    plt.savefig('comparison.pdf', format='pdf')
    plt.close('all')


if __name__ == '__main__':
    wfs = run()
    plot(wfs)