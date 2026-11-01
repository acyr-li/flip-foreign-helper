#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RapidOCR 辅助程序：读取图片路径（可多个），输出 JSON 文本行。"""
import sys
import json
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

_engine = None

def get_engine():
    global _engine
    if _engine is None:
        from rapidocr_onnxruntime import RapidOCR
        _engine = RapidOCR()
    return _engine


def ocr_file(path):
    eng = get_engine()
    try:
        res, _ = eng(path)
    except Exception as e:
        return {"error": str(e), "lines": []}
    lines = []
    if res:
        for item in res:
            box, text, score = item[0], item[1], item[2]
            xs = [p[0] for p in box]
            ys = [p[1] for p in box]
            x1, x2 = int(min(xs)), int(max(xs))
            y1, y2 = int(min(ys)), int(max(ys))
            lines.append({
                "text": text,
                "x": x1, "y": y1, "w": x2 - x1, "h": y2 - y1,
                "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2,
                "score": round(float(score), 3),
            })
    lines.sort(key=lambda d: d["y"])
    return {"lines": lines}


def serve():
    get_engine()
    sys.stdout.write("READY\n")
    sys.stdout.flush()
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        path = line.strip()
        if not path:
            continue
        if path.upper() == "QUIT":
            break
        try:
            sys.stdout.write(json.dumps(ocr_file(path), ensure_ascii=False) + "\n")
        except Exception as e:
            sys.stdout.write(json.dumps({"error": str(e), "lines": []}, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def main():
    args = sys.argv[1:]
    if args and args[0] == "--server":
        serve()
        return
    if not args:
        print(json.dumps({"error": "no image path"}, ensure_ascii=False))
        return
    if len(args) == 1:
        print(json.dumps(ocr_file(args[0]), ensure_ascii=False))
        return
    out = {}
    for p in args:
        out[p] = ocr_file(p)
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
