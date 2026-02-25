"""Gedeelde hulpfuncties voor Tempdog."""

import re

_IEEE_RE = re.compile(r"^0x[0-9a-fA-F]{10,16}$")


def is_ieee_address(name: str) -> bool:
    """Geeft True als *name* eruitziet als een IEEE-adres (bijv. 0xa4c13805dd26ffff)."""
    return bool(_IEEE_RE.match(name))
