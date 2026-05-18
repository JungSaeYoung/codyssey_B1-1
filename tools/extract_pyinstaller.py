#!/usr/bin/env python3
"""
extract_pyinstaller.py — PyInstaller single-file ELF 에서 번들 파일들을 추출.

사용법:
    python tools/extract_pyinstaller.py [입력경로]
    기본 입력: bin/agent-app
    출력 폴더: bin/agent-app_extracted/
"""
import sys, os, struct, zlib
from pathlib import Path
from elftools.elf.elffile import ELFFile

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BIN = ROOT / "bin" / "agent-app"

COOKIE = b'MEI\x0c\x0b\x0a\x0b\x0e'


def find_pydata_bounds(path):
    """ELF 안에서 pydata 섹션의 (file_offset, size) 반환."""
    with open(path, 'rb') as f:
        elf = ELFFile(f)
        sec = elf.get_section_by_name('pydata')
        if sec is None:
            return None, None
        return sec['sh_offset'], sec['sh_size']


def read_archive(path):
    """pydata 섹션을 통째로 읽어 archive bytes 반환."""
    off, size = find_pydata_bounds(path)
    if off is None:
        raise SystemExit("pydata 섹션을 찾지 못함 — PyInstaller 바이너리가 아님?")
    with open(path, 'rb') as f:
        f.seek(off)
        return f.read(size), off


def parse_cookie(archive):
    """archive 끝의 cookie 를 찾아 메타데이터 반환."""
    ci = archive.rfind(COOKIE)
    if ci < 0:
        raise SystemExit("PyInstaller cookie 를 못 찾음")
    # 8 magic + 4 length + 4 toc_pos + 4 toc_len + 4 pyver + 64 pylibname
    length, toc_pos, toc_len, pyver = struct.unpack('>IIII', archive[ci+8:ci+24])
    pylibname = archive[ci+24:ci+88].rstrip(b'\x00').decode('utf-8', errors='replace')
    return {
        'cookie_pos':  ci,
        'length':      length,
        'toc_pos':     toc_pos,
        'toc_len':     toc_len,
        'pyver':       pyver,
        'pylibname':   pylibname,
        'archive_start': ci + 88 - length,
    }


def parse_toc(archive, meta):
    """TOC 영역을 파싱해 entry 리스트 반환."""
    # archive_start 가 archive bytes 안에서의 시작 오프셋
    toc_abs = meta['archive_start'] + meta['toc_pos']
    toc = archive[toc_abs : toc_abs + meta['toc_len']]

    entries = []
    p = 0
    while p < len(toc):
        if p + 18 > len(toc):
            break
        # entry_len = 전체 entry 의 byte 길이
        entry_len, data_off, comp_len, uncomp_len = struct.unpack('>IIII', toc[p:p+16])
        if entry_len == 0 or entry_len > len(toc) - p:
            break
        comp_flag = toc[p+16]
        typecode  = chr(toc[p+17])
        name      = toc[p+18:p+entry_len].rstrip(b'\x00').decode('utf-8', errors='replace')
        entries.append({
            'data_off':   data_off,
            'comp_len':   comp_len,
            'uncomp_len': uncomp_len,
            'compressed': bool(comp_flag),
            'typecode':   typecode,
            'name':       name,
        })
        p += entry_len
    return entries


PYC_HEADER_BY_VER = {
    # CPython magic numbers (first 2 bytes of bytecode magic for each version)
    # https://github.com/python/cpython/blob/main/Lib/importlib/_bootstrap_external.py
    312: b'\xcb\x0d\x0d\x0a',   # Python 3.12
    311: b'\xa7\x0d\x0d\x0a',
    310: b'\x6f\x0d\x0d\x0a',
    309: b'\x61\x0d\x0d\x0a',
}


def build_pyc_header(pyver):
    """marshal-only 파일을 valid .pyc 로 만들기 위한 16-byte 헤더 생성."""
    magic = PYC_HEADER_BY_VER.get(pyver, PYC_HEADER_BY_VER[312])
    # bit field(4) + timestamp(4) + size(4) — 모두 0 으로 두어도 dis 가 읽을 수 있다
    return magic + b'\x00' * 12


def extract(path, out_dir):
    archive, pydata_file_off = read_archive(path)
    meta = parse_cookie(archive)
    print(f"== {path.name} (pydata @ file offset 0x{pydata_file_off:x}) ==")
    print(f"  archive 길이 : {meta['length']:,} bytes")
    print(f"  TOC pos      : 0x{meta['toc_pos']:x} (archive 내부)")
    print(f"  TOC len      : {meta['toc_len']} bytes")
    print(f"  Python 버전  : {meta['pyver'] // 100}.{meta['pyver'] % 100}")
    print(f"  python lib   : {meta['pylibname']}")
    print()

    entries = parse_toc(archive, meta)
    print(f"  TOC 항목 수  : {len(entries)}")
    print()

    out_dir.mkdir(parents=True, exist_ok=True)
    pyc_header = build_pyc_header(meta['pyver'])

    summary = {'s': 0, 'm': 0, 'M': 0, 'b': 0, 'd': 0, 'z': 0, 'Z': 0, 'o': 0}
    for e in entries:
        # 원본 데이터 위치 (archive 내부)
        start = meta['archive_start'] + e['data_off']
        raw = archive[start : start + e['comp_len']]

        # zlib 압축 해제
        if e['compressed']:
            try:
                data = zlib.decompress(raw)
            except zlib.error:
                data = raw
        else:
            data = raw

        # 안전한 파일명
        safe_name = e['name'].replace('/', os.sep).replace('\\', os.sep)
        target = out_dir / safe_name

        # 타입에 따라 확장자 보정 — Python source code 류는 .pyc 로 저장 + 헤더 추가
        if e['typecode'] in ('s', 'm', 'M'):
            target = target.with_suffix('.pyc')
            # marshalled code object → .pyc 로 복원
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, 'wb') as f:
                f.write(pyc_header)
                f.write(data)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, 'wb') as f:
                f.write(data)

        summary[e['typecode']] = summary.get(e['typecode'], 0) + 1

    print("== 추출 완료 ==")
    type_names = {
        's':'script (entry)', 'm':'module', 'M':'package',
        'b':'binary (.so/.dll)', 'd':'data', 'z':'PYZ', 'Z':'PYZ-zlib',
        'o':'option',
    }
    for t, n in sorted(summary.items()):
        if n:
            print(f"  {t} ({type_names.get(t,'?')}): {n}")
    print(f"\n  출력 폴더: {out_dir}")
    return out_dir, entries


if __name__ == '__main__':
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_BIN
    out = src.parent / f"{src.name}_extracted"
    extract(src, out)
