#!/usr/bin/env python3
"""Convert an LCOV tracefile (from `llvm-cov export -format=lcov`) into a
minimal Cobertura coverage.xml that CTest's ctest_coverage() can parse.

CTest has no reader for LLVM source-based coverage, but it does read
Cobertura XML from ${COBERTURADIR:-${CTEST_BINARY_DIRECTORY}}/coverage.xml and
submits it to CDash as a regular Coverage part.

Usage: llvm_cov_to_cobertura.py <in.lcov> <out.xml> <source_dir>
"""
import os
import sys
import time
from xml.sax.saxutils import quoteattr

INT_MAX = 2**31 - 1


def parse_lcov(path):
    files = {}
    cur = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("SF:"):
                cur = files.setdefault(line[3:], {})
            elif line.startswith("DA:") and cur is not None:
                parts = line[3:].split(",")
                num, hits = int(parts[0]), int(parts[1])
                # llvm-cov can report wrapped-around 64-bit counts (racy,
                # non-atomic counters in multi-threaded tests). CTest reads
                # hits with atoi(); a value that does not fit an int turns
                # negative and crashes its Cobertura parser, so clamp.
                hits = min(hits, INT_MAX)
                # Several regions may map to one line; keep the max count.
                cur[num] = max(hits, cur.get(num, 0))
            elif line == "end_of_record":
                cur = None
    return files


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    lcov, out, src = sys.argv[1], sys.argv[2], os.path.realpath(sys.argv[3])
    # Only keep files from the source tree (no toolchain/system headers).
    files = {k: v for k, v in parse_lcov(lcov).items()
             if os.path.realpath(k).startswith(src + os.sep)}
    # CTest's Cobertura reader indexes lines without a bounds check,
    # so never report a line number past the end of the file.
    for fname in list(files):
        try:
            with open(fname, "rb") as sf:
                nlines = sum(1 for _ in sf)
        except OSError:
            del files[fname]
            continue
        files[fname] = {k: v for k, v in files[fname].items() if 0 < k <= nlines}
    total = sum(len(v) for v in files.values())
    covered = sum(1 for v in files.values() for h in v.values() if h > 0)
    rate = (covered / total) if total else 0.0
    with open(out, "w", encoding="utf-8") as o:
        o.write('<?xml version="1.0" ?>\n')
        o.write('<coverage line-rate="%.4f" branch-rate="0" lines-covered="%d" '
                'lines-valid="%d" version="llvm-cov" timestamp="%d">\n'
                % (rate, covered, total, int(time.time())))
        o.write("  <sources><source>%s</source></sources>\n" % src)
        o.write('  <packages><package name="bitcoin"><classes>\n')
        for fname in sorted(files):
            lines = files[fname]
            real = os.path.realpath(fname)
            rel = os.path.relpath(real, src) if real.startswith(src + os.sep) else real
            n = len(lines)
            c = sum(1 for h in lines.values() if h > 0)
            o.write('    <class name=%s filename=%s line-rate="%.4f"><lines>\n'
                    % (quoteattr(rel), quoteattr(rel), (c / n) if n else 0.0))
            for num in sorted(lines):
                o.write('      <line number="%d" hits="%d"/>\n' % (num, lines[num]))
            o.write("    </lines></class>\n")
        o.write("  </classes></package></packages>\n</coverage>\n")
    print("cobertura: %d files, %d/%d lines covered (%.2f%%)"
          % (len(files), covered, total, 100.0 * rate))


if __name__ == "__main__":
    main()