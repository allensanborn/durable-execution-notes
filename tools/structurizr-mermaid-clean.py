#!/usr/bin/env python3
"""Convert Structurizr's Mermaid export into GitHub-safe Mermaid.

Structurizr emits node/edge labels as HTML <div> stacks. GitHub renders Mermaid with
htmlLabels disabled, so that markup shows up as literal &lt;div&gt; text. This rewrites
those label stacks into plain text separated by <br/>, which Mermaid honours in both
modes, and drops the hardcoded white fills that break dark themes.
"""
import re, sys

DIV = re.compile(r"<div[^>]*>(.*?)</div>", re.S)

def flatten(label: str) -> str:
    parts = [re.sub(r"<[^>]+>", "", p).strip() for p in DIV.findall(label)]
    parts = [p for p in parts if p]
    return "<br/>".join(parts) if parts else re.sub(r"<[^>]+>", "", label).strip()

def convert(src: str, keep_style: bool = False) -> str:
    out = []
    for line in src.splitlines():
        if not keep_style and re.match(r"\s*(style \S+ fill:|linkStyle default)", line):
            continue
        # node labels:  1["<div ...>...</div>"]
        line = re.sub(r'\["(.*?)"\]', lambda m: '["%s"]' % flatten(m.group(1)), line)
        # edge labels:  -. "<div>..</div>" .->
        line = re.sub(r'"(<div.*?)"', lambda m: '"%s"' % flatten(m.group(1)), line)
        out.append(line)
    return "\n".join(out)

if __name__ == "__main__":
    sys.stdout.write(convert(open(sys.argv[1]).read()))
