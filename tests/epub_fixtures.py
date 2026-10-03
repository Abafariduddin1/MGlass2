#!/usr/bin/env python3
"""Generate small EPUBs for the native package-parser checks in macOS CI."""
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
container = '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
def book(name, package, entries=None):
    with zipfile.ZipFile(root / (name + ".epub"), "w", compression=zipfile.ZIP_DEFLATED) as output:
        output.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        output.writestr("META-INF/container.xml", container)
        output.writestr("EPUB/book.opf", package)
        output.writestr("EPUB/one.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head><body>Hello</body></html>')
        output.writestr("EPUB/two.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml"><body>Two</body></html>')
        for path, content in (entries or {}).items(): output.writestr(path, content)

package = '<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Example book</dc:title></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="two"/><itemref idref="one"/></spine></package>'
book("valid", package)
book("fixed-rtl", package.replace('</metadata>', '<meta property="rendition:layout">pre-paginated</meta></metadata>').replace('<spine>', '<spine page-progression-direction="rtl">'))
book("nonlinear", package.replace('<itemref idref="one"/>', '<itemref idref="one" linear="no"/>'))
book("missing", package.replace('href="one.xhtml"', 'href="missing.xhtml"'))
book("outside", package.replace('href="one.xhtml"', 'href="../../outside.xhtml"'))
book("remote", package.replace('href="one.xhtml"', 'href="https://example.invalid/one.xhtml"'))
book("drm", package, {"META-INF/encryption.xml": '<encryption xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes256-cbc"/></enc:EncryptedData></encryption>'})
book("font-obfuscation", package, {"META-INF/encryption.xml": '<encryption xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></enc:EncryptedData></encryption>'})
book("encoded-space", package.replace('href="one.xhtml"', 'href="chapter%20one.xhtml"'), {"EPUB/chapter one.xhtml": '<html xmlns="http://www.w3.org/1999/xhtml"><body>One</body></html>'})
