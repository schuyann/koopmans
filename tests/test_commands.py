import os
import pytest
from koopmans.commands import Command, ParallelCommand, ParallelCommandWithPostfix
from koopmans.io import encode, decode
from koopmans import utils


def test_command():
    # Creation from a string
    c_str = 'pw.x -in in.pwi > out.pwi'
    c = Command(c_str)
    assert c.executable == 'pw.x'
    assert str(c) == c_str
    assert decode(encode(c)) == c

    # Creation from another command object
    c2 = Command(c)
    assert c.executable == 'pw.x'
    assert str(c) == c_str


def test_parallel_command():
    c_str = 'mpirun -n 16 pw.x -in in.pwi > out.pwi'
    c = ParallelCommand(c_str)

    assert c.executable == 'pw.x'
    assert c.mpi_command == 'mpirun -n 16'
    assert str(c) == c_str
    assert decode(encode(c)) == c


def test_parallel_command_with_postfix():
    with utils.set_env(PARA_POSTFIX='-npool 4'):
        c_str = 'mpirun -n 16 pw.x -in in.pwi > out.pwi'
        postfix = '-npool 4'
        os.environ['PARA_POSTFIX'] = postfix
        c = ParallelCommandWithPostfix(c_str)

        assert c.postfix == postfix
        assert c.flags == postfix
        assert decode(encode(c)) == c