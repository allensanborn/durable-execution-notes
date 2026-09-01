#!/usr/bin/env python3
"""Convert Structurizr's Mermaid export into GitHub-safe Mermaid.

Two problems with the raw export, both verified by rendering with htmlLabels disabled:

1. Node and edge labels are HTML <div> stacks. GitHub renders Mermaid with htmlLabels
   off, so that markup shows up as literal &lt;div&gt; text. They are rewritten into
   plain text separated by <br/>, which Mermaid honours in both modes.
2. Every element carries a hardcoded `fill:#ffffff` plus Structurizr's default dark-grey
   stroke and text (#444444), which is unreadable on a dark background. Those defaults
   are dropped so the diagram inherits the reader's theme. Fills that carry meaning
   (a tagged style in the DSL, e.g. grey for external systems) are kept.

Two things the exporter flattens, both of which carry meaning in the DSL:

- It emits no element border style, so a `border dashed` is lost. `--dash-stroke
  <#rrggbb>` restores it: any element whose stroke is that colour gets a dashed border.
- It emits *every* relationship as a dotted arrow, so a `style dashed` on a relationship
  is indistinguishable from a solid one. Arrows are therefore rewritten solid, and
  `--dash-edge <regex>` puts the dashes back on the subset whose label matches.

Together those are how a "Proposed" tag stays visually distinct from a shipping one.

Usage:
    structurizr-mermaid-clean.py <file.mmd> [--dash-stroke '#b3591a']
                                            [--dash-edge '^PROPOSED'] [--keep-style]
Writes to stdout.
"""
import re
import sys

DIV = re.compile(r"<div[^>]*>(.*?)</div>", re.S)
STYLE = re.compile(r"^(\s*)style (\S+) (.*)$")
EDGE = re.compile(r'^(\s*)(\S+?)-\. "(.*)" \.->(\S+)$')

# Structurizr's defaults, not a deliberate choice in the DSL: a white background, a dark
# grey that vanishes on a dark theme, and a near-white group label that vanishes on a light
# one. Dropping them lets the element inherit the reader's theme instead.
DEFAULT_PROPS = {"fill:#ffffff", "stroke:#ffffff", "stroke:#444444", "color:#444444",
                 "color:#cccccc"}


BR = re.compile(r"<br\s*/?>", re.I)


def strip_tags(fragment: str) -> str:
    """Drop markup, but keep Structurizr's own line wrapping as real <br/> breaks."""
    return re.sub(r"<[^>]+>", "", BR.sub("\x00", fragment)).strip().replace("\x00", "<br/>")


def flatten(label: str) -> str:
    parts = [strip_tags(p) for p in DIV.findall(label)]
    parts = [p for p in parts if p]
    return "<br/>".join(parts) if parts else strip_tags(label)


def clean_style(line: str, dash_stroke: str | None) -> str | None:
    """Strip theme-hostile defaults from one `style <id> ...` line.

    Returns the rewritten line, or None if nothing meaningful is left.
    """
    m = STYLE.match(line)
    if not m:
        return line
    indent, target, props = m.groups()
    kept = [p.strip() for p in props.split(",") if p.strip() and p.strip() not in DEFAULT_PROPS]
    if dash_stroke and any(p.replace(" ", "").lower() == "stroke:" + dash_stroke.lower() for p in kept):
        kept.append("stroke-dasharray: 6 4")
    if not kept:
        return None
    return "%sstyle %s %s" % (indent, target, ",".join(kept))


def convert(src: str, keep_style: bool = False, dash_stroke: str | None = None,
            dash_edge: str | None = None) -> str:
    dash_edge_re = re.compile(dash_edge) if dash_edge else None
    out = []
    for line in src.splitlines():
        if not keep_style:
            if re.match(r"\s*linkStyle default", line):
                continue
            if STYLE.match(line):
                line = clean_style(line, dash_stroke)
                if line is None:
                    continue
        # node labels:  1["<div ...>...</div>"]
        line = re.sub(r'\["(.*?)"\]', lambda m: '["%s"]' % flatten(m.group(1)), line)
        # edge labels:  -. "<div>..</div>" .->
        line = re.sub(r'"(<div.*?)"', lambda m: '"%s"' % flatten(m.group(1)), line)
        edge = EDGE.match(line)
        if edge:
            indent, src_id, label, dst_id = edge.groups()
            arrow = "-.->" if dash_edge_re and dash_edge_re.search(label) else "-->"
            line = '%s%s %s|"%s"| %s' % (indent, src_id, arrow, label, dst_id)
        out.append(line)
    return "\n".join(out)


if __name__ == "__main__":
    args = sys.argv[1:]
    keep_style = "--keep-style" in args
    args = [a for a in args if a != "--keep-style"]
    dash = None
    if "--dash-stroke" in args:
        i = args.index("--dash-stroke")
        dash = args[i + 1]
        del args[i:i + 2]
    dash_edge = None
    if "--dash-edge" in args:
        i = args.index("--dash-edge")
        dash_edge = args[i + 1]
        del args[i:i + 2]
    sys.stdout.write(convert(open(args[0]).read(), keep_style=keep_style,
                             dash_stroke=dash, dash_edge=dash_edge))
