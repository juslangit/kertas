#!/usr/bin/env python3
"""Kertas's helper: the jobs Apple's PDFKit cannot do on its own.

PDFKit can show a PDF, add annotations and move pages, but it cannot change the
text that is printed on a page, shrink a file, or write Word. PyMuPDF can, so the
Mac app hands those jobs to this script and reloads the file it writes.

Every command reads one PDF and writes another; it never changes its input.
Positions arrive in PDF space (origin bottom-left, y up), which is what PDFKit
uses, and are converted to MuPDF space (origin top-left) here.

    helper.py span-info    IN PAGE X0 Y0 X1 Y1
    helper.py edit-text    IN OUT PAGE X0 Y0 X1 Y1 TEXT [FONTFILE]
    helper.py insert-image IN OUT PAGE X0 Y0 X1 Y1 IMAGE
    helper.py compress     IN OUT
    helper.py to-docx      IN OUT
    helper.py ocr-layer    IN OUT WORDS.json

Output is one line of JSON on stdout. Failures print {"error": ...} and exit 1.
"""
import json
import os
import sys

import pymupdf


def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(1)


def to_mupdf(page, x0, y0, x1, y1):
    """A rectangle in PDF space, as a rectangle in MuPDF space on this page."""
    return pymupdf.Rect(x0, y0, x1, y1) * page.transformation_matrix


def spans_in(page, rect):
    """The text spans on the line inside rect, in reading order.

    A span belongs to the line when its vertical middle lies inside the rect.
    Testing for overlap instead would catch the lines above and below, whose
    boxes often touch this one.
    """
    found = []
    for block in page.get_text("dict")["blocks"]:
        for line in block.get("lines", []):
            for span in line["spans"]:
                box = pymupdf.Rect(span["bbox"])
                middle = (box.y0 + box.y1) / 2
                if rect.y0 <= middle <= rect.y1 and box.x1 >= rect.x0 and box.x0 <= rect.x1:
                    if span["text"].strip():
                        found.append(span)
    found.sort(key=lambda s: s["bbox"][0])
    return found


def clean_font_name(name):
    # Embedded fonts are usually subsets, named like "ABCDEF+Helvetica-Bold".
    return name.split("+", 1)[1] if "+" in name else name


def base14_for(span):
    """The closest of PDF's built-in fonts, for when the real one isn't on this Mac."""
    flags = span["flags"]
    bold, italic = bool(flags & 16), bool(flags & 2)
    name = span["font"].lower()
    # The name is trusted before the flags: Chrome marks the Helvetica Neue it
    # embeds as serif, which would turn a sans-serif CV into Times.
    sans_names = ("helvetica", "arial", "sans", "inter", "roboto", "calibri", "verdana", "segoe", "gothic")
    serif_names = ("times", "georgia", "garamond", "cambria", "serif", "minion", "palatino", "baskerville")
    if "courier" in name or "mono" in name or (flags & 8 and not any(n in name for n in sans_names)):
        family = ["cour", "cobo", "coit", "cobi"]
    elif any(n in name for n in sans_names):
        family = ["helv", "hebo", "heit", "hebi"]
    elif any(n in name for n in serif_names) or flags & 4:
        family = ["tiro", "tibo", "tiit", "tibi"]
    else:
        family = ["helv", "hebo", "heit", "hebi"]
    if "bold" in name:
        bold = True
    if "italic" in name or "oblique" in name:
        italic = True
    return family[(1 if bold else 0) + (2 if italic else 0)]


def colour(value):
    return ((value >> 16) & 255) / 255, ((value >> 8) & 255) / 255, (value & 255) / 255


def span_info(path, page_no, *box):
    doc = pymupdf.open(path)
    page = doc[int(page_no)]
    spans = spans_in(page, to_mupdf(page, *map(float, box)))
    if not spans:
        fail("There is no text on that line.")
    first = spans[0]
    print(json.dumps({
        "text": "".join(s["text"] for s in spans),
        "font": clean_font_name(first["font"]),
        "size": first["size"],
        "color": list(colour(first["color"])),
        "bold": bool(first["flags"] & 16) or "bold" in first["font"].lower(),
        "italic": bool(first["flags"] & 2),
    }))


def edit_text(src, dst, page_no, x0, y0, x1, y1, text, fontfile=""):
    doc = pymupdf.open(src)
    page = doc[int(page_no)]
    spans = spans_in(page, to_mupdf(page, float(x0), float(y0), float(x1), float(y1)))
    if not spans:
        fail("There is no text on that line.")
    first = spans[0]

    # Remove the old characters for real, not by painting white over them, so
    # the old words cannot be copied or searched for afterwards. The box is
    # trimmed top and bottom so it cannot bite into the neighbouring lines, and
    # pictures and drawings under it are left alone.
    old = pymupdf.Rect()
    for span in spans:
        old |= pymupdf.Rect(span["bbox"])
    trim = old.height * 0.2
    page.add_redact_annot(pymupdf.Rect(old.x0, old.y0 + trim, old.x1, old.y1 - trim), fill=False)
    page.apply_redactions(images=pymupdf.PDF_REDACT_IMAGE_NONE,
                          graphics=pymupdf.PDF_REDACT_LINE_ART_NONE)

    if text:
        options = dict(fontsize=first["size"], color=colour(first["color"]))
        if fontfile and os.path.exists(fontfile):
            options.update(fontname="KertasFont", fontfile=fontfile)
        else:
            options.update(fontname=base14_for(first))
        page.insert_text(pymupdf.Point(first["origin"]), text, **options)

    doc.save(dst, garbage=3, deflate=True)
    print(json.dumps({"ok": True, "font": options.get("fontname") if text else None}))


def insert_image(src, dst, page_no, x0, y0, x1, y1, image):
    doc = pymupdf.open(src)
    page = doc[int(page_no)]
    page.insert_image(to_mupdf(page, float(x0), float(y0), float(x1), float(y1)),
                      filename=image, keep_proportion=True)
    doc.save(dst, garbage=3, deflate=True)
    print(json.dumps({"ok": True}))


def compress(src, dst):
    before = os.path.getsize(src)
    doc = pymupdf.open(src)
    # Photos are where the weight is. Anything sharper than 150 dpi is brought
    # down to 120, which still prints cleanly and reads fine on any screen.
    doc.rewrite_images(dpi_threshold=150, dpi_target=120, quality=75)
    doc.subset_fonts()
    doc.save(dst, garbage=4, deflate=True, clean=True, deflate_images=True, deflate_fonts=True)
    after = os.path.getsize(dst)
    print(json.dumps({"ok": True, "before": before, "after": after}))


def to_docx(src, dst):
    from pdf2docx import Converter
    import logging
    logging.disable(logging.CRITICAL)
    converter = Converter(src)
    converter.convert(dst)
    converter.close()
    print(json.dumps({"ok": True}))


def ocr_layer(src, dst, words_json):
    """Write recognised text into the page as invisible text, so a scan becomes searchable.

    Invisible text (render mode 3) is what scanners do: nothing changes on screen,
    but the words can be selected, copied and found. Each line is stretched
    sideways to the width Vision measured, so a selection lands on the words.
    """
    with open(words_json) as f:
        pages = json.load(f)
    doc = pymupdf.open(src)
    written = 0
    for entry in pages:
        page = doc[entry["page"]]
        for line in entry["lines"]:
            rect = to_mupdf(page, *line["rect"])
            text = line["text"]
            size = max(rect.height * 0.85, 1)
            width = pymupdf.get_text_length(text, fontname="helv", fontsize=size)
            if width <= 0:
                continue
            origin = pymupdf.Point(rect.x0, rect.y1 - rect.height * 0.2)
            page.insert_text(origin, text, fontsize=size, fontname="helv", render_mode=3,
                             morph=(origin, pymupdf.Matrix(rect.width / width, 1)))
            written += 1
    doc.save(dst, garbage=3, deflate=True)
    print(json.dumps({"ok": True, "lines": written}))


COMMANDS = {
    "span-info": span_info,
    "edit-text": edit_text,
    "insert-image": insert_image,
    "compress": compress,
    "to-docx": to_docx,
    "ocr-layer": ocr_layer,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        fail("usage: helper.py " + " | ".join(COMMANDS))
    try:
        COMMANDS[sys.argv[1]](*sys.argv[2:])
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — the app shows this message to the user
        fail(f"{type(exc).__name__}: {exc}")
