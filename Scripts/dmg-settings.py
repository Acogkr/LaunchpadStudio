"""Finder layout written directly to the image by dmgbuild; no UI scripting."""
import os

application = defines['app']
assets = defines['assets']
format = 'UDZO'
filesystem = 'HFS+'
files = [application]
symlinks = {'Applications': '/Applications'}
icon = os.path.join(application, 'Contents', 'Resources', 'AppIcon.icns')
background = os.path.join(assets, 'background.tiff')
# Keep the signed app bundle's Finder metadata untouched.
hide_extensions = []
icon_locations = {os.path.basename(application): (160, 190), 'Applications': (480, 190)}
# Finder's 28-point title bar sits above the 400-point background.
window_rect = ((260, 260), (640, 428))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = 'icon-view'
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_spacing = 96
icon_size = 112
text_size = 13
label_pos = 'bottom'
show_icon_preview = False
scroll_position = (0, 0)
