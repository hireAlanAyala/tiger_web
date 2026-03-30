# Tiger Web SDK — utilities for Python handlers.
# Port of generated/types.generated.ts utilities.

import html as _html


def esc(s: str) -> str:
    """HTML-escape a string."""
    return _html.escape(s, quote=True)


def price(cents: int) -> str:
    """Format cents as a dollar string."""
    return f"${cents / 100:.2f}"


def short_id(id: str) -> str:
    """Truncate a hex UUID to first 8 chars for display."""
    return id[:8]
