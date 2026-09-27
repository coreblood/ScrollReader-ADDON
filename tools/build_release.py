#!/usr/bin/env python3
"""Build releases/v<version>/ deliverables: addon zip, changelog .txt,
Guide PDF (MANUAL.md + CHANGELOG.md) and nutshell PDF (NUTSHELL.md).
Needs: pip install reportlab.  Usage: python3 tools/build_release.py"""
import os, re, zipfile
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, ListFlowable, ListItem
from reportlab.lib import colors

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON_FILES = ["ScrollReader.toc", "Bindings.xml", "ScrollReader.lua"]
AUTHOR = "Mhortai"

def read(name):
    return open(os.path.join(ROOT, name), encoding="utf-8").read()

VERSION = re.search(r"^## Version:\s*(\S+)", read("ScrollReader.toc"), re.M).group(1)
OUT = os.path.join(ROOT, "releases", "v" + VERSION)

def build_zip():
    path = os.path.join(OUT, f"ScrollReader-v{VERSION}.zip")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(zipfile.ZipInfo("ScrollReader/"), "")
        for f in ADDON_FILES:
            z.write(os.path.join(ROOT, f), "ScrollReader/" + f)

def build_txt():
    t = read("CHANGELOG.md")
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t).replace("`", "")
    t = t.replace("—", "--").replace("→", "->").replace("×", "x")
    open(os.path.join(OUT, "ScrollReader Changelog.txt"), "w", encoding="utf-8").write(t)

# --- tiny markdown -> reportlab ---------------------------------------------
ss = getSampleStyleSheet()
BODY = ParagraphStyle("b", parent=ss["BodyText"], fontSize=10, leading=13.5)
H1 = ParagraphStyle("h1", parent=ss["Title"], fontSize=20, spaceAfter=4)
H2 = ParagraphStyle("h2", parent=ss["Heading2"], fontSize=13.5, spaceBefore=10, spaceAfter=4)
H3 = ParagraphStyle("h3", parent=ss["Heading3"], fontSize=11.5, spaceBefore=8, spaceAfter=3)
SUB = ParagraphStyle("sub", parent=BODY, textColor=colors.grey, alignment=1, spaceAfter=10)

def inline(s):
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"`(.+?)`", r"<font face='Courier'>\1</font>", s)
    s = re.sub(r"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)", r"<i>\1</i>", s)
    return s

def md_flow(md, subtitle=None):
    out, lst, lst_kind = [], [], None
    lines = md.splitlines()
    def flush():
        nonlocal lst, lst_kind
        if lst:
            out.append(ListFlowable([ListItem(Paragraph(inline(x), BODY)) for x in lst],
                       bulletType="1" if lst_kind == "ol" else "bullet", leftIndent=14, bulletFontSize=8))
        lst, lst_kind = [], None
    i = 0
    while i < len(lines):
        ln = lines[i].rstrip()
        m_ul, m_ol = re.match(r"^[-*] (.*)", ln), re.match(r"^\d+\. (.*)", ln)
        if m_ul or m_ol:
            kind = "ul" if m_ul else "ol"
            if lst_kind and lst_kind != kind: flush()
            lst_kind = kind; lst.append((m_ul or m_ol).group(1)); i += 1; continue
        flush()
        if ln.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if not all(re.match(r"^:?-+:?$", c) for c in cells):
                    rows.append([Paragraph(inline(c), BODY) for c in cells])
                i += 1
            t = Table(rows, colWidths=[45 * mm, None], hAlign="LEFT")
            t.setStyle(TableStyle([("GRID", (0, 0), (-1, -1), 0.4, colors.lightgrey),
                                   ("BACKGROUND", (0, 0), (-1, 0), colors.whitesmoke),
                                   ("VALIGN", (0, 0), (-1, -1), "TOP")]))
            out.append(t); continue
        if ln.startswith("# "):
            out.append(Paragraph(inline(ln[2:]), H1))
            if subtitle: out.append(Paragraph(subtitle, SUB))
        elif ln.startswith("## "): out.append(Paragraph(inline(ln[3:]), H2))
        elif ln.startswith("### "): out.append(Paragraph(inline(ln[4:]), H3))
        elif ln: out.append(Paragraph(inline(ln), BODY)); out.append(Spacer(1, 4))
        i += 1
    flush()
    return out

def pdf(name, title, flow):
    doc = SimpleDocTemplate(os.path.join(OUT, name), pagesize=A4, title=title, author=AUTHOR,
                            leftMargin=18 * mm, rightMargin=18 * mm, topMargin=16 * mm, bottomMargin=16 * mm)
    doc.build(flow)

def build_guide():
    man = read("MANUAL.md")
    man = re.sub(r"^# .*\n", "# ScrollReader Guide\n", man, count=1)
    man = re.sub(r"^\*\*Version:\*\*.*\n", "", man, flags=re.M)
    cl = re.sub(r"^# .*\n", "", read("CHANGELOG.md"), count=1)
    cl = re.sub(r"^## ", "### ", cl, flags=re.M)
    sub = f"Version {VERSION} · WotLK 3.3.5a · Uncapped server · by {AUTHOR}"
    pdf("ScrollReader Guide.pdf", "ScrollReader Guide", md_flow(man + "\n## Changelog\n" + cl, sub))

def build_nutshell():
    md = read("NUTSHELL.md")
    md = re.sub(r"^by .*\n", "", md, flags=re.M)
    pdf("ScrollReader in a nutshell.pdf", "ScrollReader in a nutshell", md_flow(md, f"by {AUTHOR}"))

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build_zip(); build_txt(); build_guide(); build_nutshell()
    print("built", OUT)
