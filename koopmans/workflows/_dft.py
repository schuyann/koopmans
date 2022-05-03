"""

Workflow module for performing a single DFT calculation with either kcp.x or pw.x

Written by Edward Linscott Oct 2020

"""

from koopmans import utils, pseudopotentials
from ._workflow import Workflow
import matplotlib.pyplot as plt


class DFTCPWorkflow(Workflow):

    def _run(self):

        calc = self.new_calculator('kcp')

        # Removing old directories
        if self.parameters.from_scratch:
            utils.system_call(f'rm -r {calc.parameters.outdir} 2>/dev/null', False)

        calc.prefix = 'dft'
        calc.directory = '.'
        calc.parameters.ndr = 50
        calc.parameters.ndw = 51
        calc.parameters.restart_mode = 'from_scratch'
        calc.parameters.do_orbdep = False
        calc.parameters.fixed_state = False
        calc.parameters.do_outerloop = True
        calc.parameters.which_compensation = 'tcc'

        if calc.parameters.maxiter is None:
            calc.parameters.maxiter = 300
        if calc.has_empty_states():
            calc.parameters.do_outerloop_empty = True
            if calc.parameters.empty_states_maxstep is None:
                calc.parameters.empty_states_maxstep = 300

        self.run_calculator(calc, enforce_ss=self.parameters.fix_spin_contamination)

        return calc


class DFTPWWorkflow(Workflow):

    def _run(self):

        # Create the calculator
        calc = self.new_calculator('pw')

        # Update keywords
        calc.prefix = 'dft'
        calc.parameters.ndr = 50
        calc.parameters.ndw = 51
        calc.parameters.restart_mode = 'from_scratch'

        # Remove old directories
        if self.parameters.from_scratch:
            utils.system_call(f'rm -r {calc.parameters.outdir} 2>/dev/null', False)

        # Run the calculator
        self.run_calculator(calc)

        return


class PWBandStructureWorkflow(Workflow):

    def _run(self):

        self.print('DFT bandstructure workflow', style='heading')

        with utils.chdir('dft_bands'):
            # First, a scf calculation
            calc_scf = self.new_calculator('pw', nbnd=None)
            calc_scf.prefix = 'scf'
            self.run_calculator(calc_scf)

            # Second, a bands calculation
            calc_bands = self.new_calculator('pw', calculation='bands', kpts=self.kpath)
            calc_bands.prefix = 'bands'
            self.run_calculator(calc_bands)

            # Prepare the band structure for plotting
            bs = calc_bands.results['band structure']
            n_filled = pseudopotentials.nelec_from_pseudos(self.atoms, self.pseudopotentials, self.pseudo_dir) // 2
            vbe = bs._energies[:, :, :n_filled].max()
            bs._energies -= vbe

            # Third, a PDOS calculation
            pseudos = [pseudopotentials.read_pseudo_file(calc_scf.parameters.pseudo_dir / p) for p in
                       self.pseudopotentials.values()]
            if all([int(p.find('PP_HEADER').get('number_of_wfc')) > 0 for p in pseudos]):
                calc_dos = self.new_calculator('projwfc', filpdos=self.name)
                calc_dos.pseudopotentials = self.pseudopotentials
                calc_dos.spin_polarised = self.parameters.spin_polarised
                calc_dos.pseudo_dir = calc_bands.parameters.pseudo_dir
                self.run_calculator(calc_dos)

                # Prepare the DOS for plotting
                dos = calc_dos.results['dos']
                dos._energies -= vbe
            else:
                # Skip if the pseudos don't have the requisite PP_PSWFC blocks
                utils.warn('Some of the pseudopotentials do not have PP_PSWFC blocks, which means a projected DOS '
                           'calculation is not possible. Skipping...')
                dos = None

            # Plot the band structure and DOS
            self.plot_bandstructure(bs, dos)
