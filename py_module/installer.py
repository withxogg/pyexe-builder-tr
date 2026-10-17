# -*- coding: utf-8 -*-
"""PyExeBuilder tarafindan otomatik uretilmis GUI kurulum betigi (v8.8)."""
import os, sys, time, ctypes, shutil, subprocess, winreg, json, threading, queue
import tkinter as tk
from tkinter import ttk, messagebox

PROJECT_NAME = __PROJECT_NAME__
EXE_NAME     = __EXE_NAME__

# ─── DPI awareness ───────────────────────────────────────────────────────
# tk.Tk() olusturulmadan ONCE cagrilmali.
def _enable_dpi_awareness():
    try:
        ctypes.windll.user32.SetProcessDpiAwarenessContext(-4)   # PerMonitorV2
        return
    except Exception:
        pass
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)           # PerMonitor
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
    # Tk'nin otomatik DPI font buyutmesini kapat (cift olcekleme olmasin)
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
    # Negatif deger = Tk'da 'piksel' anlamina gelir -> DPI'dan bagimsiz
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
    return os.path.join(base, 'pyexebuilder_install.log')

def log(msg):
    try:
        with open(_log_path(), 'a', encoding='utf-8') as f:
            f.write('[%s] %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), msg))
    except Exception:
        pass

# ─── Yollar ──────────────────────────────────────────────────────────────
def get_base_dir():
    if getattr(sys, 'frozen', False):
        return getattr(sys, '_MEIPASS', os.path.dirname(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))

BASE_DIR      = get_base_dir()
MANIFEST_PATH = os.path.join(BASE_DIR, 'manifest.json')

def get_install_dir():
    base = os.environ.get('LOCALAPPDATA') or os.environ.get('USERPROFILE') or os.path.expanduser('~')
    return os.path.join(base, 'Programs', PROJECT_NAME)

INSTALL_DIR = get_install_dir()

def _mb(b):
    try: return float(b) / 1024.0 / 1024.0
    except Exception: return 0.0

def load_manifest():
    with open(MANIFEST_PATH, 'r', encoding='utf-8') as f:
        return json.load(f)

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
        root._pb_icon_ref = img   # referans tut (GC'ye kapilmasin)
        return True
    except Exception:
        return False

def apply_window_icon(root):
    base = get_base_dir()
    for name in ('_pb_window_icon.ico', '_pb_window_icon.png'):
        p = os.path.join(base, name)
        if os.path.isfile(p) and _set_window_icon(root, p):
            return

class InstallerGUI:
    def __init__(self, root):
        self.root = root
        init_scale(root)
        self.root.title(PROJECT_NAME + ' Kurulum')

        w, h = fit_window(root, 680, 520)
        self.root.minsize(S(560), S(460))
        center_window(root, w, h)
        self.root.resizable(False, False)

        apply_window_icon(self.root)

        self.log_queue = queue.Queue()
        self.install_dir = INSTALL_DIR
        self.build_ui()
        self.root.after(80, self.pump_queue)
        threading.Thread(target=self.worker, daemon=True).start()

    def build_ui(self):
        default_font = font(9.5)
        bold_font    = font(10, bold=True)
        title_font   = font(16, bold=True)
        mono_font    = font(9, family='Consolas')

        try:
            style = ttk.Style()
            style.configure('.', font=default_font)
            style.configure('TLabel', font=default_font)
            style.configure('TButton', font=bold_font)
            style.configure('TLabelframe.Label', font=bold_font)
        except Exception:
            pass

        top = ttk.Frame(self.root, padding=(S(18), S(16), S(18), S(6)))
        top.pack(fill='x')
        ttk.Label(top, text=PROJECT_NAME, font=title_font).pack(anchor='w')
        ttk.Label(top, text='Kurulum hedefi:', foreground='#555').pack(anchor='w', pady=(S(6), 0))
        ttk.Label(top, text=self.install_dir, font=mono_font).pack(anchor='w')

        self.status_var = tk.StringVar(value='Hazırlanıyor...')
        stat = ttk.Frame(self.root, padding=(S(18), S(6), S(18), S(6)))
        stat.pack(fill='x')
        ttk.Label(stat, textvariable=self.status_var).pack(anchor='w')

        prog = ttk.Frame(self.root, padding=(S(18), 0, S(18), S(6)))
        prog.pack(fill='x')
        self.progress = ttk.Progressbar(prog, mode='determinate', maximum=100)
        self.progress.pack(fill='x')

        logf = ttk.LabelFrame(self.root, text='İşlem günlüğü', padding=S(4))
        logf.pack(fill='both', expand=True, padx=S(18), pady=(S(4), S(8)))

        self.log_text = tk.Text(
            logf, height=9, wrap='word', font=mono_font,
            background='#101418', foreground='#d6e2ea',
            insertbackground='white', relief='flat',
        )
        self.log_text.pack(side='left', fill='both', expand=True)
        sb = ttk.Scrollbar(logf, orient='vertical', command=self.log_text.yview)
        sb.pack(side='right', fill='y')
        self.log_text.configure(yscrollcommand=sb.set, state='disabled')

        btnf = ttk.Frame(self.root, padding=(S(18), 0, S(18), S(14)))
        btnf.pack(fill='x')
        self.close_btn = ttk.Button(btnf, text='Kapat', command=self.root.destroy, state='disabled')
        self.close_btn.pack(side='right')

    def log(self, text):
        msg = str(text)
        self.log_queue.put(msg)
        log(msg)

    def pump_queue(self):
        try:
            while True:
                msg = self.log_queue.get_nowait()
                self.log_text.configure(state='normal')
                self.log_text.insert('end', msg + '\n')
                self.log_text.see('end')
                self.log_text.configure(state='disabled')
        except queue.Empty:
            pass
        self.root.after(80, self.pump_queue)

    def set_progress(self, value, status=None):
        try:
            self.progress['value'] = max(0, min(100, value))
        except Exception:
            pass
        if status:
            self.status_var.set(status)

    def worker(self):
        try:
            self.do_install()
        except Exception as e:
            import traceback
            tb = traceback.format_exc()
            self.log('HATA: ' + str(e))
            self.log(tb)
            self.set_progress(0, 'Kurulum başarısız')
            try:
                messagebox.showerror(
                    PROJECT_NAME,
                    'Kurulum başarısız:\n\n%s\n\nAyrıntılı log:\n%s' % (e, _log_path())
                )
            except Exception:
                pass
            try: self.close_btn.configure(state='normal')
            except Exception: pass

    def do_install(self):
        self.set_progress(2, 'Manifest okunuyor...')
        self.log('[*] Manifest okunuyor: ' + MANIFEST_PATH)
        manifest = load_manifest()
        archives = manifest.get('archives', []) or []
        joins    = manifest.get('joins', []) or []
        if not archives:
            raise RuntimeError('Manifestte arsiv yok.')

        total_comp = sum(int(a.get('bytes', 0)) for a in archives) or 1
        done = 0

        try:
            os.makedirs(INSTALL_DIR, exist_ok=True)
        except Exception as e:
            raise RuntimeError('Klasor olusturulamadi: ' + str(e))

        self.set_progress(5, 'Arşivler çıkartılıyor...')
        self.log('[*] Hedef klasör: ' + INSTALL_DIR)
        self.log('[*] Toplam %d arşiv çıkarılacak' % len(archives))

        try:
            import py7zr
        except ImportError:
            raise RuntimeError('py7zr kutuphanesi bulunamadi.')

        for i, arc in enumerate(archives, 1):
            arc_path = os.path.join(BASE_DIR, arc['file'])
            if not os.path.isfile(arc_path):
                raise RuntimeError('Arsiv bulunamadi: ' + arc_path)
            comp  = int(arc.get('bytes', 0))
            orig  = int(arc.get('original_bytes', 0))
            ratio = float(arc.get('ratio_percent', 0.0)) or (comp / float(orig) * 100.0 if orig else 0.0)
            self.log('    [%d/%d] %s  (%.2f MB, %.1f%% sıkıştırma)' % (i, len(archives), arc['file'], _mb(comp), ratio))
            with py7zr.SevenZipFile(arc_path, mode='r') as z:
                z.extractall(path=INSTALL_DIR)
            done += comp
            pct = 5 + int((done / float(total_comp)) * 70)
            self.set_progress(pct, 'Arşiv çıkarılıyor... (%d/%d)' % (i, len(archives)))

        if joins:
            self.set_progress(78, 'Büyük dosyalar birleştiriliyor...')
            self.log('[*] %d parçalı dosya birleştirilecek' % len(joins))
            for j in joins:
                target_rel  = j['target']
                target_full = os.path.join(INSTALL_DIR, target_rel.replace('/', os.sep))
                target_dir  = os.path.dirname(target_full)
                if target_dir: os.makedirs(target_dir, exist_ok=True)
                self.log('    -> %s  (%.2f MB)' % (target_rel, _mb(j.get('total_bytes', 0))))
                with open(target_full, 'wb') as fout:
                    for part_rel in j['parts']:
                        part_full = os.path.join(INSTALL_DIR, part_rel.replace('/', os.sep))
                        if not os.path.isfile(part_full):
                            raise RuntimeError('Parca bulunamadi: ' + part_full)
                        with open(part_full, 'rb') as fin:
                            shutil.copyfileobj(fin, fout, 4 * 1024 * 1024)
            parts_dir = os.path.join(INSTALL_DIR, '__parts__')
            if os.path.isdir(parts_dir):
                shutil.rmtree(parts_dir, ignore_errors=True)

        self.set_progress(85, 'Kısayollar oluşturuluyor...')
        target = self.find_main_exe()
        if not target:
            raise RuntimeError('Kurulum sonrasi calistirilabilir exe bulunamadi.')
        shortcuts = self.create_all_shortcuts(target)
        self.log('[*] %d kısayol oluşturuldu' % len(shortcuts))

        self.set_progress(92, 'Kayıt defteri girdileri yazılıyor...')
        uninst = self.register_uninstall(target)
        if uninst:
            self.log('[*] Kaldırma aracı: ' + uninst)

        # Özet log dosyası (kullanıcı desteği için)
        try:
            summary = os.path.join(INSTALL_DIR, 'install.log')
            totals = manifest.get('totals', {}) or {}
            with open(summary, 'w', encoding='utf-8') as f:
                f.write('Proje         : %s\n' % PROJECT_NAME)
                f.write('Sürüm         : %s\n' % manifest.get('version', '?'))
                f.write('Kurulum yeri  : %s\n' % INSTALL_DIR)
                f.write('Tarih         : %s\n' % time.strftime('%Y-%m-%d %H:%M:%S'))
                f.write('Arşiv sayısı  : %d\n' % len(archives))
                f.write('Toplam ham    : %.2f MB\n' % _mb(totals.get('original_bytes', 0)))
                f.write('Sıkıştırılmış : %.2f MB\n' % _mb(totals.get('compressed_bytes', 0)))
                f.write('Sıkıştırma    : %.1f%%\n' % float(totals.get('ratio_percent', 0.0)))
                f.write('Ana exe       : %s\n' % os.path.basename(target))
        except Exception:
            pass

        self.set_progress(100, 'Kurulum tamamlandı.')
        self.log('')
        self.log('[OK] Kurulum tamamlandı.')
        self.log('     Konum: ' + INSTALL_DIR)
        try: self.close_btn.configure(state='normal')
        except Exception: pass

        self.root.after(200, lambda: self.ask_launch(target))

    def find_main_exe(self):
        target = os.path.join(INSTALL_DIR, EXE_NAME + '.exe')
        if os.path.isfile(target): return target
        best = None; best_sz = -1
        for root, dirs, files in os.walk(INSTALL_DIR):
            for f in files:
                if f.lower().endswith('.exe') and not f.lower().startswith('uninstall'):
                    p = os.path.join(root, f)
                    try: sz = os.path.getsize(p)
                    except Exception: sz = 0
                    if sz > best_sz:
                        best_sz = sz; best = p
        return best

    def _make_shortcut(self, lnk_path, target, workdir):
        try:
            import win32com.client
            shell = win32com.client.Dispatch('WScript.Shell')
            sc = shell.CreateShortCut(lnk_path)
            sc.TargetPath = target
            sc.WorkingDirectory = workdir
            sc.IconLocation = target
            sc.Save()
            return True
        except ImportError:
            pass
        except Exception:
            pass
        try:
            ps = (
                '$ws = New-Object -ComObject WScript.Shell; '
                '$sc = $ws.CreateShortcut("%s"); '
                '$sc.TargetPath = "%s"; '
                '$sc.WorkingDirectory = "%s"; '
                '$sc.IconLocation = "%s"; '
                '$sc.Save()'
            ) % (lnk_path.replace('"','""'), target.replace('"','""'),
                 workdir.replace('"','""'), target.replace('"','""'))
            # Pencereyi tamamen gizle: CREATE_NO_WINDOW + STARTF_USESHOWWINDOW/SW_HIDE
            _flags = 0x08000000
            _si = None
            try:
                _si = subprocess.STARTUPINFO()
                _si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                _si.wShowWindow = 0
            except Exception:
                _si = None
            subprocess.run(
                ['powershell','-NoProfile','-ExecutionPolicy','Bypass',
                 '-WindowStyle','Hidden','-Command',ps],
                capture_output=True, timeout=30,
                creationflags=_flags, startupinfo=_si,
            )
            return os.path.isfile(lnk_path)
        except Exception:
            return False

    def create_all_shortcuts(self, target):
        created = []
        start_menu = os.path.join(os.environ.get('APPDATA',''), 'Microsoft','Windows','Start Menu','Programs')
        if os.path.isdir(start_menu):
            lnk = os.path.join(start_menu, PROJECT_NAME + '.lnk')
            if self._make_shortcut(lnk, target, INSTALL_DIR):
                created.append(lnk)
        desktop = os.path.join(os.environ.get('USERPROFILE',''), 'Desktop')
        if os.path.isdir(desktop):
            lnk = os.path.join(desktop, PROJECT_NAME + '.lnk')
            if self._make_shortcut(lnk, target, INSTALL_DIR):
                created.append(lnk)
        return created

    def register_uninstall(self, target):
        uninst_exe = os.path.join(INSTALL_DIR, 'uninstall.exe')
        if not os.path.isfile(uninst_exe): return None
        try:
            reg_path = 'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\' + PROJECT_NAME
            key = winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, reg_path, 0, winreg.KEY_WRITE)
            winreg.SetValueEx(key, 'DisplayName', 0, winreg.REG_SZ, PROJECT_NAME)
            winreg.SetValueEx(key, 'UninstallString', 0, winreg.REG_SZ, '"' + uninst_exe + '"')
            winreg.SetValueEx(key, 'QuietUninstallString', 0, winreg.REG_SZ, '"' + uninst_exe + '" --quiet')
            winreg.SetValueEx(key, 'InstallLocation', 0, winreg.REG_SZ, INSTALL_DIR)
            winreg.SetValueEx(key, 'DisplayIcon', 0, winreg.REG_SZ, target)
            winreg.SetValueEx(key, 'Publisher', 0, winreg.REG_SZ, 'PyExeBuilder')
            winreg.SetValueEx(key, 'NoModify', 0, winreg.REG_DWORD, 1)
            winreg.SetValueEx(key, 'NoRepair', 0, winreg.REG_DWORD, 1)
            winreg.CloseKey(key)
        except Exception:
            pass
        return uninst_exe

    def ask_launch(self, target):
        try:
            ans = messagebox.askyesno(PROJECT_NAME, 'Program simdi calistirilsin mi?')
            if ans:
                subprocess.Popen([target], cwd=INSTALL_DIR)
        except Exception:
            pass

def main():
    try:
        root = tk.Tk()
    except Exception:
        print(PROJECT_NAME + ' kuruluyor...')
        try:
            import tkinter as _tk  # noqa
        except Exception:
            print('HATA: tkinter yok.')
            return 1
    app = InstallerGUI(root)
    root.mainloop()
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        try:
            import traceback
            traceback.print_exc()
            try:
                import tkinter.messagebox as mb
                mb.showerror('Hata', str(e))
            except Exception:
                pass
        except Exception:
            pass
        sys.exit(1)
