"""

kwf (Koopmans WorkFlow) I/O for koopmans

Written by Edward Linscott Mar 2021, largely modelled off ase.io.jsonio

"""

import inspect
import json
import os
from importlib import import_module
from pathlib import Path
from typing import List, TextIO, Union
from sklearn.linear_model import Ridge
from sklearn.preprocessing import StandardScaler


from ase.io import jsonio as ase_json

from koopmans.ml import AbstractPredictor
import koopmans.workflows as workflows

import numpy as np


class KoopmansEncoder(ase_json.MyEncoder):
    def default(self, obj) -> dict:
        if isinstance(obj, set):
            return {'__set__': list(obj)}
        elif isinstance(obj, Path):
            return {'__path__': os.path.relpath(obj, '.')}
        elif inspect.isclass(obj):
            return {'__class__': {'__name__': obj.__name__, '__module__': obj.__module__}}
        elif hasattr(obj, 'todict'):
            d = obj.todict()
            if '__koopmans_name__' in d:
                return d
        elif (isinstance(obj, Ridge) or isinstance(obj, StandardScaler)):
            model_params: List[str] = []
            if isinstance(obj, Ridge):
                model_params = ['coef_', 'intercept_']
            elif isinstance(obj, StandardScaler):
                model_params = ['mean_', 'scale_', 'n_samples_seen_', 'var_']
            d = {}
            d['init_params'] = obj.get_params()
            d['model_params'] = {}
            for p in model_params:
                d['model_params'][p] = getattr(obj, p).tolist()
            return d
        # If none of the above, use ASE's encoder
        return super().default(obj)


encode = KoopmansEncoder(indent=1).encode


def object_hook(dct):
    if '__koopmans_name__' in dct:
        return create_koopmans_object(dct)
    elif '__set__' in dct:
        return set(dct['__set__'])
    elif '__path__' in dct:
        return Path(dct['__path__'])
    elif '__class__' in dct:
        subdct = dct['__class__']
        module = import_module(subdct['__module__'])
        return getattr(module, subdct['__name__'])
    else:
        if ('scaler' in dct or 'model' in 'dct'):
            def load_ml_model(model, model_dct):
                model.set_params(**model_dct['init_params'])
                for p in model_dct['model_params'].keys():
                    setattr(model, p, np.asarray(model_dct['model_params'][p] ))
                return model
            if 'scaler' in dct:
                scaler = StandardScaler()
                model_dct = dct.pop('scaler')
                scaler = load_ml_model(scaler, model_dct)
                dct['scaler'] = scaler
            if 'model' in dct:
                model = Ridge()
                model_dct = dct.pop('model')
                model = load_ml_model(model, model_dct)
                dct['model'] = model
        # Patching bug in ASE where allocating an np.empty(dtype=str) will assume a particular length for each
        # string. dtype=object allows for individual strings to be different lengths
        if '__ndarray__' in dct:
            dtype = dct['__ndarray__'][1]
            if 'str' in dtype:
                dct['__ndarray__'][1] = object

        # Making it possible for "None" to be a key in a dictionary
        if 'null' in dct:
            dct[None] = dct.pop('null')

        return ase_json.object_hook(dct)


def create_koopmans_object(dct: dict):
    # Load object class corresponding to this dictionary
    name = dct.pop('__koopmans_name__')
    module = import_module(dct.pop('__koopmans_module__'))
    objclass = getattr(module, name)

    # Reconstruct the class from the dictionary
    return objclass.fromdict(dct)


decode = json.JSONDecoder(object_hook=object_hook).decode


def read_kwf(fd: TextIO):
    return decode(fd.read())


def write_kwf(obj: Union[workflows.Workflow, AbstractPredictor, dict], fd: TextIO):
    if isinstance(obj, workflows.Workflow):
        use_relpath = obj.parameters.use_relative_paths
        obj.parameters.use_relative_paths = True
    fd.write(encode(obj))
    if isinstance(obj, workflows.Workflow):
        obj.parameters.use_relative_paths = use_relpath
