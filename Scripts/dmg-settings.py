from pathlib import Path

release_root = Path.cwd()
application = release_root / 'ReleaseSwitch.app'
format = 'UDZO'
filesystem = 'HFS+'
files = [str(application)]
symlinks = {'Программы': '/Applications'}
background = str(release_root / 'Resources/DMGBackground.png')
icon = str(release_root / 'Resources/AppIcon.icns')
window_rect = ((200, 160), (660, 500))
icon_locations = {'ReleaseSwitch.app': (170, 230), 'Программы': (490, 230)}
icon_size = 128
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
default_view = 'icon-view'
arrange_by = None
license = None
