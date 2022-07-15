

from ._workflow import Workflow
from typing import List, Dict, Any
from ase import Atoms, io
import json as json_ext
from koopmans import utils

load_results_from_output = True


class TrajectoryWorkflow(Workflow):

    def __init__(self, *args, **kwargs):
        self.snapshots: List[Atoms] = kwargs.pop('snapshots', [])
        super().__init__(*args, **kwargs)

    def _run(self) -> None:
        """
        Runs the trajectory workflow. 
        """

        # Import it like this so if they have been monkey-patched, we will get the monkey-patched version
        from koopmans.workflows import KoopmansDFPTWorkflow, KoopmansDSCFWorkflow

        for i, snapshot in enumerate(self.snapshots):
            self.parameters.current_snapshot = i
            self.atoms.set_positions(snapshot.positions)

            self.print(f'Performing Koopmans calculation on snapshot {i+1} / {len(self.snapshots)}', style='heading')

            if self.parameters.method == 'dfpt':
                workflow = KoopmansDFPTWorkflow(**self.wf_kwargs)
                self.run_subworkflow(workflow)
            else:
                dscf_workflow = KoopmansDSCFWorkflow(**self.wf_kwargs)

                # reset the bands to the initial guesses (i.e. either from file or to 0.6 but not from the previous calculation)
                self.bands = dscf_workflow.bands
                self.run_subworkflow(dscf_workflow, subdirectory='snapshot_' + str(i+1))

    @classmethod
    def _fromjsondct(cls, bigdct: Dict[str, Any]):
        """
        Reads the atomic positions for each snapshot from the xyz-file specified by the user in the snapshots-file.
        """

        try:
            snapshots_file = bigdct['setup'].pop('snapshots')
        except:
            raise ValueError(
                f'To calculate a trajectory, please provide a xyz-file containing the atomic positions of the snapshots in the setup-block of the json-input file.')

        snapshots = io.read(snapshots_file, index=':')
        if isinstance(snapshots, Atoms):
            snapshots = [snapshots]
        bigdct['setup']['atomic_positions'] = utils.construct_atomic_positions_block(snapshots[0])
        wf = super(TrajectoryWorkflow, cls)._fromjsondct(bigdct)
        wf.snapshots = snapshots
        return wf