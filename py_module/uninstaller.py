# -*- coding: utf-8 -*-
"""PyExeBuilder GUI kaldirma araci (v8.8)."""
import os, sys, time, ctypes, shutil, subprocess, winreg, threading, queue
import tkinter as tk
from tkinter import ttk, messagebox

PROJECT_NAME = __PROJECT_NAME__
EXE_NAME     = __EXE_NAME__

# ─── DPI awareness ───────────────────────────────────────────────────────
def _enable_dpi_awareness():
    try:
        ctypes.windll.user32.SetProcessDpiAwarenessContext(-4)
        return
    except Exception:
        pass
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
        return
    except Exception:
        pass
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

_enable_dpi_awareness()

# ─── Ekran olcekleme ─────────────────────────────────────────────────────
REF_W, REF_H = 1920.0, 1080.0
MIN_SCALE, MAX_SCALE = 0.80, 2.50
_SCALE = 1.0

def init_scale(root):
    global _SCALE
    try:
        sw = root.winfo_screenwidth()
        sh = root.winfo_screenheight()
        s = min(sw / REF_W, sh / REF_H)
        _SCALE = max(MIN_SCALE, min(MAX_SCALE, s))
    except Exception:
        _SCALE = 1.0
    try:
        root.tk.call('tk', 'scaling', 1.0)
    except Exception:
        pass
    return _SCALE

def S(v):
    return int(round(v * _SCALE))

def SF(v):
    return round(v * _SCALE * 2) / 2

def font(size_pt, family='Segoe UI', bold=False):
    px = -max(1, int(round(size_pt * _SCALE * 1.33)))
    if bold:
        return (family, px, 'bold')
    return (family, px)

def fit_window(root, base_w, base_h, margin_x=40, margin_y=80):
    sw = root.winfo_screenwidth()
    sh = root.winfo_screenheight()
    w = min(S(base_w), max(S(base_w) // 2, sw - margin_x))
    h = min(S(base_h), max(S(base_h) // 2, sh - margin_y))
    return w, h

def center_window(win, w, h):
    win.update_idletasks()
    sw = win.winfo_screenwidth()
    sh = win.winfo_screenheight()
    x = max(0, (sw - w) // 2)
    y = max(0, (sh - h) // 2 - S(20))
    win.geometry("%dx%d+%d+%d" % (w, h, x, y))

def _log_path():
    base = os.environ.get('TEMP') or os.environ.get('TMP') or '.'
    return os.path.join(base, 'pyexebuilder_uninstall.log')

def log(msg):
    try:
        with open(_log_path(), 'a', encoding='utf-8') as f:
            f.write('[%s] %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), msg))
    except Exception:
        pass

# ─── Yollar ──────────────────────────────────────────────────────────────
def get_install_dir():
    v = os.environ.get('_PYEXEBUILDER_INSTALL_DIR')
    if v: return v
    base = os.environ.get('LOCALAPPDATA') or os.environ.get('USERPROFILE') or os.path.expanduser('~')
    return os.path.join(base, 'Programs', PROJECT_NAME)

def get_bundle_dir():
    if getattr(sys, 'frozen', False):
        return getattr(sys, '_MEIPASS', os.path.dirname(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))

# ─── Pencere ikonu ───────────────────────────────────────────────────────
def _set_window_icon(root, path):
    low = path.lower()
    if low.endswith('.ico'):
        try:
            root.iconbitmap(path)
            return True
        except Exception:
            pass
    try:
        img = tk.PhotoImage(file=path)
        root.iconphoto(True, img)
        root._pb_icon_ref = img
        return True
    except Exception:
        return False

def apply_window_icon(root):
    base = get_bundle_dir()
    for name in ('_pb_window_icon.ico', '_pb_window_icon.png'):
        p = os.path.join(base, name)
        if os.path.isfile(p) and _set_window_icon(root, p):
            return

def kill_running():
    try:
        subprocess.run(['taskkill','/F','/IM', EXE_NAME + '.exe'],
                       capture_output=True, creationflags=0x08000000, timeout=15)
    except Exception:
        pass

def clear_attrs(p):
    try: ctypes.windll.kernel32.SetFileAttributesW(p, 0x80)
    except Exception: pass

def remove_shortcuts():
    appdata = os.environ.get('APPDATA','') or ''
    userprofile = os.environ.get('USERPROFILE','') or ''
    paths = []
    if appdata:
        paths.append(os.path.join(appdata,'Microsoft','Windows','Start Menu','Programs', PROJECT_NAME + '.lnk'))
        paths.append(os.path.join(appdata,'Microsoft','Windows','Start Menu','Programs','Startup','Hidden', PROJECT_NAME + '.lnk'))
    if userprofile:
        paths.append(os.path.join(userprofile,'Desktop', PROJECT_NAME + '.lnk'))
    for p in paths:
        try:
            if os.path.isfile(p):
                clear_attrs(p); os.remove(p)
        except Exception:
            pass

def remove_registry():
    try:
        winreg.DeleteKey(winreg.HKEY_CURRENT_USER,
            'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\' + PROJECT_NAME)
    except Exception:
        pass

def delete_dir(path):
    for _ in range(30):
        if not os.path.exists(path): return True
        try: shutil.rmtree(path, ignore_errors=True)
        except Exception: pass
        if not os.path.exists(path): return True
        time.sleep(0.8)
    return not os.path.exists(path)

def spawn_phase2(install_dir):
    src = sys.executable
    tmpdir = os.environ.get('TEMP') or os.environ.get('TMP') or os.path.expanduser('~')
    tmp_exe = os.path.join(tmpdir, '_pyexebuilder_uninst_' + str(int(time.time())) + '.exe')
    try: shutil.copy2(src, tmp_exe)
    except Exception: return None
    env = os.environ.copy()
    env['_PYEXEBUILDER_INSTALL_DIR'] = install_dir
    try:
        subprocess.Popen([tmp_exe, '--phase2'], env=env, close_fds=True,
                         creationflags=0x00000008 | 0x08000000)
        return tmp_exe
    except Exception:
        try: os.remove(tmp_exe)
        except Exception: pass
        return None

def phase2_silent(install_dir, log_fn=None):
    def L(s):
        if log_fn: log_fn(s)
    L('[*] Dosyalar siliniyor...')
    time.sleep(2.5)
    kill_running(); time.sleep(0.8)
    remove_shortcuts(); remove_registry(); time.sleep(0.5)
    ok = delete_dir(install_dir)
    if not ok:
        time.sleep(2.0)
        ok = delete_dir(install_dir)
    L('[OK] Kaldirma tamamlandi.' if ok else '[!] Bazi dosyalar silinemedi.')
    try:
        cmd = 'ping 127.0.0.1 -n 3 >nul & del /f /q "' + sys.executable + '"'
        subprocess.Popen(['cmd','/c',cmd], creationflags=0x08000000)
    except Exception:
        pass
    return 0 if ok else 1

class UninstallerGUI:
    def __init__(self, root, install_dir):
        self.root = root
        self.install_dir = install_dir
        self.log_queue = queue.Queue()

        init_scale(root)
        self.root.title(PROJECT_NAME + ' programını Kaldır')

        w, h = fit_window(root, 620, 520)
        self.root.minsize(S(540), S(460))
        center_window(root, w, h)
        self.root.resizable(False, False)

        apply_window_icon(self.root)

        self.build_ui()
        self.root.after(80, self.pump)

    def build_ui(self):
        title_font = font(15, bold=True)
        mono_font  = font(9, family='Consolas')
        bold_font  = font(10, bold=True)
        default_font = font(9.5)

        try:
            style = ttk.Style()
            style.configure('.', font=default_font)
            style.configure('TButton', font=bold_font)
        except Exception:
            pass

        ttk.Label(self.root, text=PROJECT_NAME, font=title_font)\
            .pack(anchor='w', padx=S(18), pady=(S(16), S(2)))
        ttk.Label(self.root, text='Kaldırma hedefi:')\
            .pack(anchor='w', padx=S(18))
        ttk.Label(self.root, text=self.install_dir, font=mono_font)\
            .pack(anchor='w', padx=S(18))

        self.status_var = tk.StringVar(value='Kaldırmayı onaylayın.')
        ttk.Label(self.root, textvariable=self.status_var)\
            .pack(anchor='w', padx=S(18), pady=(S(12), S(4)))

        self.progress = ttk.Progressbar(self.root, mode='determinate', maximum=100)
        self.progress.pack(fill='x', padx=S(18))

        logf = ttk.LabelFrame(self.root, text='İşlem günlüğü', padding=S(4))
        logf.pack(fill='both', expand=True, padx=S(18), pady=(S(8), S(8)))

        self.log_text = tk.Text(
            logf, height=8, wrap='word', font=mono_font,
            background='#101418', foreground='#d6e2ea', relief='flat',
        )
        self.log_text.pack(side='left', fill='both', expand=True)
        sb = ttk.Scrollbar(logf, orient='vertical', command=self.log_text.yview)
        sb.pack(side='right', fill='y')
        self.log_text.configure(yscrollcommand=sb.set, state='disabled')

        btnf = ttk.Frame(self.root)
        btnf.pack(fill='x', padx=S(18), pady=(0, S(14)))
        self.cancel_btn = ttk.Button(btnf, text='Vazgeç', command=self.root.destroy)
        self.cancel_btn.pack(side='right', padx=(S(6), 0))
        self.go_btn = ttk.Button(btnf, text='Kaldır', command=self.start)
        self.go_btn.pack(side='right')

    def log(self, text):
        msg = str(text)
        self.log_queue.put(msg)
        log(msg)

    def pump(self):
        try:
            while True:
                m = self.log_queue.get_nowait()
                self.log_text.configure(state='normal')
                self.log_text.insert('end', m + '\n')
                self.log_text.see('end')
                self.log_text.configure(state='disabled')
        except queue.Empty:
            pass
        self.root.after(80, self.pump)

    def start(self):
        self.go_btn.configure(state='disabled')
        self.cancel_btn.configure(state='disabled')
        self.status_var.set('Kaldırılıyor...')
        self.progress['value'] = 10
        self.log('[*] Kaldırma başlatıldı.')
        threading.Thread(target=self.worker, daemon=True).start()

    def worker(self):
        try:
            self.status_var.set('Uygulama kapatılıyor...')
            self.progress['value'] = 10
            self.log('[*] Çalışan uygulama kapatılıyor...')
            kill_running()
            time.sleep(0.6)

            self.status_var.set('Kaldırma yardımcısı hazırlanıyor...')
            self.progress['value'] = 40
            self.log('[*] Kaldırma yardımcısı hazırlanıyor...')
            tmp_exe = spawn_phase2(self.install_dir)

            if tmp_exe:
                self.progress['value'] = 100
                self.status_var.set('Kaldırılıyor... Pencere kapanacak.')
                self.log('[OK] Kaldırma arka planda başlatıldı.')
                self.log('     Dosyalar birkaç saniye içinde silinecek.')
                time.sleep(0.8)
                try: self.root.destroy()
                except Exception: pass
                return

            self.log('[!] Yardımcı kopya oluşturulamadı, doğrudan siliniyor...')
            remove_shortcuts(); remove_registry(); time.sleep(0.3)
            self.progress['value'] = 70
            ok = delete_dir(self.install_dir)
            self.progress['value'] = 100
            self.status_var.set('Kaldırma tamamlandı.' if ok else 'Kaldırma kısmen tamamlandı.')
            self.log('[OK] Kaldırma tamamlandı.' if ok else '[!] Bazı dosyalar silinemedi (uygulama hala çalışıyor olabilir).')
            try:
                cmd = 'ping 127.0.0.1 -n 3 >nul & del /f /q "' + sys.executable + '"'
                subprocess.Popen(['cmd','/c',cmd], creationflags=0x08000000)
            except Exception:
                pass
            self.root.after(1500, self.root.destroy)
        except Exception as e:
            self.log('HATA: ' + str(e))
            try: messagebox.showerror(PROJECT_NAME, str(e))
            except Exception: pass
            try:
                self.go_btn.configure(state='normal')
                self.cancel_btn.configure(state='normal')
            except Exception: pass

def main():
    install_dir = get_install_dir()
    if '--phase2' in sys.argv:
        return phase2_silent(install_dir, log_fn=log)
    if '--quiet' in sys.argv:
        kill_running(); time.sleep(0.8)
        if spawn_phase2(install_dir): return 0
        remove_shortcuts(); remove_registry(); delete_dir(install_dir); return 0
    try:
        root = tk.Tk()
    except Exception:
        try:
            if ctypes.windll.user32.MessageBoxW(0, PROJECT_NAME + ' kaldirilsin mi?', PROJECT_NAME, 4|0x40) == 6:
                kill_running(); time.sleep(0.8)
                if spawn_phase2(install_dir): return 0
                remove_shortcuts(); remove_registry(); delete_dir(install_dir)
        except Exception: pass
        return 0
    app = UninstallerGUI(root, install_dir)
    root.mainloop()
    return 0

if __name__ == '__main__':
    try: sys.exit(main())
    except Exception:
        import traceback; traceback.print_exc()
        sys.exit(1)
