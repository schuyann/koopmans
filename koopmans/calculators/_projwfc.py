"""

projwfc.x calculator module for koopmans

"""

import os
import copy
import numpy as np
import re
from glob import glob
from pathlib import Path
from typing import List, Dict, Optional
from ase import Atoms
from ase.calculators.espresso import Projwfc
from ase.spectrum.dosdata import GridDOSData
from ase.spectrum.doscollection import GridDOSCollection
from koopmans import pseudopotentials
from koopmans.commands import Command, ParallelCommand
from koopmans.settings import ProjwfcSettingsDict
from ._utils import CalculatorExt, CalculatorABC, bin_directory


class ProjwfcCalculator(CalculatorExt, Projwfc, CalculatorABC):
    # Subclass of CalculatorExt for performing calculations with projwfc.x
    ext_in = '.pri'
    ext_out = '.pro'

    def __init__(self, atoms: Atoms, *args, **kwargs):
        # Define the valid settings
        self.parameters = ProjwfcSettingsDict()

        # Initialise first using the ASE parent and then CalculatorExt
        Projwfc.__init__(self, atoms=atoms)
        CalculatorExt.__init__(self, *args, **kwargs)

        self.results_for_qc = ['dos']
        if not isinstance(self.command, Command):
            self.command = ParallelCommand(os.environ.get(
                'ASE_PROJWFC_COMMAND', str(bin_directory) + os.path.sep + self.command))

        # We need pseudopotentials and pseudo dir in order to work out the number of valence electrons for each
        # element, and therefore what pDOS files to expect. We also need spin-polarised to know if the pDOS files will
        # contain columns for each spin channel

        # These must be provided post-initialisation (because we want to be allowed to initialise the calculator)
        # without providing these arguments
        self.pseudopotentials = None
        self.pseudo_dir = None
        self.spin_polarised = None

        self.results_for_qc = []

    def calculate(self):
        for attr in ['pseudopotentials', 'pseudo_dir', 'spin_polarised']:
            if not hasattr(self, attr):
                raise ValueError(f'Please set {self.__class__.__name__}.{attr} before calling '
                                 f'{self.__class__.__name__.calculate()}')
        super().calculate()
        self.generate_dos()

    @property
    def _expected_orbitals(self):
        """
        Generates a list of orbitals (e.g. 1s, 2s, 2p, ...) expected for each element in the system, based on the
        corresponding pseudopotential.
        """
        expected_orbitals = {}
        z_core_to_first_orbital = {0: '1s', 2: '2s', 4: '2p', 10: '3s', 12: '3p', 18: '3d', 28: '4s', 30: '4p',
                                   36: '4d', 46: '5s', 48: '5p', 50: '6s'}
        for atom in self.atoms:
            if atom.symbol in expected_orbitals:
                continue
            pseudo_file = self.pseudopotentials[atom.symbol]
            z_core = atom.number - pseudopotentials.valence_from_pseudo(pseudo_file, self.pseudo_dir)
            first_orbital = z_core_to_first_orbital[z_core]
            all_orbitals = list(z_core_to_first_orbital.values())
            expected_orbitals[atom.symbol] = all_orbitals[all_orbitals.index(first_orbital):]
        return expected_orbitals

    def generate_dos(self) -> GridDOSCollection:
        """
        Parse all of the pdos files and add these densities of state to self.results
        """
        dos_list = []
        for atom in self.atoms:
            filenames = sorted(self.directory.glob(self.parameters.filpdos + f'.pdos_atm#{atom.index+1}*'))
            # The filename does not encode the principal quantum number n. In order to recover this number, we compare
            # the reported angular momentum quantum number l against the list of expected orbitals, and infer n
            # assuming only that the file corresponding to nl will come before (n+1)l
            orbitals = copy.copy(self._expected_orbitals[atom.symbol])
            for filename in filenames:
                # Infer l from the filename
                subshell = filename.name[-2]
                # Find the orbital with matching l with the smallest n
                orbital = [o for o in orbitals if o[-1] == subshell][0]
                orbitals.remove(orbital)

                # Load the DOSs
                dos_list += self.read_pdos(filename, orbital)

        #  add pDOS to self.results
        self.results['dos'] = GridDOSCollection(dos_list)

    def read_pdos(self, filename: Path, expected_subshell: str) -> List[GridDOSData]:
        """
        Function for reading a pDOS file
        """

        # Read the file contents
        with open(filename, 'r') as fd:
            flines = fd.readlines()

        # Parse important information from the filename
        [_, index, symbol, _, _, subshell, _] = re.split(r"#|\(|\)", filename.name)

        # Compare against the expected subshell
        if subshell != expected_subshell[1]:
            raise ValueError(
                f"Unexpected pdos file {filename.name}, a pdos file corresponding to {expected_subshell} was expected")

        # Work out what orbitals will be contained within the pDOS file
        orbital_order = {"s": ["s"], "p": ["pz", "px", "py"], "d": ["dz2", "dxz", "dyz", "dx2-y2", "dxy"]}

        spins: List[Optional[str]]
        if self.spin_polarised:
            spins = ["up", "down"]
        else:
            spins = [None]
        orbitals = [(o, spin) for o in orbital_order[subshell] for spin in spins]

        # Parse the rest of the file
        data = np.array([l.split() for l in flines[1:]], dtype=float).transpose()
        energy = data[0]

        # Looping over each pDOS in the file...
        dos_list = []
        for weight, (label, spin) in zip(data[-len(orbitals):], orbitals):
            # Assemble all of the information about this particular pDOS
            info = {"symbol": symbol, "index": int(index), "n": expected_subshell[0], "l": subshell, "m": label}
            if self.spin_polarised:
                info['spin'] = spin

            # Create and store the pDOS as a GridDOSData object
            dos = GridDOSData(energy, weight, info=info)
            dos_list.append(dos)

        # Return the list of GridDOSData objects
        return dos_list

    def is_complete(self):
        return self.results['job done']

    def is_converged(self):
        return True