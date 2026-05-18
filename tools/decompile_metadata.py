#!/usr/bin/env python3
"""
decompile_metadata.py — .pyc 의 code object 들을 재귀로 순회하며
이름·상수·문서문자열을 추출. 완전한 디컴파일은 아니지만 코드의 *구조* 와
*의도* 를 거의 그대로 복원해 보여준다.

사용법:
    python tools/decompile_metadata.py [pyc경로]
"""
import sys, marshal, types
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent
DEFAULT = ROOT / "bin" / "agent-app_extracted" / "linux_pbl_v2.pyc"


def load_pyc(path):
    with open(path, 'rb') as f:
        f.read(16)
        return marshal.load(f)


def walk(code, indent=0):
    pad = "  " * indent
    kind = "class" if "<locals>" not in (code.co_qualname or "") and \
                       any(isinstance(c, types.CodeType) and
                           getattr(c, 'co_name', '') == '__init__'
                           for c in code.co_consts) else "function/code"

    # 모듈/함수/클래스 구분 시도
    qn = code.co_qualname or code.co_name
    if qn == "<module>":
        label = "MODULE"
    elif code.co_name == "__init__":
        label = "method __init__"
    elif "." in qn and not qn.startswith("<"):
        label = "method"
    else:
        label = "function" if code.co_argcount > 0 or code.co_kwonlyargcount > 0 else "code"

    print(f"\n{pad}┏━ {label}: {qn}  (line {code.co_firstlineno})")

    # 시그니처
    args = list(code.co_varnames[:code.co_argcount])
    kwargs = list(code.co_varnames[code.co_argcount:
                                    code.co_argcount + code.co_kwonlyargcount])
    sig = []
    if args: sig.append(", ".join(args))
    if kwargs: sig.append("*, " + ", ".join(kwargs))
    print(f"{pad}┃  sig: ({', '.join(sig)})  locals={code.co_nlocals}")

    # 외부 참조 — 어떤 모듈/이름을 쓰는지
    if code.co_names:
        names_grouped = [code.co_names[i:i+8] for i in range(0, len(code.co_names), 8)]
        print(f"{pad}┃  names (호출/속성 접근):")
        for grp in names_grouped:
            print(f"{pad}┃    {grp}")

    # 자유변수 / 셀변수 — 클로저 단서
    if code.co_freevars:
        print(f"{pad}┃  freevars: {list(code.co_freevars)}")
    if code.co_cellvars:
        print(f"{pad}┃  cellvars: {list(code.co_cellvars)}")

    # 상수 — 문자열·숫자만 (중첩 code 는 별도 재귀)
    str_consts = []
    num_consts = []
    other_consts = []
    nested = []
    for c in code.co_consts:
        if isinstance(c, types.CodeType):
            nested.append(c)
        elif isinstance(c, str):
            if c:  # 빈 문자열 제외
                str_consts.append(c)
        elif isinstance(c, (int, float)):
            num_consts.append(c)
        elif c is None:
            pass
        else:
            other_consts.append(repr(c))

    if str_consts:
        print(f"{pad}┃  string constants:")
        for s in str_consts[:30]:
            display = s if len(s) < 100 else s[:100] + "..."
            display = display.replace('\n', '\\n')
            print(f"{pad}┃    {display!r}")
        if len(str_consts) > 30:
            print(f"{pad}┃    ... ({len(str_consts) - 30}개 더)")

    if num_consts:
        print(f"{pad}┃  number constants: {num_consts}")
    if other_consts:
        print(f"{pad}┃  other constants:  {other_consts}")

    # 첫 번째 상수가 보통 docstring
    if code.co_consts and isinstance(code.co_consts[0], str) and code.co_consts[0]:
        print(f"{pad}┃  docstring: {code.co_consts[0]!r}")

    print(f"{pad}┗━")

    # 중첩 재귀
    for nc in nested:
        walk(nc, indent + 1)


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    if not src.exists():
        sys.exit(f"[ERROR] not found: {src}")
    print(f"# 메타데이터 디컴파일: {src}\n")
    code = load_pyc(src)
    walk(code)


if __name__ == '__main__':
    main()
