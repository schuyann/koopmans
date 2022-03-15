from typing import Dict, Any, List
from ase.io.espresso import w2kcw_keys
from ._utils import SettingsDict, kc_wann_defaults


class Wann2KCSettingsDict(SettingsDict):
    def __init__(self, **kwargs) -> None:

        # Get rid of any nested kwargs
        flattened_kwargs: Dict[str, Any] = {}
        for k, v in kwargs.items():
            if isinstance(v, dict):
                flattened_kwargs.update(**v)
            else:
                flattened_kwargs[k] = v

        super().__init__(valid=[k for block in w2kcw_keys.values() for k in block],
                         defaults={'calculation': 'wann2kcw', **kc_wann_defaults},
                         are_paths=['outdir', 'pseudo_dir'],
                         to_not_parse=['assume_isolated'],
                         **flattened_kwargs)

    @property
    def _other_valid_keywords(self) -> List[str]:
        return []
