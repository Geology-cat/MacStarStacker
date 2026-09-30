#!/bin/bash
# 使い方ガイドを LuaLaTeX で組み、docs/MacStarStacker使い方ガイド.pdf に書き出す。
# 必要なもの: TeX Live（lualatex・latexmk・jlreq・luatexja。フォントは TeX Live 付属の原ノ味フォント）
# スクリーンショット（figures/）は DocumentationScreenshotTests で撮る（README.md の「使い方ガイド」を参照）
set -euo pipefail
cd "$(dirname "$0")"
latexmk -lualatex -interaction=nonstopmode -halt-on-error manual.tex
cp manual.pdf "../MacStarStacker使い方ガイド.pdf"
echo "書き出し: docs/MacStarStacker使い方ガイド.pdf ($(du -h manual.pdf | cut -f1))"
