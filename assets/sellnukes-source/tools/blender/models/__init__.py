"""
SellNukes model builders. Each module exports BUILDERS = {modelKey: fn() -> snkit.core.Model}.

    props.py         BuyPad, PocketNuke (shared props used in every area)
    tiles.py         Tile_Grass, Tile_Road, Tile_Sidewalk, Tile_Hazard (16 x 16 stud ground tiles)
    area1_garage.py  Area 1 "Garage Lab" set (shell pieces, door, workbench, reactor, tools, ...)
    tests.py         StudTest (stud-material experiment); built only when named with --only
"""
