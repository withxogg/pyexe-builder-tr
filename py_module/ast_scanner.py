import ast, sys, io, json
files = sys.argv[1:]
out = set()
def add_module(mod):
    if not mod: return
    parts = mod.split('.')
    if not parts[0]: return
    out.add(parts[0])
    if len(parts) >= 2: out.add('.'.join(parts[:2]))
    if len(parts) >= 3: out.add('.'.join(parts[:3]))
for f in files:
    try:
        with io.open(f, 'r', encoding='utf-8', errors='replace') as fh:
            src = fh.read()
    except Exception:
        continue
    try:
        tree = ast.parse(src, filename=f)
    except Exception:
        import re
        for line in src.splitlines():
            m = re.match(r'^\s*import\s+([A-Za-z_][\w\.]*(?:\s*,\s*[A-Za-z_][\w\.]*)*)', line)
            if m:
                for part in m.group(1).split(','):
                    add_module(part.strip().split(' as ')[0].strip())
            m = re.match(r'^\s*from\s+(\.*)([A-Za-z_][\w\.]*)\s+import', line)
            if m and not m.group(1):
                add_module(m.group(2))
        continue
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names: add_module(a.name)
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0 and node.module: add_module(node.module)
        elif isinstance(node, ast.Call):
            try:
                if isinstance(node.func, ast.Name) and node.func.id == '__import__':
                    if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                        add_module(node.args[0].value)
                elif isinstance(node.func, ast.Attribute) and node.func.attr == 'import_module':
                    if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                        add_module(node.args[0].value)
            except Exception:
                pass
print(json.dumps(sorted(out)))
