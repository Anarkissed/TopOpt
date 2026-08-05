import re, sys

def strip_comments(src):
    out=[]
    for line in src.split('\n'):
        i=line.find('//')
        out.append(line if i<0 else line[:i])
    return '\n'.join(out)

def body(s, idx):
    depth=0; started=False; out=[]
    for ch in s[idx:]:
        if ch=='{': depth+=1; started=True
        if started: out.append(ch)
        if ch=='}':
            depth-=1
            if depth==0 and started: break
    return ''.join(out)

def decl(code,n):
    i=code.find("var "+n)
    if i<0: i=code.find("func "+n)
    return body(code,i) if i>=0 else ""

# characters of literal prose inside Text(...) — concatenated "a" + "b" counts as one
LIT=re.compile(r'"((?:[^"\\]|\\.)*)"')
def prose_chars(b):
    total=0
    for m in re.finditer(r'Text\(', b):
        # take the balanced-paren argument
        i=m.end(); depth=1; j=i
        while j<len(b) and depth:
            if b[j]=='(': depth+=1
            elif b[j]==')': depth-=1
            j+=1
        arg=b[i:j-1]
        for lit in LIT.findall(arg):
            if lit.startswith('%') or len(lit)<=2:   # format fragments, separators
                continue
            total+=len(lit)
    return total

def controls(b):
    return b.count("Button {")+b.count("Button(action:")+b.count("Slider(")

def report(label, path, spec):
    code=strip_comments(open(path).read())
    chars=0; ctrls=0; rows=[]
    for name,mult in spec:
        b=decl(code,name)
        if not b:
            rows.append((name,mult,'MISSING',0)); continue
        c=prose_chars(b)*mult
        k=controls(b)*mult
        chars+=c; ctrls+=k
        rows.append((name,mult,c,k))
    print(f"--- {label}")
    for n,m,c,k in rows: print(f"  {n:20} x{m}  chars={c:5}  controls={k}")
    print(f"  STANDING PROSE = {chars} chars  (~{round(chars/60)} lines at 60ch)")
    print(f"  CONTROLS AT REST = {ctrls}")
    return chars, ctrls

# instance multipliers = how many times each renders on a page AT REST
r2=[("topLeftColumn",1),("workingOnBar",1),("loadCaseBar",1),("topRightColumn",1),
    ("statusBanner",1),("panelHeader",1),("sellCard",1),("toolsSection",1),
    ("modeTab",3),("sizeButton",2),("regionsSection",1),("protectedSection",1),
    ("actionButton",4)]
r3=[("topLeftColumn",1),("workingOnBar",1),("loadCaseBar",1),("topRightColumn",1),
    ("panelHeader",1),("toolsSection",1),("modeTab",2),("sizeButton",2),
    ("brushFootprint",1),("pencilOnlyRow",1),("receiptToggle",1),
    ("actionButton",3),("entryNotice",1)]
report("ROUND 2 (shipped)", "/tmp/round2page.swift", r2)
report("ROUND 3 (this task)", "app/TopOptKit/Sources/TopOptFlows/SmoothingPage.swift", r3)
