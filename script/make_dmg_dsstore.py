#!/usr/bin/env python3
"""Write the Finder layout (.DS_Store) for the TokenRemain install window.

Usage: make_dmg_dsstore.py <mounted-volume-path> [output-copy]

Finder normally records this layout when a human arranges the window, which is
why most DMG recipes drive Finder over AppleScript. That needs Automation (TCC)
consent and a GUI session, so it breaks in CI. Writing the store directly keeps
packaging headless and reproducible.

The coordinates must stay in sync with script/make_dmg_background.py.

Regenerating Resources/dmg/DS_Store (only needed when the layout changes):

    pip install ds_store mac_alias
    python3 script/make_dmg_background.py
    # stage a folder containing TokenRemain.app, an Applications symlink and
    # .background/background.tiff, build a UDRW image from it, attach it, then:
    python3 script/make_dmg_dsstore.py /Volumes/TokenRemain Resources/dmg/DS_Store

package_developer_id_release.sh only copies the resulting file, so releases need
neither these packages nor a mounted volume to reproduce the layout.
"""

import os
import shutil
import sys

from ds_store import DSStore
from mac_alias import Alias

WIN_X, WIN_Y = 100, 100
IMAGE_W, IMAGE_H = 640, 448      # must equal the background image size
TITLE_BAR = 30                   # WindowBounds covers the frame, chrome included
WIN_W, WIN_H = IMAGE_W, IMAGE_H + TITLE_BAR
ICON_SIZE, TEXT_SIZE = 128, 12
APP_POS = (168, 196)             # icon centres, matching the background art
APPLICATIONS_POS = (472, 196)
BACKGROUND_REL = ".background/background.tiff"


def build(volume, output_copy=None):
    background = os.path.join(volume, BACKGROUND_REL)
    if not os.path.isfile(background):
        raise SystemExit(f"background missing: {background}")

    alias = Alias.for_file(background)
    store_path = os.path.join(volume, ".DS_Store")
    if os.path.exists(store_path):
        os.remove(store_path)

    with DSStore.open(store_path, "w+") as d:
        d["."]["bwsp"] = {
            "WindowBounds": f"{{{{{WIN_X}, {WIN_Y}}}, {{{WIN_W}, {WIN_H}}}}}",
            "ShowSidebar": False,
            "ShowToolbar": False,
            "ShowStatusBar": False,
            "ShowPathbar": False,
            "ShowTabView": False,
            "ContainerShowSidebar": False,
            "SidebarWidth": 0,
        }
        d["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 2,                 # 2 = picture
            "backgroundImageAlias": alias.to_bytes(),
            "backgroundColorRed": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
            "iconSize": float(ICON_SIZE),
            "textSize": float(TEXT_SIZE),
            "gridSpacing": 100.0,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "labelOnBottom": True,
            "showIconPreview": True,
            "showItemInfo": False,
            "arrangeBy": "none",
        }
        d["."]["vSrn"] = ("long", 1)
        d["TokenRemain.app"]["Iloc"] = APP_POS
        d["Applications"]["Iloc"] = APPLICATIONS_POS

    if output_copy:
        shutil.copyfile(store_path, output_copy)
    print(f"wrote {store_path}"
          + (f" (copied to {output_copy})" if output_copy else ""))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    build(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
