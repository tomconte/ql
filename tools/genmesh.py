#!/usr/bin/env python3
"""Mesh pipeline: hand-designed low-poly solids -> validated,
winding-consistent tables as a vasm include.

Two targets:
  (default)  shapes/meshes.inc for the parade: MESHES at parade scale,
             projection-safe radius <= SHOW_RADIUS, 16-byte directory.
  --game     glider/meshes.inc for the game: GAME_MESHES in world units
             (camera 128 over the ground, lattice cells of 256), radius
             <= GAME_RADIUS (16-bit safety once edges are clipped), plus
             per-face planes for the object-space backface test and a
             32-byte directory with ybase, mesh radius and collision
             radius.

Coordinate system matches the engine: x right, y DOWN (screen), z away.
Faces are vertex loops wound consistently; per mesh this script:
  - checks every undirected edge appears in exactly 2 faces, once per
    direction (closed 2-manifold + consistent winding),
  - auto-orients the whole mesh by signed volume, matched against the
    parade cube whose winding is known-good in the engine (cull test
    cross>0),
  - checks Euler characteristic, engine limits (<=16 vertices/faces),
    and the target's radius bound,
  - derives the edge list with per-edge two-face masks (bit f = face f),
  - emits faces LAST-FIRST so the cull loop's dbf counter is the bit
    number, vertex indexes pre-multiplied by the engine's per-vertex
    record size, and a directory of counts, colour and offsets from
    the meshes base.

Game target, per face: the outward normal scaled to length NORM_LEN
(nx,ny,nz words) and the plane constant d = n.v0 (long), last-first
like the faces. The engine sees a face iff n.eye > d, with the eye in
the mesh's own frame (glider.asm). Outward is fixed against the
centroid, so game meshes must be convex -- asserted exactly on the
integer normals.

Colours are the lib/draw_line.asm codes (mode 4 pixel bits: red 1,
green 2, white 3), one per mesh, drawn for the whole object.

Used by shapes/Makefile and glider/Makefile."""

import math
import sys

COLOURS = {"red": 1, "green": 2, "white": 3}    # lib/draw_line.asm col_*

# name, colour, vertices (x,y,z), faces as outward-wound vertex loops
MESHES = [
    ("cube", "white",
     [(-48,-48,-48),(48,-48,-48),(48,48,-48),(-48,48,-48),
      (-48,-48,48),(48,-48,48),(48,48,48),(-48,48,48)],
     [[0,1,2,3],[1,0,4,5],[2,1,5,6],[3,2,6,7],[0,3,7,4],[5,4,7,6]]),

    ("dart", "red",                     # triangular enemy ship
     [(0,6,-70),(-52,6,42),(52,6,42),(0,-22,30)],
     [[0,1,2],[0,2,3],[1,0,3],[2,1,3]]),

    ("tower", "green",                  # hexagonal tower
     [(40,-55,0),(20,-55,35),(-20,-55,35),(-40,-55,0),(-20,-55,-35),(20,-55,-35),
      (40,55,0),(20,55,35),(-20,55,35),(-40,55,0),(-20,55,-35),(20,55,-35)],
     [[0,1,2,3,4,5],                    # top cap
      [11,10,9,8,7,6],                  # bottom cap
      [1,0,6,7],[2,1,7,8],[3,2,8,9],[4,3,9,10],[5,4,10,11],[0,5,11,6]]),

    ("mine", "white",                   # stretched octahedron
     [(0,0,-70),(0,0,70),(-42,0,0),(42,0,0),(0,-42,0),(0,42,0)],
     [[0,2,4],[0,4,3],[0,3,5],[0,5,2],
      [1,4,2],[1,3,4],[1,5,3],[1,2,5]]),

    ("fighter", "red",                  # the Starglider-style bandit:
     [(0,0,-78),                        # 0 nose
      (0,-16,-18),                      # 1 cockpit hump
      (0,-10,52),                       # 2 tail top
      (0,12,52),                        # 3 tail bottom
      (0,16,-8),                        # 4 belly
      (-64,8,40),                       # 5 left wingtip
      (64,8,40)],                       # 6 right wingtip
     [[0,1,5],[1,2,5],[2,3,5],[3,4,5],[4,0,5],       # left skin
      [1,0,6],[2,1,6],[3,2,6],[4,3,6],[0,4,6]]),     # right skin
]

# The game's meshes, in world units. The camera hovers 128 over the
# ground and lattice cells are 256, so a tower stands well above the
# eye (top 256 over it), the block's top is seen from above, and the
# mine floats at eye height (its centre height is the level table's).
GAME_MESHES = [
    ("tower", "white",                  # hex prism: vertex radius 48, 384 tall
     [(48,-192,0),(24,-192,42),(-24,-192,42),(-48,-192,0),(-24,-192,-42),(24,-192,-42),
      (48,192,0),(24,192,42),(-24,192,42),(-48,192,0),(-24,192,-42),(24,192,-42)],
     [[0,1,2,3,4,5],                    # top cap
      [11,10,9,8,7,6],                  # bottom cap
      [1,0,6,7],[2,1,7,8],[3,2,8,9],[4,3,9,10],[5,4,10,11],[0,5,11,6]]),

    ("block", "white",                  # bunker: a 192 cube, top 64 under the eye
     [(-96,-96,-96),(96,-96,-96),(96,96,-96),(-96,96,-96),
      (-96,-96,96),(96,-96,96),(96,96,96),(-96,96,96)],
     [[0,1,2,3],[1,0,4,5],[2,1,5,6],[3,2,6,7],[0,3,7,4],[5,4,7,6]]),

    ("mine", "red",                     # stretched octahedron, hover height
     [(0,0,-70),(0,0,70),(-42,0,0),(42,0,0),(0,-42,0),(0,42,0)],
     [[0,2,4],[0,4,3],[0,3,5],[0,5,2],
      [1,4,2],[1,3,4],[1,5,3],[1,2,5]]),
]

# Meshes shown on the radar (spec 5.4), their blips in the mesh's own
# colour: hostiles red, generators white, energy packs green. Obstacles
# (towers, blocks) are left off.
GAME_ON_RADAR = {"mine"}

# Hits a mesh takes before it goes (spec 6); the rest are obstacles
# that stop shots and are never destroyed.
GAME_HP = {"mine": 1}

# What touching a mesh does (spec 7): absent = an obstacle (the craft
# bounces off, 1 shield); else the entity is consumed and the shield
# changes by the value (a mine -2, an energy pack will be +2).
GAME_TOUCH = {"mine": -2}

SHOW_RADIUS = 84        # parade: projection-safe bound (Z0=300, focal
                        # 256/170): the cube's 83 is proven on screen (x
                        # 256+-98, y 120+-66, clear of the meter rows at 240)
GAME_RADIUS = 1024      # game: 16-bit safety for the projection divides
                        # once edges are clipped. A vertex clipped to
                        # z = znear_o (32 in glider.asm) can sit 3.5r + 32
                        # sideways (frustum side test at 1.5r), and
                        # 256*(3.5r+32)/32 must stay under 32768: r <= 1160.
NORM_LEN = 1024         # length of the emitted game face normals

def cross(a, b):
    return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])

def sub(a, b):
    return (a[0]-b[0], a[1]-b[1], a[2]-b[2])

def dot(a, b):
    return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]

def signed_volume(verts, faces):
    vol = 0
    for f in faces:
        for i in range(1, len(f)-1):
            a, b, c = verts[f[0]], verts[f[i]], verts[f[i+1]]
            vol += dot(a, cross(b, c))
    return vol

def validate(name, verts, faces, rmax):
    if len(verts) > 16 or len(faces) > 16:
        sys.exit(f"{name}: >16 vertices or faces")
    r2max = max(dot(v, v) for v in verts)
    if r2max > rmax * rmax:
        sys.exit(f"{name}: radius {r2max**0.5:.0f} > {rmax}")
    edges = {}
    for fi, f in enumerate(faces):
        for k in range(len(f)):
            a, b = f[k], f[(k+1) % len(f)]
            key, direc = (min(a, b), max(a, b)), a < b
            edges.setdefault(key, []).append((fi, direc))
    for (a, b), uses in edges.items():
        if len(uses) != 2 or uses[0][1] == uses[1][1]:
            sys.exit(f"{name}: edge {a}-{b} not manifold/consistent: {uses}")
    ne = len(edges)
    euler = len(verts) - ne + len(faces)
    if euler != 2:
        sys.exit(f"{name}: Euler {euler} != 2, not a closed solid")
    return edges, r2max ** 0.5

def face_planes(name, verts, faces):
    """Per face (in face order): outward normal scaled to NORM_LEN and
    the plane constant d = n.v0. Outward is decided against the
    centroid; every face must agree with the winding, and every vertex
    must lie on or behind every face plane (exact, on the integer
    normals): the mesh is convex, which the engine's eye-side test
    relies on."""
    nv = len(verts)
    ctr = (sum(v[0] for v in verts), sum(v[1] for v in verts),
           sum(v[2] for v in verts))          # centroid * nv
    sign = None
    planes = []
    for f in faces:
        a, b, c = verts[f[0]], verts[f[1]], verts[f[2]]
        n = cross(sub(b, a), sub(c, a))
        side = dot(n, sub((a[0]*nv, a[1]*nv, a[2]*nv), ctr))
        if side == 0:
            sys.exit(f"{name}: face {f} passes through the centroid")
        s = 1 if side > 0 else -1
        if sign is None:
            sign = s
        elif s != sign:
            sys.exit(f"{name}: face {f} winding disagrees with outward")
        n = (n[0]*sign, n[1]*sign, n[2]*sign)
        dmax = dot(n, a)
        for v in verts:
            if dot(n, v) > dmax:
                sys.exit(f"{name}: not convex, vertex {v} is outside face {f}")
        length = math.sqrt(dot(n, n))
        ns = tuple(round(x * NORM_LEN / length) for x in n)
        planes.append((ns, dot(ns, a)))
    return planes

REF_SIGN = 1 if signed_volume(MESHES[0][2], MESHES[0][3]) > 0 else -1
                                        # the parade cube anchors orientation

def build(name, colour, verts, faces, rmax):
    vol = signed_volume(verts, faces)
    if vol * REF_SIGN < 0:
        faces = [list(reversed(f)) for f in faces]
    edges, radius = validate(name, verts, faces, rmax)
    edge_list = []
    for (a, b), uses in sorted(edges.items()):
        mask = (1 << uses[0][0]) | (1 << uses[1][0])
        edge_list.append((a, b, mask))
    return name, colour, verts, faces, edge_list, radius

def emit_tables(name, verts, faces, edge_list, vs):
    """Vertex, face-triple and edge tables; vertex indexes are
    pre-multiplied by vs, the engine's per-vertex record size (4 in
    the parade's vtx2d, 12 in the game's vscr)."""
    print(f"; ----- {name}: V{len(verts)} F{len(faces)} E{len(edge_list)}")
    print(f"m_{name}_v:")
    for x, y, z in verts:
        print(f"        dc.w    {x},{y},{z}")
    print(f"m_{name}_f:")                  # last face first: dbf = bit no.
    for f in reversed(faces):
        a, b, c = f[0]*vs, f[1]*vs, f[2]*vs
        print(f"        dc.b    {a},{b},{c}")
    print("        even")
    print(f"m_{name}_e:")                  # i*vs, j*vs, two-face mask word
    for a, b, mask in edge_list:
        print(f"        dc.b    {a*vs},{b*vs}")
        print(f"        dc.w    ${mask:04x}")

def emit_parade():
    out_meshes = []
    for name, colour, verts, faces in MESHES:
        name, colour, verts, faces, edge_list, radius = \
            build(name, colour, verts, faces, SHOW_RADIUS)
        out_meshes.append((name, colour, verts, faces, edge_list))
        print(f"; {name}: V{len(verts)} E{len(edge_list)} F{len(faces)} "
              f"Euler 2, radius {radius:.0f}, winding consistent, {colour}",
              file=sys.stderr)
    print("; generated by tools/genmesh.py -- do not edit")
    print("meshes:")
    for name, colour, verts, faces, edge_list in out_meshes:
        emit_tables(name, verts, faces, edge_list, 4)
    print("; directory, 16 bytes per object: nvtx-1, nfaces-1, nedges-1, colour,")
    print("; v/f/e offsets from meshes, pad")
    print(f"nobjs       equ     {len(out_meshes)}")
    print("objdir:")
    for name, colour, verts, faces, edge_list in out_meshes:
        print(f"        dc.w    {len(verts)-1},{len(faces)-1},{len(edge_list)-1},"
              f"{COLOURS[colour]}    ; {colour}")
        print(f"        dc.w    m_{name}_v-meshes,m_{name}_f-meshes,"
              f"m_{name}_e-meshes,0")

def emit_game():
    out_meshes = []
    for name, colour, verts, faces in GAME_MESHES:
        name, colour, verts, faces, edge_list, radius = \
            build(name, colour, verts, faces, GAME_RADIUS)
        planes = face_planes(name, verts, faces)
        ybase = max(v[1] for v in verts)
        radius = math.ceil(radius)
        colrad = math.ceil(max(math.hypot(v[0], v[2]) for v in verts))
        out_meshes.append((name, colour, verts, faces, edge_list, planes,
                           ybase, radius, colrad))
        print(f"; {name}: V{len(verts)} E{len(edge_list)} F{len(faces)} "
              f"Euler 2, convex, radius {radius}, ybase {ybase}, "
              f"collision {colrad}, {colour}", file=sys.stderr)
    print("; generated by tools/genmesh.py --game -- do not edit")
    print("meshes:")
    for (name, colour, verts, faces, edge_list, planes,
         ybase, radius, colrad) in out_meshes:
        emit_tables(name, verts, faces, edge_list, 12)
        print(f"m_{name}_n:")              # last face first: nx,ny,nz, d.l
        for (nx, ny, nz), d in reversed(planes):
            print(f"        dc.w    {nx},{ny},{nz}")
            print(f"        dc.l    {d}")
    print("; directory, 32 bytes per object: nvtx-1, nfaces-1, nedges-1, colour,")
    print("; v/f/e/n offsets from meshes, ybase (centre to lowest point),")
    print("; mesh radius, collision radius (x/z extent), radar blip colour")
    print("; (0 = not on the radar), hits to destroy (0 = an obstacle),")
    print("; contact (0 = an obstacle, else consumed: shield += it), pad")
    print(f"nobjs       equ     {len(out_meshes)}")
    for i, m in enumerate(out_meshes):
        print(f"msh_{m[0]:<8}equ     {i}")
        print(f"yb_{m[0]:<9}equ     {m[6]}")
    print("objdir:")
    for (name, colour, verts, faces, edge_list, planes,
         ybase, radius, colrad) in out_meshes:
        print(f"        dc.w    {len(verts)-1},{len(faces)-1},{len(edge_list)-1},"
              f"{COLOURS[colour]}    ; {colour}")
        print(f"        dc.w    m_{name}_v-meshes,m_{name}_f-meshes,"
              f"m_{name}_e-meshes,m_{name}_n-meshes")
        blip = COLOURS[colour] if name in GAME_ON_RADAR else 0
        print(f"        dc.w    {ybase},{radius},{colrad},{blip}")
        print(f"        dc.w    {GAME_HP.get(name, 0)},{GAME_TOUCH.get(name, 0)},0,0")

if "--game" in sys.argv[1:]:
    emit_game()
else:
    emit_parade()
