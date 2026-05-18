#!/usr/bin/env python3
"""
disasm_pyc.py — .pyc 파일을 dis 모듈로 분해해 사람 친화 형식으로 출력.

사용법:
    python tools/disasm_pyc.py [pyc경로]
    기본: bin/agent-app_extracted/linux_pbl_v2.pyc

decompyle6/decompyle3 가 Python 3.12 를 완전히 지원하기 전까지 가장 안정적인 방법.
"""
import sys, marshal, dis, types
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent
DEFAULT = ROOT / "bin" / "agent-app_extracted" / "linux_pbl_v2.pyc"


def load_pyc(path):
    """16-byte 헤더 건너뛰고 marshal 로드."""
    with open(path, 'rb') as f:
        header = f.read(16)
        code = marshal.load(f)
    return header, code


def summarize_code(code, depth=0):
    """code object 의 상수·이름·중첩 코드까지 재귀로 요약."""
    indent = "  " * depth
    print(f"{indent}━━ {code.co_qualname or code.co_name} ({code.co_filename}:{code.co_firstlineno})")
    print(f"{indent}   args={code.co_argcount}, kwonly={code.co_kwonlyargcount}, "
          f"locals={code.co_nlocals}, stacksize={code.co_stacksize}")

    if code.co_varnames:
        print(f"{indent}   varnames: {list(code.co_varnames)}")
    if code.co_names:
        print(f"{indent}   names:    {list(code.co_names)}")
    if code.co_freevars:
        print(f"{indent}   freevars: {list(code.co_freevars)}")

    # 상수 — 문자열/숫자/내장 함수만 보여주고 code object 는 별도로 재귀
    consts_repr = []
    nested = []
    for c in code.co_consts:
        if isinstance(c, types.CodeType):
            nested.append(c)
        elif isinstance(c, str):
            consts_repr.append(repr(c[:80]) + ('...' if len(c) > 80 else ''))
        else:
            consts_repr.append(repr(c))
    if consts_repr:
        print(f"{indent}   consts:")
        for c in consts_repr:
            print(f"{indent}     {c}")

    print()

    # 바이트코드
    if depth == 0:
        print(f"{indent}── 바이트코드 ──")
        dis.dis(code, depth=0, show_caches=False)
        print()

    # 중첩 함수/클래스 재귀
    for nc in nested:
        summarize_code(nc, depth + 1)


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    if not src.exists():
        print(f"[ERROR] not found: {src}")
        sys.exit(1)

    print(f"분석 대상: {src}")
    header, code = load_pyc(src)
    print(f"PYC magic : {header[:4].hex()}")
    print(f"file size : {src.stat().st_size:,} bytes")
    print(f"module    : {code.co_qualname or code.co_name}")
    print(f"firstline : {code.co_firstlineno}")
    print()
    summarize_code(code)


if __name__ == '__main__':
    main()
