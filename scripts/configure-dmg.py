"""Write a reproducible Finder layout without controlling the user's Finder."""
from pathlib import Path
import sys
from ds_store import DSStore
from mac_alias import Alias

volume = Path(sys.argv[1]).resolve()
background = Alias.for_file(str(volume / '.background' / 'installer.png')).to_bytes()
with DSStore.open(str(volume / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowTabView': False, 'ShowToolbar': False,
        'ShowPathbar': False, 'ShowSidebar': False,
        'WindowBounds': '{{160, 120}, {720, 460}}',
        'ContainerShowSidebar': False,
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundImageAlias': background,
        'backgroundColorRed': 0.925, 'backgroundColorGreen': 0.93,
        'backgroundColorBlue': 0.955,
        'iconSize': 80.0, 'textSize': 12.0, 'gridSpacing': 90.0,
        'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'arrangeBy': 'none',
        'showIconPreview': False, 'showItemInfo': False, 'labelOnBottom': True,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['icvl'] = ('type', b'icnv')
    store['[oasis].app']['Iloc'] = (200, 235)
    store['Applications']['Iloc'] = (520, 235)
