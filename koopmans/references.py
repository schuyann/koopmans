'''
references module for koopmans

Written by Edward Linscott, Feb 2022
'''

from pathlib import Path

from pybtex.database.input import bibtex

parser = bibtex.Parser()
bib_file = Path(__file__).parents[1] / 'docs/refs.bib'
bib_data = parser.parse_file(bib_file)
