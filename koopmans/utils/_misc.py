'''

Miscellaneous functions for koopmans.utils

Written by Edward Linscott May 2020

'''


from typing import Any, Generator, Iterable, List, Union


def flatten(l: Union[List[Any], Iterable[Any]]) -> Generator[Any, None, None]:
    # Converts a list of any kind of object (numbers, arrays, lists, strings, ecc.)
    # to a generator
    for item in l:
        if isinstance(item, Iterable) and not isinstance(item, str):
            for x in flatten(item):
                yield x
        else:
            yield item
