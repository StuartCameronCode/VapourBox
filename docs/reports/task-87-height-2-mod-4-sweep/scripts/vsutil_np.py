import hashlib, array
def plane_rows(f, p):
    m = memoryview(f[p])
    h, w = m.shape
    code = {'B': 'B', 'H': 'H', 'f': 'f'}[m.format]
    rows = []
    for y in range(h):
        a = array.array(code)
        a.frombytes(m[y].tobytes()) if False else None
        rows.append([m[y, x] for x in range(w)])
    return rows
def md5(rows):
    return hashlib.md5(repr(rows).encode()).hexdigest()[:8]
