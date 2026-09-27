#!/usr/bin/env python3
"""regcheck -- check the register contracts of a vasm (Motorola syntax) program.

Usage, from the project dir (include paths resolve from there, as in
vasm):

    python ../tools/regcheck.py [-Dsym=value ...] [-v] <name>.asm

Every routine entered with bsr/jsr, every fall-through entry and every
macro that expands to code carries a contract in the comment block right
above its label (CLAUDE.md, "Register contracts"):

    ; In:      d0.w = w, a0 = record
    ; Out:     a0 = next record (+12)
    ; Trashes: d0, d1, d4

The lists are complete: a register not in Out or Trashes is preserved.
The program is read as vasm reads it (includes, macros, rept and
conditional assembly expanded, -D as on the vasm command line), then:

  contract  whatever a routine or macro may write -- its instructions on
            every path, (an)+/-(an) side effects, the contracts of what
            it calls or tail-branches to -- is in its Out or Trashes; a
            register pushed and popped back counts as preserved
  callers   at every call site no register of the callee's Trashes is
            still live (read again before being rewritten), and the
            condition codes are not live across the call unless its Out
            names CCR; the same at every exit of every macro use
  stack     the stack is balanced at every rts and tail branch
  presence  every bsr/jsr target and every code macro has a contract

A reviewed false positive is silenced by a comment on the reported line
(the call, the rts, the macro use) or in the routine's contract block:
"; regcheck-ok: d6 -- why" (registers, ccr, or stack). -v lists what
each routine changes and the registers live after every call. Not
modelled: TRAP (QDOS calls), indirect jumps and calls (warned),
self-modifying code, values passed through memory. Exit status 1 when
a problem is reported.
"""

import re
import sys

CCR = "ccr"
SP = "sp"
ALL_REGS = frozenset([f"d{i}" for i in range(8)] + [f"a{i}" for i in range(7)])

BCC = {"beq", "bne", "bmi", "bpl", "bge", "bgt", "ble", "blt", "bhi", "bls",
       "bcc", "bcs", "bhs", "blo", "bvc", "bvs"}
CONDS = ("t", "f", "eq", "ne", "mi", "pl", "ge", "gt", "le", "lt", "hi",
         "ls", "cc", "cs", "hs", "lo", "vc", "vs")
DBCC = {"db" + c for c in CONDS} | {"dbra"}
SCC = {"s" + c for c in CONDS}
RMW2 = {"add", "adda", "addi", "addq", "addx", "sub", "suba", "subi", "subq",
        "subx", "and", "andi", "or", "ori", "eor", "eori", "muls", "mulu",
        "divs", "divu", "asl", "asr", "lsl", "lsr", "rol", "ror", "roxl",
        "roxr", "bset", "bclr", "bchg", "abcd", "sbcd"}
RMW1 = {"neg", "negx", "not", "ext", "extb", "swap", "tas", "nbcd"}
TESTS = {"tst", "cmp", "cmpa", "cmpi", "cmpm", "btst", "chk"}
X_USERS = {"addx", "subx", "negx", "roxl", "roxr", "abcd", "sbcd", "nbcd"}
OTHER = {"trap", "nop", "reset", "stop", "illegal", "link", "unlk"}
DATA_DIRS = {"dc", "ds", "dcb", "blk", "incbin", "even", "odd", "cnop",
             "align"}
QUIET_DIRS = {"section", "org", "opt", "xdef", "xref", "public", "fail",
              "printt", "echo", "list", "nolist", "idnt", "ttl", "plen",
              "llen", "page", "spc", "output", "rsreset", "rsset", "offset",
              "near", "far", "basereg", "endb", "inline", "einline",
              "machine", "mc68000", "mc68008", "cpu"}
COND_DIRS = {"if", "ifeq", "ifne", "ifgt", "ifge", "iflt", "ifle", "ifd",
             "ifnd"}


class Unknown(Exception):
    """An expression refers to something regcheck can't evaluate."""


# -------------------------------------------------------------- expressions
# vasm's precedence, loosest first (checked against vasm 2.0f): shifts
# bind tighter than & ^ |, which bind tighter than * / %; true is -1;
# / and % truncate toward zero.

LEVELS = [("||",), ("&&",), ("==", "=", "!="), ("<", ">", "<=", ">="),
          ("+", "-"), ("*", "/", "%"), ("|",), ("^",), ("&",), ("<<", ">>")]
TOKEN = re.compile(r"""\s*(?:(?P<num>\$[0-9a-fA-F]+|%[01]+|@[0-7]+|\d+)
                   |(?P<chr>'[^']*'|"[^"]*")
                   |(?P<sym>[A-Za-z_.][\w.$]*)
                   |(?P<op><<|>>|<=|>=|==|!=|&&|\|\||[-+*/%&|^~!<>=()]))""",
                   re.X)


def evaluate(text, symbols):
    toks, pos, text = [], 0, text.strip()
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m or m.end() == pos:
            raise Unknown(text)
        pos = m.end()
        kind = m.lastgroup
        toks.append((kind, m.group(kind)))
    toks.append(("end", None))
    at = [0]

    def take():
        at[0] += 1
        return toks[at[0] - 1]

    def primary():
        kind, t = take()
        if t == "(":
            v = level(0)
            if take()[1] != ")":
                raise Unknown(text)
            return v
        if t in ("-", "+", "~", "!"):
            v = primary()
            return {"-": -v, "+": v, "~": ~v, "!": int(v == 0)}[t]
        if kind == "num":
            base = {"$": 16, "%": 2, "@": 8}.get(t[0])
            return int(t[1:], base) if base else int(t)
        if kind == "chr":
            v = 0
            for ch in t[1:-1]:
                v = (v << 8) | ord(ch)
            return v
        if kind == "sym" and symbols.get(t) is not None:
            return symbols[t]
        raise Unknown(t)

    def level(k):
        if k == len(LEVELS):
            return primary()
        v = level(k + 1)
        while toks[at[0]][0] == "op" and toks[at[0]][1] in LEVELS[k]:
            v = binop(take()[1], v, level(k + 1))
        return v

    v = level(0)
    if toks[at[0]][0] != "end":
        raise Unknown(text)
    return v


def binop(op, a, b):
    if op in ("/", "%"):
        if b == 0:
            raise Unknown("division by zero")
        q, r = abs(a) // abs(b), abs(a) % abs(b)
        if op == "/":
            return q if (a < 0) == (b < 0) else -q
        return r if a >= 0 else -r
    if op in ("<<", ">>") and b < 0:
        raise Unknown("negative shift")
    return {"+": lambda: a + b, "-": lambda: a - b, "*": lambda: a * b,
            "<<": lambda: a << b, ">>": lambda: a >> b,
            "&": lambda: a & b, "^": lambda: a ^ b, "|": lambda: a | b,
            "<": lambda: -int(a < b), ">": lambda: -int(a > b),
            "<=": lambda: -int(a <= b), ">=": lambda: -int(a >= b),
            "==": lambda: -int(a == b), "=": lambda: -int(a == b),
            "!=": lambda: -int(a != b),
            "&&": lambda: -int(bool(a) and bool(b)),
            "||": lambda: -int(bool(a) or bool(b))}[op]()


# ------------------------------------------------------------------ syntax

def norm_reg(r):
    r = r.lower()
    return SP if r in ("a7", "sp") else r


def reglist(text):
    """Registers named in text: 'd0-d3/a0', 'd0-d4, a0, a1', prose."""
    regs = set()
    for m in re.finditer(r"\b([da])([0-7])(?:\s*-\s*([da])([0-7]))?\b",
                         text, re.I):
        k1, n1 = m.group(1).lower(), int(m.group(2))
        k2, n2 = m.group(3), m.group(4)
        if k2 and k2.lower() == k1:
            regs.update(f"{k1}{i}" for i in range(n1, int(n2) + 1))
        else:
            regs.add(f"{k1}{n1}")
            if k2:
                regs.add(f"{k2.lower()}{n2}")
    return {norm_reg(r) for r in regs}


def strip_comment(text):
    quote = None
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == ";":
            return text[:i], text[i + 1:]
    return text, ""


def split_line(text):
    """-> (label, op, args, comment); op None for comment/blank lines."""
    if text[:1] == "*":
        return None, None, "", text[1:]
    code, comment = strip_comment(text)
    if not code.strip():
        return None, None, "", comment
    label, rest = None, code
    if not code[0].isspace():
        m = re.match(r"([^\s:]+):?", code)
        label, rest = m.group(1), code[m.end():]
    else:
        m = re.match(r"\s*([A-Za-z_.][\w.$]*):(?=\s|$)", code)
        if m:
            label, rest = m.group(1), code[m.end():]
    parts = rest.split(None, 1)
    return (label, parts[0] if parts else "",
            parts[1].strip() if len(parts) > 1 else "", comment)


def split_ops(args):
    ops, depth, cur, quote = [], 0, "", None
    for ch in args:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "," and depth == 0:
            ops.append(cur.strip())
            cur = ""
            continue
        cur += ch
    if cur.strip():
        ops.append(cur.strip())
    return ops


def suppressed(text):
    """Registers named by '; regcheck-ok: d6, ccr -- why' in text."""
    m = re.search(r"regcheck-ok:\s*(.*?)(?:--|$)", text or "")
    if not m:
        return set()
    return reglist(m.group(1)) | ({CCR} if re.search(r"\bccr\b", m.group(1),
                                                     re.I) else set())


# --------------------------------------------------------------- contracts

KEY = re.compile(r";\s*(In|Out|Trashes):\s*(.*)$")


class Contract:
    def __init__(self, fields, block):
        self.ins = reglist(fields["In"])
        self.outs = reglist(fields["Out"])
        self.trashes = reglist(fields["Trashes"])
        self.ccr_out = bool(re.search(r"\bccr\b|\b[XNZVC] (?:set|clear|flag)",
                                      fields["Out"], re.I))
        self.ok = set().union(*(suppressed(line) for line in block))
        self.changes = self.outs | self.trashes


def parse_contract(block):
    """-> (Contract or None, malformed?) from the comment block above."""
    fields, cur = {}, None
    for line in block:
        m = KEY.match(line.strip())
        if m:
            cur = m.group(1)
            fields[cur] = m.group(2)
        elif cur and re.match(r";\s{3,}\S", line):
            fields[cur] += " " + line.strip()[1:].strip()
        else:
            cur = None
    if not fields:
        return None, False
    if len(fields) < 3:
        return None, True
    return Contract(fields, block), False


# ------------------------------------------------------------ preprocessor

class Ins:
    """One source line as assembled (after macro and rept expansion)."""

    def __init__(self, where, label, op, size, args, comment, block, exp):
        self.where = where          # (file, line) to report
        self.label = label
        self.op = op                # lower case, no size; '' = label only
        self.size = size
        self.args = args
        self.ops = split_ops(args)
        self.comment = comment
        self.block = block          # comment lines right above
        self.exp = exp              # innermost macro expansion, or None

    def text(self):
        return (self.op + ("." + self.size if self.size else "") + " "
                + self.args).strip()


class Macro:
    def __init__(self, name, body, block, where):
        self.name, self.body, self.where = name, body, where
        self.contract, self.malformed = parse_contract(block)
        self.uses = []


class Expansion:
    def __init__(self, macro, where, comment, start):
        self.macro, self.where, self.comment = macro, where, comment
        self.start = self.end = start


class Program:
    def __init__(self, defines):
        self.sym = dict(defines)
        self.defined = set(defines)
        self.macros = {}
        self.ins = []
        self.expansions = []
        self.warnings = []
        self.uid = 0
        self.ended = False

    def warn(self, where, msg):
        self.warnings.append((where, msg))

    def load(self, fname, where=None):
        try:
            with open(fname, encoding="latin-1") as f:
                lines = f.read().splitlines()
        except OSError as e:
            at = f"{loc(where)}: " if where else ""
            raise SystemExit(f"regcheck: {at}cannot open {fname}: {e.strerror}")
        self.run([((fname, n), t) for n, t in enumerate(lines, 1)], None)

    def collect(self, src, i, opener, closer):
        """Body lines up to the matching closer, and the index after it."""
        body, depth = [], 0
        while i < len(src):
            op = split_line(src[i][1])[1]
            base = (op or "").lower().partition(".")[0]
            i += 1
            if base == opener:
                depth += 1
            elif base == closer:
                if depth == 0:
                    return body, i
                depth -= 1
            body.append(src[i - 1])
        self.warn(src[-1][0], f"no {closer} before the end")
        return body, i

    def run(self, src, exp, report=None):
        """Assemble (where, text) lines; report overrides where (macros)."""
        conds, block, i = [], [], 0
        while i < len(src) and not self.ended:
            where, text = src[i]
            i += 1
            at = report or where
            label, op, args, comment = split_line(text)
            active = conds[-1][0] if conds else True
            if op is None:
                if active:
                    block = block + [text] if text.strip() else []
                continue
            base, _, size = op.lower().partition(".")
            if base in COND_DIRS:
                v = active and self.cond(base, args, at)
                conds.append([v, v, active])
                continue
            if base == "else" and conds:
                c = conds[-1]
                c[0], c[1] = c[2] and not c[1], True
                continue
            if base in ("endc", "endif") and conds:
                conds.pop()
                continue
            if not active:
                continue
            if label and base in ("equ", "set", "="):
                try:
                    self.sym[label] = evaluate(args, self.sym)
                except Unknown:
                    self.sym[label] = None
                self.defined.add(label)
            elif label and base == "macro":
                body, i = self.collect(src, i, "macro", "endm")
                self.macros[label.lower()] = Macro(label, body, block, at)
            elif base == "rept":
                body, i = self.collect(src, i, "rept", "endr")
                try:
                    count = evaluate(args, self.sym)
                except Unknown:
                    self.warn(at, f"cannot evaluate 'rept {args}', expanding once")
                    count = 1
                for _ in range(max(count, 0)):
                    self.run(body, exp, report)
            elif base == "include":
                self.load(args.strip().strip("\"'"), at)
            elif base == "end":
                self.ended = True
            elif base in self.macros:
                if label:
                    self.emit(at, label, "", "", "", comment, block, exp)
                self.expand(self.macros[base], size, args, at, comment)
            else:
                self.emit(at, label, base, size, args, comment, block, exp)
            block = []

    def emit(self, where, label, op, size, args, comment, block, exp):
        if label:
            self.defined.add(label)
        self.ins.append(Ins(where, label, op, size, args, comment, block, exp))

    def expand(self, macro, size, args, where, comment):
        self.uid += 1
        argv = split_ops(args)

        def sub(m):
            c = m.group(1)
            if c == "@":
                return f"_{self.uid:05d}"
            if c == "0":
                return size
            k = int(c)
            return argv[k - 1] if k <= len(argv) else ""

        body = [(w, re.sub(r"\\([0-9@])", sub, t)) for w, t in macro.body]
        exp = Expansion(macro, where, comment, len(self.ins))
        self.run(body, exp, where)
        exp.end = len(self.ins)
        self.expansions.append(exp)
        macro.uses.append(exp)

    def cond(self, base, args, where):
        if base in ("ifd", "ifnd"):
            return (args.strip() in self.defined) == (base == "ifd")
        try:
            v = evaluate(args, self.sym)
        except Unknown:
            self.warn(where, f"cannot evaluate '{base} {args}', assembling the "
                             f"block (a -D missing?)")
            return True
        return {"if": v != 0, "ifeq": v == 0, "ifne": v != 0, "ifgt": v > 0,
                "ifge": v >= 0, "iflt": v < 0, "ifle": v <= 0}[base]


# ------------------------------------------------------------- instructions

class Operand:
    def __init__(self, text):
        self.text = text
        low = text.lower().replace(" ", "")
        self.kind, self.reg, self.uses, self.defs = "mem", None, set(), set()
        if low.startswith("#"):
            self.kind = "imm"
        elif re.fullmatch(r"d[0-7]|a[0-7]|sp", low):
            self.kind, self.reg = "reg", norm_reg(low)
        elif low in ("sr", "ccr", "usp"):
            self.kind, self.reg = "special", low
        elif re.fullmatch(r"-\((a[0-7]|sp)\)", low):
            self.kind, self.reg = "predec", norm_reg(low[2:-1])
        elif re.fullmatch(r"\((a[0-7]|sp)\)\+", low):
            self.kind, self.reg = "postinc", norm_reg(low[1:-2])
        else:
            for group in re.findall(r"\(([^()]*)\)", low):
                self.uses |= {norm_reg(r) for r in
                              re.findall(r"\b(d[0-7]|a[0-7]|sp)\b", group)}
        if self.kind in ("predec", "postinc"):
            self.uses, self.defs = {self.reg}, {self.reg}
        self.is_list = bool(re.fullmatch(
            r"([da][0-7]|sp)(-[da][0-7])?(/([da][0-7]|sp)(-[da][0-7])?)*", low))

    def is_sp(self, kind):
        return self.kind == kind and self.reg == SP


def nbytes(size, count=1):
    return (4 if size == "l" else 2) * count


def analyze(ins, prog):
    """uses/defs (ccr included), flow, target and stack effects of ins.
    A register pushed on the stack is not a use here: push_regs holds it,
    and it counts as read only if its value is needed after the pop."""
    op, size = ins.op, ins.size
    ins.uses, ins.defs, ins.stack, ins.push_regs = set(), set(), [], set()
    ins.flow, ins.target, ins.reads_stack = "next", None, False
    if op == "" or op in QUIET_DIRS:
        return
    if op in DATA_DIRS:
        ins.flow = "data"
        return
    P = [Operand(o) for o in ins.ops]
    for p in P:
        ins.uses |= p.uses
        ins.defs |= p.defs
    src = P[0] if P else None
    dst = P[-1] if P else None
    ins.reads_stack = op not in ("lea", "pea") and any(
        p.kind == "mem" and SP in p.uses for p in P)

    def reg_use(p):
        if p.kind == "reg":
            ins.uses.add(p.reg)
        elif p.kind == "special" and p.reg in ("sr", "ccr"):
            ins.uses.add(CCR)

    def reg_def(p):
        if p.kind == "reg":
            ins.defs.add(p.reg)
        elif p.kind == "special" and p.reg in ("sr", "ccr"):
            ins.defs.add(CCR)

    def imm(p):
        try:
            return evaluate(p.text[1:], prog.sym) if p.kind == "imm" else None
        except Unknown:
            return None

    def branch(p):
        m = re.fullmatch(r"([A-Za-z_.][\w.$]*)(\(pc(,[^)]*)?\))?", p.text,
                         re.I)
        if not m:
            return None
        t = m.group(1)
        return f"{ins.glob}{t}" if t.startswith(".") else t

    if op in ("move", "movea") and len(P) == 2:
        if dst.is_sp("predec") and src.kind == "reg":
            ins.push_regs = {src.reg}
        else:
            reg_use(src)
        reg_def(dst)
        if not (dst.kind == "reg" and dst.reg[0] in "as") and dst.kind != "special":
            ins.defs.add(CCR)
        if dst.is_sp("predec"):
            ins.stack.append(("push", {src.reg} if src.kind == "reg" else None,
                              nbytes(size)))
        if src.is_sp("postinc"):
            ins.stack.append(("pop", {dst.reg} if dst.kind == "reg" else None,
                              nbytes(size)))
        if dst.kind == "reg" and dst.reg == SP:
            ins.stack.append(("unknown",) if SP in src.uses or src.kind == "reg"
                             else ("reset",))
    elif op == "moveq":
        reg_def(dst)
        ins.defs.add(CCR)
    elif op == "lea":
        reg_def(dst)
        if dst.reg == SP:
            m = re.fullmatch(r"(-?\w+)\(sp\)", src.text.replace(" ", ""), re.I)
            try:
                n = evaluate(m.group(1), prog.sym) if m else None
            except Unknown:
                n = None
            ins.stack.append(("drop", n) if n is not None and n >= 0 else
                             ("grow", -n) if n is not None else
                             ("unknown",) if SP in src.uses else ("reset",))
    elif op == "pea":
        ins.stack.append(("push", None, 4))
    elif op == "clr" or op in SCC:
        reg_def(dst)
        if op == "clr":
            ins.defs.add(CCR)
        else:
            ins.uses.add(CCR)
        if dst.is_sp("predec"):
            ins.stack.append(("push", None, nbytes(size)))
    elif op in RMW2 and len(P) == 2:
        if not (op in ("sub", "suba", "eor") and src.kind == dst.kind == "reg"
                and src.reg == dst.reg):        # x-x, x^x: zeroing, no read
            reg_use(src)
            reg_use(dst)
        reg_def(dst)
        if not (op in ("adda", "suba") or (dst.kind == "reg" and dst.reg[0] in "as"
                                            and op in ("addq", "subq", "add", "sub"))):
            ins.defs.add(CCR)
        if op in X_USERS:
            ins.uses.add(CCR)
        if dst.kind == "reg" and dst.reg == SP:
            n = imm(src)
            add = op.startswith("add")
            ins.stack.append(("unknown",) if n is None else
                             ("drop", n) if add == (n >= 0) else ("grow", abs(n)))
    elif op in RMW2 or op in RMW1:
        reg_use(dst)
        reg_def(dst)
        ins.defs.add(CCR)
        if op in X_USERS:
            ins.uses.add(CCR)
    elif op in TESTS:
        for p in P:
            reg_use(p)
        ins.defs.add(CCR)
    elif op == "exg":
        for p in P:
            reg_use(p)
            reg_def(p)
    elif op == "movem" and len(P) == 2:
        if src.is_list:
            regs = reglist(src.text)
            if dst.is_sp("predec"):
                ins.push_regs = set(regs)
                ins.stack.append(("push", regs, nbytes(size, len(regs))))
            else:
                ins.uses |= regs
        else:
            regs = reglist(dst.text)
            ins.defs |= regs
            if src.is_sp("postinc"):
                ins.stack.append(("pop", regs, nbytes(size, len(regs))))
    elif op in ("bra", "jmp", "bsr", "jsr") or op in BCC or op in DBCC:
        p = P[-1]
        ins.target = branch(p)
        if op in DBCC:
            reg_use(src)
            reg_def(src)
        if (op in BCC or op in DBCC) and op not in ("dbf", "dbra", "dbt"):
            ins.uses.add(CCR)
        call = op in ("bsr", "jsr")
        if ins.target is None:
            ins.flow = "icall" if call else "ijump"
        else:
            ins.flow = ("call" if call else "jump" if op in ("bra", "jmp")
                        else "cjump")
    elif op in ("rts", "rte", "rtr"):
        ins.flow = "ret"
        if op != "rts":
            ins.defs.add(CCR)
    elif op in OTHER:
        pass
    else:
        prog.warn(ins.where, f"'{ins.text()}' not modelled: its register "
                             f"operands count as read and written")
        for p in P:
            reg_use(p)
            reg_def(p)
        ins.defs.add(CCR)
    ins.uses.discard(SP)
    ins.defs.discard(SP)


# ---------------------------------------------------------------- analysis

def merge_stack(a, b):
    if a is None or b is None or len(a) != len(b):
        return None
    out = []
    for (ra, na, sa), (rb, nb, sb) in zip(a, b):
        if ra != rb or na != nb:
            return None
        out.append((ra, na, sa | sb))
    return tuple(out)


def apply_stack(ins, W, S):
    """Stack effects of ins on (writes, stack) -> (W, S, restored regs)."""
    restored = {}
    for eff in ins.stack:
        if S is None:
            break
        kind = eff[0]
        if kind == "push":
            S = S + ((frozenset(eff[1]) if eff[1] else None, eff[2], W),)
        elif kind == "grow":
            S = S + ((None, eff[1], W),)
        elif kind == "pop":
            regs, n = eff[1], eff[2]
            if S and S[-1][1] == n:
                top_regs, _, snap = S[-1]
                S = S[:-1]
                if regs and top_regs == frozenset(regs):
                    for r in regs:
                        restored[r] = r in snap
            else:
                S = None
        elif kind == "drop":
            n = eff[1]
            while S and n > 0 and S[-1][1] <= n:
                n -= S[-1][1]
                S = S[:-1]
            if n:
                S = None
        elif kind == "reset":
            S = ()
        else:
            S = None
    return W, S, restored


class Checker:
    def __init__(self, prog, verbose):
        self.prog, self.verbose = prog, verbose
        self.problems, self.member_memo = [], {}
        ins = prog.ins
        glob = None
        self.index = {}
        for k, i in enumerate(ins):
            if i.label:
                if i.label.startswith("."):
                    i.label = f"{glob}{i.label}"
                else:
                    glob = i.label
                if i.label in self.index:
                    prog.warn(i.where, f"label {i.label} defined twice")
                self.index.setdefault(i.label, k)
            i.glob = glob
        for i in ins:
            analyze(i, prog)
        self.contracts, self.malformed = {}, set()
        for i in ins:
            if i.label and not i.exp:
                c, bad = parse_contract(i.block)
                if c:
                    self.contracts[i.label] = c
                elif bad:
                    self.malformed.add(i.label)
                    self.problem(i.where, f"{i.label}: contract needs all of "
                                          f"In, Out and Trashes")
        for m in prog.macros.values():
            if m.malformed:
                self.problem(m.where, f"macro {m.name}: contract needs all of "
                                      f"In, Out and Trashes")

    def problem(self, where, msg):
        self.problems.append((where, msg))

    def entry(self, label):
        return self.index.get(label)

    def is_tail(self, i, ins, entry):
        """A branch into another routine's contracted entry."""
        return (ins.target in self.contracts and self.entry(ins.target) != entry
                and ins.flow in ("jump", "cjump"))

    # --- membership: code reachable from an entry without entering calls
    def members(self, entry):
        if entry in self.member_memo:
            return self.member_memo[entry]
        seen, work, n = set(), [entry], len(self.prog.ins)
        self.member_memo[entry] = seen
        while work:
            k = work.pop()
            if k in seen or k >= n:
                continue
            seen.add(k)
            ins = self.prog.ins[k]
            if ins.flow in ("ret", "data", "ijump"):
                continue
            if ins.flow in ("jump", "cjump") and ins.target in self.index:
                if not self.is_tail(k, ins, entry):
                    work.append(self.index[ins.target])
            if ins.flow != "jump":
                work.append(k + 1)
        return seen

    # --- forward: registers a routine (or a macro region) may change
    def writes(self, entry, region=None, memo=None, active=()):
        memo = {} if memo is None else memo
        key = (entry, region)
        if key in memo:
            return memo[key]
        if entry in active:             # recursion: no new information
            return set(), {}
        prog, n = self.prog, len(self.prog.ins)
        states, work = {}, [(entry, frozenset(), ())]
        result, first = set(), {}
        while work:
            k, W, S = work.pop()
            if region and not region[0] <= k < region[1]:
                result |= W
                continue
            old = states.get(k)
            if old:
                W2, S2 = old[0] | W, merge_stack(old[1], S)
                if W2 == old[0] and S2 == old[1]:
                    continue
                W, S = W2, S2
            states[k] = (W, S)
            if k >= n:
                prog.warn(prog.ins[-1].where, "code runs off the end")
                continue
            ins = prog.ins[k]
            if ins.flow == "data":
                prog.warn(ins.where, f"code runs into data ({ins.text()})")
                continue
            W1, S1, restored = apply_stack(ins, W, S)
            new = set(W1) | (ins.defs - {CCR})
            for r, was in restored.items():
                new.discard(r)
                if was:
                    new.add(r)
            if ins.flow == "call":
                c = self.contracts.get(ins.target)
                if c:
                    new |= c.changes
                elif ins.target in self.index:
                    new |= self.writes(self.index[ins.target], None, memo,
                                       active + (entry,))[0]
            elif ins.flow == "icall":
                new |= ALL_REGS
            for r in new - W:
                first.setdefault(r, k)
            W1 = frozenset(new)
            if ins.flow == "ret":
                if S1:
                    self.stack_problem(ins, S1)
                result |= W1
                continue
            if self.is_tail(k, ins, entry):
                if S1:
                    self.stack_problem(ins, S1)
                result |= W1 | self.contracts[ins.target].changes
                for r in self.contracts[ins.target].changes - W1:
                    first.setdefault(r, k)
                if ins.flow == "jump":
                    continue
                work.append((k + 1, W1, S1))
                continue
            if ins.flow == "ijump":
                result |= W1
                continue
            if ins.flow in ("jump", "cjump") and ins.target in self.index:
                work.append((self.index[ins.target], W1, S1))
            elif ins.flow in ("jump", "cjump"):
                prog.warn(ins.where, f"branch target {ins.target} not found")
            if ins.flow != "jump":
                work.append((k + 1, W1, S1))
        memo[key] = (result, first)
        return result, first

    def stack_problem(self, ins, S):
        if re.search(r"regcheck-ok:.*\bstack\b", ins.comment or ""):
            return
        left = sum(s[1] for s in S)
        self.problem(ins.where, f"'{ins.text()}' with {left} byte(s) still on "
                                f"the stack")

    # --- where pushed values go: the pops that take each slot back,
    # "dropped" (addq #n,sp and the like), or "used" (read in place,
    # or lost track of -- then the pushed registers count as read)
    def stack_flow(self):
        prog, n = self.prog, len(self.prog.ins)
        fate = {}

        def mark(S, how):
            for slot in S or ():
                fate.setdefault(slot[0], set()).add(how)

        starts = {0} | {self.index[c] for c in self.contracts} | {
            self.index[i.target] for i in prog.ins
            if i.flow == "call" and i.target in self.index}
        for start in starts:
            states, work = {}, [(start, ())]
            while work:
                k, S = work.pop()
                if k >= n:
                    continue
                if k in states:
                    old = states[k]
                    if old == S or old is None:
                        continue
                    mark(old, "used")
                    mark(S, "used")
                    S = None
                states[k] = S
                ins = prog.ins[k]
                if S is not None:
                    if ins.reads_stack:
                        mark(S, "used")
                    for eff in ins.stack:
                        kind = eff[0]
                        if kind in ("push", "grow"):
                            regs = frozenset(eff[1]) if kind == "push" and eff[1] else None
                            S = S + ((k, regs, eff[-1]),)
                        elif kind == "pop" and S and S[-1][2] == eff[2]:
                            fate.setdefault(S[-1][0], set()).add(
                                (k, frozenset(eff[1]) if eff[1] else None))
                            S = S[:-1]
                        elif kind == "drop":
                            left = eff[1]
                            while S and 0 < S[-1][2] <= left:
                                left -= S[-1][2]
                                mark(S[-1:], "dropped")
                                S = S[:-1]
                            if left:
                                mark(S, "used")
                                S = None
                                break
                        elif kind == "reset":
                            mark(S, "dropped")
                            S = ()
                        else:
                            mark(S, "used")
                            S = None
                            break
                if ins.flow in ("ret", "data", "ijump"):
                    mark(S, "used")
                    continue
                if ins.flow in ("jump", "cjump"):
                    if self.is_tail(k, ins, start):
                        mark(S, "used")
                    elif ins.target in self.index:
                        work.append((self.index[ins.target], S))
                if ins.flow != "jump":
                    work.append((k + 1, S))
        return fate

    def push_use(self, k, fate):
        """Registers a push reads: those whose value is needed later."""
        ins = self.prog.ins[k]
        f = fate.get(k)
        if not f or "used" in f:
            return set(ins.push_regs)
        out = set()
        for item in f:
            if item == "dropped":
                continue
            q, dest = item
            if dest is None:
                return set(ins.push_regs)
            after = self.live_out(q)
            if dest == frozenset(ins.push_regs):
                out |= dest & after             # each back to itself
            elif dest & after:
                out |= ins.push_regs
        return out

    # --- backward: registers live at each instruction
    def liveness(self):
        prog, n = self.prog, len(self.prog.ins)
        owners = [set() for _ in range(n)]
        for label in self.contracts:
            for k in self.members(self.index[label]):
                owners[k].add(label)
        returns = [[] for _ in range(n)]
        for k, ins in enumerate(prog.ins):
            if ins.flow == "call" and ins.target in self.index \
                    and ins.target not in self.contracts:
                for m in self.members(self.index[ins.target]):
                    if prog.ins[m].flow == "ret":
                        returns[m].append(k + 1)
        for k, ins in enumerate(prog.ins):
            use, dfn, succ = set(ins.uses), set(ins.defs), []
            c = self.contracts.get(ins.target)
            if ins.flow == "next":
                succ = [k + 1]
            elif ins.flow == "call":
                if c:
                    use |= c.ins
                    dfn |= c.changes | {CCR}
                    succ = [k + 1]
                elif ins.target in self.index:
                    succ = [self.index[ins.target]]
                else:
                    succ = [k + 1]
            elif ins.flow == "icall":
                use |= ALL_REGS
                succ = [k + 1]
            elif ins.flow in ("jump", "cjump"):
                tail = any(self.is_tail(k, ins, self.index[o]) for o in owners[k]) \
                    if owners[k] else (c is not None)
                if c and tail:
                    use |= c.ins
                elif ins.target in self.index:
                    succ = [self.index[ins.target]]
                if ins.flow == "cjump":
                    succ.append(k + 1)
            elif ins.flow == "ret":
                for o in owners[k]:
                    use |= self.contracts[o].outs
                    if self.contracts[o].ccr_out:
                        use.add(CCR)
                succ = returns[k]
            ins.use_l, ins.def_l, ins.succ = use, dfn, [s for s in succ if s < n]
            ins.base_use = use
        preds = [[] for _ in range(n)]
        for k, ins in enumerate(prog.ins):
            for s in ins.succ:
                preds[s].append(k)
        self.live, self.owners = [frozenset()] * n, owners
        fate = self.stack_flow()
        pushes = [k for k in range(n) if prog.ins[k].push_regs]
        work = list(range(n))
        while work:                     # least fixpoint: push reads grow
            queued = set(work)
            while work:
                k = work.pop()
                queued.discard(k)
                ins = prog.ins[k]
                new = frozenset(ins.use_l | (self.live_out(k) - ins.def_l))
                if new != self.live[k]:
                    self.live[k] = new
                    for p in preds[k]:
                        if p not in queued:
                            work.append(p)
                            queued.add(p)
            for k in pushes:
                ins = prog.ins[k]
                use = ins.base_use | self.push_use(k, fate)
                if use != ins.use_l:
                    ins.use_l = use
                    work.append(k)

    def live_out(self, k):
        succ = self.prog.ins[k].succ
        return set().union(*(self.live[s] for s in succ)) if succ else set()

    def first_read(self, start, reg):
        seen, work = set(), [start]
        while work:
            k = work.pop(0)
            if k in seen or k >= len(self.prog.ins):
                continue
            seen.add(k)
            ins = self.prog.ins[k]
            if reg in ins.use_l:
                return ins
            if reg not in ins.def_l:
                work.extend(ins.succ)
        return None

    def reads(self, start, regs):
        out = []
        for r in sorted(regs):
            ins = self.first_read(start, r)
            how = ("returned in Out" if ins and ins.flow == "ret" else "read")
            where = f" ({how} at {loc(ins.where)}: {ins.text()})" if ins else ""
            out.append(f"{r}{where}")
        return "; ".join(out)

    # --- the checks
    def check(self):
        prog = self.prog
        calls = 0
        for label, c in self.contracts.items():
            k = self.index[label]
            got, first = self.writes(k)
            bad = got - c.changes - c.ok - {CCR}
            for r in sorted(bad):
                w = prog.ins[first[r]] if r in first else None
                how = f", first at {loc(w.where)}: {w.text()}" if w else ""
                self.problem(prog.ins[k].where, f"{label} changes {r}, not in "
                                                f"its Out/Trashes{how}")
            if self.verbose:
                spare = c.changes - got
                print(f"  {label:14} changes {' '.join(sorted(got)) or '-'}"
                      + (f"   (declared, unused: {' '.join(sorted(spare))})"
                         if spare else ""))
        for m in prog.macros.values():
            if not m.uses or not m.contract:
                continue
            e = m.uses[0]
            got, first = self.writes(e.start, (e.start, e.end))
            for r in sorted(got - m.contract.changes - m.contract.ok - {CCR}):
                self.problem(m.where, f"macro {m.name} changes {r}, not in its "
                                      f"Out/Trashes")
        self.liveness()
        for k, ins in enumerate(prog.ins):
            if ins.flow != "call":
                continue
            calls += 1
            c = self.contracts.get(ins.target)
            if c is None:
                if ins.target not in self.index:
                    prog.warn(ins.where, f"call target {ins.target} not found")
                elif "." not in ins.target and ins.target not in self.malformed:
                    self.problem(ins.where, f"'{ins.text()}': {ins.target} has "
                                            f"no register contract")
                continue
            live = self.live_out(k)
            if self.verbose:
                print(f"  {loc(ins.where)}: {ins.text()}: live after: "
                      f"{' '.join(sorted(live)) or '-'}")
            bad = (live & c.trashes) - suppressed(ins.comment)
            if CCR in live and not c.ccr_out and CCR not in suppressed(ins.comment):
                bad.add(CCR)
            if bad:
                self.problem(ins.where, f"'{ins.text()}' trashes what is still "
                                        f"live here: {self.reads(k + 1, bad)}")
        uses = 0
        for e in prog.expansions:
            m = e.macro
            code = any(prog.ins[j].flow != "data" and prog.ins[j].op
                       for j in range(e.start, e.end))
            if not code:
                continue
            uses += 1
            if not m.contract:
                if not m.malformed and m.uses[0] is e:
                    self.problem(m.where, f"macro {m.name} has no register "
                                          f"contract")
                continue
            exits = set()
            for j in range(e.start, e.end):
                exits |= {s for s in prog.ins[j].succ if not e.start <= s < e.end}
            ok = suppressed(e.comment)
            for s in sorted(exits):
                live = set(self.live[s]) if s < len(prog.ins) else set()
                bad = (live & m.contract.trashes) - ok
                if CCR in live and not m.contract.ccr_out and CCR not in ok:
                    bad.add(CCR)
                if bad:
                    self.problem(e.where, f"'{m.name}' trashes what is still "
                                          f"live after it: {self.reads(s, bad)}")
        return calls, uses


def loc(where):
    return f"{where[0]}:{where[1]}"


def main(argv):
    defines, verbose, files = {}, False, []
    for a in argv:
        if a.startswith("-D"):
            name, _, value = a[2:].partition("=")
            try:
                defines[name] = evaluate(value or "1", {})
            except Unknown:
                raise SystemExit(f"regcheck: bad define {a}")
        elif a == "-v":
            verbose = True
        elif a.startswith("-"):
            raise SystemExit(__doc__)
        else:
            files.append(a)
    if len(files) != 1:
        raise SystemExit(__doc__)
    prog = Program(defines)
    prog.load(files[0])
    checker = Checker(prog, verbose)
    calls, uses = checker.check()
    seen = set()
    for where, msg in prog.warnings:
        if (where, msg) not in seen:
            seen.add((where, msg))
            print(f"{loc(where)}: warning: {msg}")
    for where, msg in dict.fromkeys(checker.problems):
        print(f"{loc(where)}: error: {msg}")
    n = len(dict.fromkeys(checker.problems))
    summary = (f"{files[0]}: {len(checker.contracts)} contracts, {calls} calls, "
               f"{uses} macro uses")
    print(f"regcheck: {summary}: " + (f"{n} problem(s)" if n else "ok"))
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
