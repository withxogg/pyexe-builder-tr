# PyExeBuilder runtime hook v8.8
import sys, os
try: import multiprocessing
except Exception: multiprocessing = None
try: multiprocessing.freeze_support()
except Exception: pass
try:
    import certifi
    os.environ.setdefault('SSL_CERT_FILE', certifi.where())
    os.environ.setdefault('REQUESTS_CA_BUNDLE', certifi.where())
except Exception:
    pass

try:
    if sys.stdout is None:
        sys.stdout = open(os.devnull, 'w', encoding='utf-8')
    if sys.stderr is None:
        sys.stderr = open(os.devnull, 'w', encoding='utf-8')
except Exception:
    pass

def _pyexebuilder_icon_path():
    base = getattr(sys, '_MEIPASS', None)
    if not base: return None
    for name in ('_pyexebuilder_icon.ico','_pyexebuilder_icon.png','_pyexebuilder_icon.jpg',
                 '_pyexebuilder_icon.jpeg','_pyexebuilder_icon.bmp','_pyexebuilder_icon.gif','_pyexebuilder_icon.webp'):
        p = os.path.join(base, name)
        if os.path.exists(p): return p
    return None

ICON = _pyexebuilder_icon_path()

if ICON:
    try:
        import tkinter
        _tk_init = tkinter.Tk.__init__
        def _pb_patched_tk(self, *a, __orig=_tk_init, **kw):
            __orig(self, *a, **kw)
            try:
                self.iconbitmap(ICON)
            except Exception:
                try:
                    img = tkinter.PhotoImage(file=ICON)
                    self.iconphoto(True, img)
                    self._pb_icon = img
                except Exception:
                    pass
        tkinter.Tk.__init__ = _pb_patched_tk
    except Exception:
        pass
    try:
        import pygame
        _sm = pygame.display.set_mode
        def _pb_patched_set_mode(*a, __orig=_sm, **kw):
            try: pygame.display.set_icon(pygame.image.load(ICON))
            except Exception: pass
            return __orig(*a, **kw)
        pygame.display.set_mode = _pb_patched_set_mode
    except Exception:
        pass
    for _mod in ('PyQt5','PyQt6','PySide2','PySide6'):
        try:
            _qtw = __import__(_mod + '.QtWidgets', fromlist=['QApplication'])
            _qtg = __import__(_mod + '.QtGui', fromlist=['QIcon'])
            _QApp = _qtw.QApplication
            _orig_init = _QApp.__init__
            def _pb_qapp_init(self, *a, __o=_orig_init, __q=_qtg, **kw):
                __o(self, *a, **kw)
                try: self.setWindowIcon(__q.QIcon(ICON))
                except Exception: pass
            _QApp.__init__ = _pb_qapp_init
        except Exception:
            pass
    try:
        import wx
        _wf = wx.Frame.__init__
        def _pb_patched_wx(self, *a, __orig=_wf, **kw):
            __orig(self, *a, **kw)
            try: self.SetIcon(wx.Icon(ICON))
            except Exception: pass
        wx.Frame.__init__ = _pb_patched_wx
    except Exception:
        pass
    try:
        import pyglet
        _pw = pyglet.window.Window.__init__
        def _pb_patched_pyglet(self, *a, __orig=_pw, **kw):
            __orig(self, *a, **kw)
            try: self.set_icon(pyglet.image.load(ICON))
            except Exception: pass
        pyglet.window.Window.__init__ = _pb_patched_pyglet
    except Exception:
        pass
    try:
        import dearpygui.dearpygui as dpg
        _ds = dpg.start_dearpygui
        def _pb_patched_dpg(*a, __orig=_ds, **kw):
            try:
                dpg.set_viewport_small_icon(ICON)
                dpg.set_viewport_large_icon(ICON)
            except Exception: pass
            return __orig(*a, **kw)
        dpg.start_dearpygui = _pb_patched_dpg
    except Exception:
        pass
