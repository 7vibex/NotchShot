"""Summarise an Animation Hitches trace for one process.

usage: hitch-summary.py <trace> [process-substring]   (or: hitch-summary.py --xml <file> [process])
For each table, prints rows (all, and those for the process when the table has
a process column) and the sum and max of the duration column.
"""
import subprocess, sys, xml.etree.ElementTree as ET

TABLES = ["hitches", "hitches-updates", "hitches-renders", "hang-risks", "potential-hangs",
          "displayed-surfaces-interval"]

def rows(root):
    ids = {}
    schema = root.find(".//schema")
    if schema is None:
        return [], []
    cols = [c.findtext("mnemonic") for c in schema.findall("col")]
    out = []
    for row in root.iter("row"):
        vals = {}
        for col, el in zip(cols, list(row)):
            if "ref" in el.attrib:
                el = ids.get(el.attrib["ref"], el)
            for sub in el.iter():
                if "id" in sub.attrib:
                    ids[sub.attrib["id"]] = sub
            vals[col] = (el.attrib.get("fmt", ""), (el.text or "").strip())
        out.append(vals)
    return cols, out

def summarise(name, root, proc):
    cols, data = rows(root)
    if not cols:
        print(f"{name}: no table")
        return
    line = f"{name}: {len(data)} rows"
    if "process" in cols:
        data = [r for r in data if proc in r.get("process", ("", ""))[0]]
        line += f", {len(data)} for {proc}"
    if "duration" in cols and data:
        ns = [int(r["duration"][1]) for r in data if r.get("duration", ("", ""))[1].isdigit()]
        if ns:
            line += f", total {sum(ns)/1e6:.1f} ms, max {max(ns)/1e6:.1f} ms"
    print(line)
    if name in ("hitches", "hang-risks", "potential-hangs"):
        for r in data[:12]:
            print("   ", r.get("start", ("",))[0], r.get("duration", ("",))[0],
                  r.get("narrative-description", r.get("narrative", ("",)))[0][:120])

proc = "NotchShot"
if sys.argv[1] == "--xml":
    if len(sys.argv) > 3: proc = sys.argv[3]
    summarise(sys.argv[2], ET.parse(sys.argv[2]).getroot(), proc)
    sys.exit()
trace = sys.argv[1]
if len(sys.argv) > 2: proc = sys.argv[2]
for t in TABLES:
    xp = f'/trace-toc/run[@number="1"]/data/table[@schema="{t}"]'
    res = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xp],
                         capture_output=True, text=True)
    try:
        summarise(t, ET.fromstring(res.stdout), proc)
    except ET.ParseError:
        print(f"{t}: export failed {res.stderr.strip()[:100]}")
