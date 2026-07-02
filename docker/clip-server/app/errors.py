class ImageDecodeError(ValueError):
    """Raised when untrusted image bytes cannot be safely decoded to an RGB image.

    server.py maps this to an HTTP 400 so malformed, truncated, or oversized
    (decompression-bomb) crawled images fail cleanly instead of surfacing as a 500.
    """
