# -*- coding: utf-8 -*-
"""PyExeBuilder paralel sikistirici (v8.8)."""
import os, sys, json, math, time, shutil, multiprocessing as mp
import py7zr

PARTS_SUBDIR = '__parts__'

def _split_file(full_path, rel_posix, size, chunk_size, out_root):
    num_parts = int(math.ceil(size / float(chunk_size)))
    part_names = []
    with open(full_path, 'rb') as fin:
        for i in range(num_parts):
            part_rel  = '%s/%s.__p%04d' % (PARTS_SUBDIR, rel_posix, i + 1)
            part_full = os.path.join(out_root, part_rel.replace('/', os.sep))
            pdir = os.path.dirname(part_full)
            if pdir and not os.path.isdir(pdir): os.makedirs(pdir, exist_ok=True)
            remaining = min(chunk_size, size - i * chunk_size)
            written = 0
            with open(part_full, 'wb') as fout:
                while written < remaining:
                    to_read = min(4 * 1024 * 1024, remaining - written)
                    data = fin.read(to_read)
                    if not data: break
                    fout.write(data)
                    written += len(data)
            part_names.append(part_rel)
    return part_names

def scan_items(out_root, chunk_size, marker, setup_exe_name):
    root_exclude = set()
    root_exclude.add(marker)
    root_exclude.add(PARTS_SUBDIR)
    root_exclude.add('_derleme_gecici')
    root_exclude.add('manifest.json')
    if setup_exe_name:
        root_exclude.add(setup_exe_name)

    parts_root = os.path.join(out_root, PARTS_SUBDIR)
    if os.path.isdir(parts_root):
        shutil.rmtree(parts_root, ignore_errors=True)

    items = []; joins = []

    def handle(rel_posix, full_path, size):
        if size <= chunk_size:
            items.append((rel_posix, size))
            return
        parts = _split_file(full_path, rel_posix, size, chunk_size, out_root)
        try: os.remove(full_path)
        except Exception: pass
        joins.append({'target': rel_posix, 'parts': parts, 'total_bytes': size})
        for p_rel in parts:
            p_full = os.path.join(out_root, p_rel.replace('/', os.sep))
            try: items.append((p_rel, os.path.getsize(p_full)))
            except Exception: items.append((p_rel, 0))

    for entry in sorted(os.listdir(out_root)):
        if entry in root_exclude: continue
        full = os.path.join(out_root, entry)
        if os.path.isfile(full):
            handle(entry, full, os.path.getsize(full))
        elif os.path.isdir(full):
            for root, dirs, files in os.walk(full):
                dirs[:] = [d for d in dirs if d not in ('__pycache__',)]
                for f in files:
                    if f == marker: continue
                    fp = os.path.join(root, f)
                    rel = os.path.relpath(fp, out_root).replace('\\', '/')
                    handle(rel, fp, os.path.getsize(fp))
    return items, joins

def binpack(items, chunk_size):
    ordered = sorted(items, key=lambda x: -x[1])
    chunks = []
    for rel, size in ordered:
        placed = False
        for c in chunks:
            if c['total'] + size <= chunk_size:
                c['items'].append(rel); c['total'] += size
                placed = True; break
        if not placed:
            chunks.append({'items': [rel], 'total': size})
    return chunks

def compress_chunk(task):
    idx, chunk, out_root, setup_dir = task
    payload_name = 'payload_%04d.7z' % idx
    payload_path = os.path.join(setup_dir, payload_name)
    original_bytes = int(chunk.get('total', 0))
    last_err = ''
    for attempt in range(1, 6):
        try:
            if os.path.exists(payload_path):
                try: os.remove(payload_path)
                except Exception: pass
            with py7zr.SevenZipFile(payload_path, 'w',
                filters=[{'id': py7zr.FILTER_LZMA2, 'preset': 9 | py7zr.PRESET_EXTREME}]) as archive:
                for rel in chunk['items']:
                    full = os.path.join(out_root, rel.replace('/', os.sep))
                    if not os.path.isfile(full): raise IOError('Kaynak yok: ' + full)
                    archive.write(full, rel)
            if not os.path.isfile(payload_path) or os.path.getsize(payload_path) == 0:
                raise IOError('Arsiv bos olustu')
            comp_bytes = os.path.getsize(payload_path)
            ratio = (comp_bytes / float(original_bytes) * 100.0) if original_bytes > 0 else 0.0
            return {'ok': True, 'index': idx, 'file': payload_name, 'bytes': comp_bytes,
                    'original_bytes': original_bytes, 'ratio_percent': ratio,
                    'savings_percent': max(0.0, 100.0 - ratio),
                    'item_count': len(chunk['items']), 'attempts': attempt}
        except Exception as e:
            last_err = '%s: %s' % (type(e).__name__, e)
            time.sleep(2.5)
    return {'ok': False, 'index': idx, 'file': payload_name, 'error': last_err,
            'original_bytes': original_bytes, 'item_count': len(chunk['items']), 'attempts': 5}

def _mb(b): return b / 1024.0 / 1024.0

def main():
    if len(sys.argv) < 6:
        sys.stderr.write('kullanim: _plan_and_compress.py <out_root> <setup_dir> <chunk_size> <workers> <marker> [setup_exe_name]\n')
        sys.exit(2)
    out_root = sys.argv[1]; setup_dir = sys.argv[2]
    chunk_size = int(sys.argv[3]); workers = int(sys.argv[4])
    marker = sys.argv[5]
    setup_exe_name = sys.argv[6] if len(sys.argv) > 6 else ''
    os.makedirs(setup_dir, exist_ok=True)
    print('[plan] OutRoot : %s' % out_root)
    print('[plan] SetupDir: %s' % setup_dir)
    print('[plan] Chunk   : %d MB,  Workers: %d' % (chunk_size // (1024*1024), workers))
    sys.stdout.flush()
    t0 = time.time()
    items, joins = scan_items(out_root, chunk_size, marker, setup_exe_name)
    print('[plan] %d oge tarandi, %d buyuk dosya parcalandi (%.1fs)' % (len(items), len(joins), time.time() - t0))
    sys.stdout.flush()
    chunks = binpack(items, chunk_size)
    total_orig_all = sum(c['total'] for c in chunks)
    print('[plan] %d chunk olusturuldu (toplam ham veri: %.2f MB)' % (len(chunks), _mb(total_orig_all)))
    sys.stdout.flush()
    t0 = time.time()
    tasks = [(i + 1, c, out_root, setup_dir) for i, c in enumerate(chunks)]
    results = []
    try:
        ctx = mp.get_context('spawn')
        with ctx.Pool(processes=workers) as pool:
            for r in pool.imap_unordered(compress_chunk, tasks):
                results.append(r)
                if r['ok']:
                    print('[compress] %s OK  Ham: %.2f MB -> Arsiv: %.2f MB  (%.1f%%)' % (
                        r['file'], _mb(r.get('original_bytes', 0)), _mb(r['bytes']), r.get('ratio_percent', 0.0)))
                else:
                    print('[compress] %s FAIL (%s)' % (r['file'], r.get('error', '')))
                sys.stdout.flush()
    except Exception as e:
        print('[compress] Pool hatasi: %s' % e)
        sys.exit(3)
    print('[compress] Tum chunklar %.1fs icinde islendi' % (time.time() - t0))
    sys.stdout.flush()
    results.sort(key=lambda x: x['index'])
    ok_results = [r for r in results if r['ok']]
    failed = [r for r in results if not r['ok']]
    total_comp = sum(r['bytes'] for r in ok_results)
    total_orig_ok = sum(r.get('original_bytes', 0) for r in ok_results)
    total_ratio = (total_comp / float(total_orig_ok) * 100.0) if total_orig_ok > 0 else 0.0
    total_saving = max(0.0, 100.0 - total_ratio)
    print('')
    print('========== SIKISTIRMA OZETI ==========')
    for r in ok_results:
        print('  %s: %.2f MB -> %.2f MB  (%.1f%% oran, %.1f%% kazanc, %d oge)' % (
            r['file'], _mb(r.get('original_bytes', 0)), _mb(r['bytes']),
            r.get('ratio_percent', 0.0), r.get('savings_percent', 0.0), r['item_count']))
    print('  TOPLAM: %.2f MB -> %.2f MB  (%.1f%% oran, %.1f%% kazanc)' % (
        _mb(total_orig_ok), _mb(total_comp), total_ratio, total_saving))
    print('======================================')
    sys.stdout.flush()
    manifest = {
        'version': 2, 'chunk_size_bytes': chunk_size,
        'archives': [{'file': r['file'], 'bytes': r['bytes'], 'original_bytes': r.get('original_bytes', 0),
                      'ratio_percent': round(r.get('ratio_percent', 0.0), 2),
                      'savings_percent': round(r.get('savings_percent', 0.0), 2),
                      'item_count': r['item_count']} for r in ok_results],
        'joins': joins,
        'totals': {'original_bytes': total_orig_ok, 'compressed_bytes': total_comp,
                   'ratio_percent': round(total_ratio, 2), 'savings_percent': round(total_saving, 2),
                   'chunk_count': len(ok_results), 'split_file_count': len(joins)},
        'failed_chunks': [r['index'] for r in failed],
    }
    with open(os.path.join(setup_dir, 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    if failed:
        print('[manifest] BASARISIZ CHUNK: %s' % [r['index'] for r in failed])
        sys.exit(4)
    sys.exit(0)

if __name__ == '__main__':
    main()
