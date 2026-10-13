# dmgbuild settings for the ParaAir disk image (used by scripts/make-dmg.sh):
#   dmgbuild -s scripts/dmg-settings.py -D app=ParaAir.app -D background=bg.tiff "ParaAir" out.dmg
# Icon centres must match the Glide mark and caption in scripts/dmg-background.swift.
import os.path

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
appname = os.path.basename(application)

format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [appname]
icon = os.path.join(application, "Contents", "Resources", "ParaAirIcon.icns")

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {appname: (165, 140), "Applications": (495, 140)}
