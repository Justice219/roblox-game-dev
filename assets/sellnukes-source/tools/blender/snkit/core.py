"""
snkit.core — coordinate conventions, Model/Piece containers and the SellNukes toy palette.

Coordinates:
    Every builder works in ROBLOX space: studs, +Y up, model front = -Z, relative to the model's
    pivot (usually ground centre). Roblox (x, y, z) -> Blender (x, -z, y); both right-handed, so
    Roblox front (-Z) becomes Blender +Y. The FBX exporter (axis_forward=-Z, axis_up=Y) maps it back.

Pieces:
    A MeshPart has ONE Color + Material, so a model is split into single-colour pieces. Each piece
    becomes one named Blender object -> one FBX mesh -> one MeshPart -> one MeshAssets entry.
    Keep piece counts low (each piece is a draw call): group every same-colour detail into the same
    piece instead of making a new one.

Material names (manifest "material" field, resolved at runtime by WorldMaterialConfig):
    "Studs"       stud MaterialVariant SNStuds, 1 stud per stud cell (default: walls, machines)
    "StudsSmall"  SNStudsSmall, 0.5 stud cells (small props: nukes, cans, tools)
    "StudsLarge"  SNStudsLarge, 2 stud cells (huge far surfaces only, e.g. ground fields)
    "Smooth"      SmoothPlastic, no studs (tiny details where studs would be noise)
    "Neon"        glowing parts (reactor cores, bulbs) — no studs
    "Glass"       windows, domes (use transparency) — no studs
    Stud density is set by the MaterialVariant's StudsPerTile at runtime (Roblox ignores mesh UVs
    for MaterialVariants — proven in docs/world-art.md), so one mesh works with any stud size.

Example:
    m = Model("BuyPad", "ground centre of the pad")
    tyre = m.piece("Tyre", TYRE)
    top = m.piece("Top", WHITE, tinted=True)   # tinted: the caller recolours it at spawn
"""

from __future__ import annotations

import bmesh
from mathutils import Vector

MATERIALS = ("Studs", "StudsSmall", "StudsLarge", "Smooth", "Neon", "Glass")


def rb(p) -> Vector:
    """Roblox point/vector -> Blender Vector."""
    return Vector((p[0], -p[2], p[1]))


def br(v) -> tuple:
    """Blender point -> Roblox tuple."""
    return (v.x, v.z, -v.y)


class Piece:
    """
    One single-colour mesh of a model.

    tinted: the runtime may recolour this piece per spawn (pad colour, nuke tier colour).
    transparency: 0..1, applied as BasePart.Transparency.
    """

    def __init__(self, name: str, color, material: str = "Studs", tinted: bool = False, transparency: float = 0.0):
        if material not in MATERIALS:
            raise ValueError(f"unknown material {material!r} for piece {name}")
        self.name = name
        self.color = tuple(int(c) for c in color)
        self.material = material
        self.tinted = tinted
        self.transparency = transparency
        self.bm = bmesh.new()


class Model:
    """
    A named model built from pieces. `pivot` documents where (0, 0, 0) is in the world, so the
    runtime and level builders know how to place it (e.g. "ground centre, front toward -Z").

    budget: max triangles for the whole model (generate_world.py fails the build if exceeded).
    """

    def __init__(self, key: str, pivot: str, budget: int = 2000):
        self.key = key
        self.pivot = pivot
        self.budget = budget
        self.pieces: dict[str, Piece] = {}

    def piece(self, name: str, color, material: str = "Studs", tinted: bool = False, transparency: float = 0.0) -> Piece:
        """Get or create a piece by name (same name -> same mesh, so details merge into one draw)."""
        if name not in self.pieces:
            self.pieces[name] = Piece(name, color, material, tinted, transparency)
        return self.pieces[name]


# ------------------------------------------------------------------------------------------------
# Palette — candy toy colours (RGB 0..255). Keep world colours here so every area matches.
# The stud colour map is ~0.86-0.93 grey, so the on-screen colour is ~10 % darker than these.
# ------------------------------------------------------------------------------------------------

WHITE = (244, 244, 248)
OFF_WHITE = (226, 222, 210)
CREAM = (250, 232, 190)
GRASS = (98, 204, 70)
GRASS_DARK = (64, 160, 52)
LEAF = (70, 186, 74)
ROAD = (78, 82, 98)
ROAD_LINE = (255, 214, 64)
SIDEWALK = (200, 202, 212)
CONCRETE = (182, 184, 194)
CONCRETE_DARK = (140, 142, 154)
HAZARD_YELLOW = (255, 206, 36)
HAZARD_BLACK = (44, 44, 54)
TYRE = (52, 54, 64)
STEEL = (150, 158, 172)
DARK_STEEL = (92, 98, 112)
CHARCOAL = (58, 60, 70)
WOOD = (214, 150, 86)
WOOD_DARK = (164, 104, 58)
PEGBOARD = (226, 176, 112)
SKY_BLUE = (96, 168, 236)
DEEP_BLUE = (52, 104, 196)
CORAL = (240, 98, 78)
TOY_RED = (232, 64, 56)
ORANGE = (255, 146, 40)
YELLOW = (255, 214, 50)
LIME = (150, 230, 60)
MINT = (110, 222, 170)
PURPLE = (150, 96, 220)
PINK = (255, 120, 180)
COPPER = (214, 128, 70)
GLOW_GREEN = (110, 255, 90)
GLOW_LIGHT = (200, 255, 160)
GLASS = (180, 226, 255)
LAMP_WARM = (255, 236, 160)
BROWN = (130, 84, 50)
