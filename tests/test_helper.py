#!/usr/bin/env python3
"""Headless checks for tools/helper.py. Run: tests/run.sh

Each check builds its own PDF, runs one helper command the way the app does,
and then reads the output file back — the output, not the command's word for it.
"""
import json
import os
import subprocess
import sys
import tempfile

import pymupdf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(ROOT, "tools", "helper.py")
work = tempfile.mkdtemp(prefix="kertas-test-")
failures = 0


def run(*args):
    out = subprocess.run([sys.executable, HELPER, *map(str, args)], capture_output=True, text=True)
    try:
        return json.loads(out.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        return {"error": out.stderr or out.stdout}


def check(name, ok, detail=""):
    global failures
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else f"  — {detail}"))
    failures += 0 if ok else 1


def fixture():
    path = os.path.join(work, "in.pdf")
    doc = pymupdf.open()
    page = doc.new_page(width=595, height=842)
    page.insert_text((72, 100), "Invoice number 1042", fontname="helv", fontsize=14)
    page.insert_text((72, 120), "Total due RM 250.00", fontname="tibo", fontsize=12, color=(0.8, 0, 0))
    page.insert_text((72, 140), "Thank you for your business", fontname="helv", fontsize=12)
    doc.save(path)
    return path


def pdf_rect(path, page_no, needle):
    """Where a phrase is, in PDF space (what PDFKit would send)."""
    page = pymupdf.open(path)[page_no]
    rect = page.search_for(needle)[0] * ~page.transformation_matrix
    rect.normalize()
    return rect.x0, rect.y0, rect.x1, rect.y1


src = fixture()

print("span-info")
info = run("span-info", src, 0, *pdf_rect(src, 0, "Total due"))
check("finds the whole line", info.get("text") == "Total due RM 250.00", info)
check("reads size and colour", abs(info.get("size", 0) - 12) < 0.1 and info.get("color", [0])[0] > 0.7, info)
check("sees bold", info.get("bold") is True, info)

print("edit-text")
out = os.path.join(work, "edited.pdf")
res = run("edit-text", src, out, 0, *pdf_rect(src, 0, "Total due"), "Total due RM 199.00")
text = pymupdf.open(out)[0].get_text() if os.path.exists(out) else ""
check("command succeeds", res.get("ok"), res)
check("old text is gone, not covered", "250.00" not in text, text)
check("new text is there", "RM 199.00" in text, text)
check("neighbouring lines untouched", "Invoice number 1042" in text and "Thank you for your business" in text, text)
check("keeps a bold serif", res.get("font") == "tibo", res)

print("insert-image")
png = os.path.join(work, "dot.png")
pix = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 20, 20), False)
pix.set_rect(pix.irect, (200, 30, 30))
pix.save(png)
out = os.path.join(work, "image.pdf")
res = run("insert-image", src, out, 0, 300, 600, 400, 700, png)
check("image lands on the page", res.get("ok") and len(pymupdf.open(out)[0].get_images()) == 1, res)

print("compress")
big = os.path.join(work, "big.pdf")
doc = pymupdf.open()
page = doc.new_page()
photo = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 2400, 2400), False)
photo.set_rect(photo.irect, (90, 140, 200))
page.insert_image(pymupdf.Rect(50, 50, 300, 300), pixmap=photo)
doc.save(big)
out = os.path.join(work, "small.pdf")
res = run("compress", big, out)
check("output is smaller", res.get("ok") and res["after"] < res["before"], res)

print("to-docx")
out = os.path.join(work, "out.docx")
res = run("to-docx", src, out)
check("writes a Word file", res.get("ok") and os.path.getsize(out) > 1000, res)

print("ocr-layer")
words = os.path.join(work, "words.json")
with open(words, "w") as f:
    json.dump([{"page": 0, "lines": [{"text": "hidden scanned words", "rect": [72, 400, 300, 418]}]}], f)
out = os.path.join(work, "ocr.pdf")
res = run("ocr-layer", src, out, words)
check("text is searchable", res.get("ok") and pymupdf.open(out)[0].search_for("scanned words"), res)

print("errors")
res = run("span-info", src, 0, 300, 10, 400, 20)
check("an empty spot is a readable error", "no text" in res.get("error", ""), res)

print(f"\n{'all passed' if not failures else f'{failures} failed'}  ({work})")
sys.exit(1 if failures else 0)
