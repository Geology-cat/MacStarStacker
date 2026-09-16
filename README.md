# MacStarStacker

星景写真に特化したMacネイティブの画像スタッキング・コンポジットアプリケーションです。
Windows用ソフトウェア「Sequator」のように、星の日周運動を追尾しながら地上の風景を固定して合成する「空と地上の分離」スタッキングを実現します。

macOS 14 (Sonoma) 以降に対応しています（macOS 15.7でビルド・検証）。
現在同梱しているDMGはx86_64版です。Intel Macではネイティブ、Apple Silicon MacではRosetta 2経由で動作します。

---

## 🌟 主な機能

1. **各社RAW画像・多彩なフォーマットに対応**:
   - Sony (`.arw`), Canon (`.cr2`, `.cr3`), Nikon (`.nef`), Fujifilm (`.raf`), OM System/Olympus (`.orf`), Panasonic (`.rw2`), Pentax (`.pef`), Adobe (`.dng`), TIFF, FITS, JPEG, PNG
2. **レンズプロファイルの自動抽出 & DNG埋め込み**:
   - 基準RAWに紐づくレンズ型番（`LensModel`）、メーカー（`LensMake`）、焦点距離、F値、カラーマトリクスを解析。
   - スタック後の16-bit リニアDNG (Linear RAW) 出力時に、Adobe Camera Raw向けXMPメタデータ（`crs:LensProfileEnable="1"`）を埋め込み。対応プロファイルが現像ソフト側にある場合のレンズ補正自動適用を補助します。
3. **比較明合成における飛行機・人工衛星の光跡自動除去 & 流星保護レビュー**:
   - 比較明スタック（スタートレイル）時に、空を横切る飛行機（点滅ストロボ・航跡灯）や人工衛星（直線）を、2K解析・時間中央値/MAD・画像別ノイズ床・直線支持率に加え、線方向の輝度積算と短線分検出で高感度に検出して除去。星像や静止した地形境界は時間方向の連続性検証で除外します。
   - **流星（流れ星）の救出レビュー機能**: 画面内に収まるコンパクトな一覧で候補を確認し、流星など残したい光跡を保護可能。「光跡ハイライトを表示」をON/OFFして元画像と直接比較でき、ウィンドウ端をドラッグしてプレビューを拡大できます。
4. **空と地上の分離スタッキング**:
   - 機能をONにしたときだけ有効になるブラシツールで空と地上を塗り分け、星空は星の動きに合わせてスタックし、地上風景は固定して合成。
   - 余白・ズーム・パンを含む表示座標と画像座標を一致させ、境界ぼかしを0〜100 pxで調整可能（0 pxで無効）。
5. **高精度アライメント (OpenCV)**:
   - AKAZE / ORB 特徴点検出と MAGSAC / RANSAC ホモグラフィ変換により、周辺部の歪みまで高精度に位置合わせ。
6. **キャリブレーションフレーム減算**:
   - ダークフレーム、フラットフレーム、バイアスフレームのマスター生成と自動ノイズ減算。
7. **タイムラプス動画エクスポート**:
   - アライメント・フリッカー除去・オートストレッチ付きの高品質タイムラプス動画（H.264 / HEVC）書き出し。
8. **macOSネイティブUI**:
   - AppKit / Cocoa UI と GCD（Grand Central Dispatch）を使用。

---

## 📁 ディレクトリ構成

```text
MacStarStacker/
├── dist/                              # 配布用バイナリ成果物 (.app, .dmg)
│   ├── MacStarStacker.app
│   └── MacStarStacker.dmg
├── docs/                              # ドキュメント・仕様書・マニュアル
│   ├── specification.md               # アプリケーション詳細仕様書
│   ├── installation_guide.md          # インストール＆起動ガイド (Markdown)
│   ├── installation_guide.html        # インストール＆起動ガイド (HTML)
│   ├── user_manual.html               # ユーザーマニュアル (HTML)
│   ├── インストールと初回起動ガイド.pdf  # PDF形式ガイド
│   └── assets/                        # アイコン・画像素材
├── scripts/                           # 補助スクリプト
│   └── fix_dylib_bundling.py
├── MacStarStacker.swiftpm/            # Swift/C++ ソースコード & ビルド設定
│   ├── Package.swift
│   ├── build_app.sh                   # dist/ にビルド・パッケージングするスクリプト
│   └── Sources/
│       ├── MacSequator/               # AppKit UI, コントローラ, 画像処理エンジン
│       ├── OpenCVWrapper/             # OpenCV C++ アライメントラッパー
│       └── LibRawBridge/              # LibRaw C ブリッジ（RAWのセンサーデータ読み込み・デモザイク）
├── .gitignore
└── README.md
```

---

## 🔨 ビルド方法

### 前提条件
- macOS 14 以降
- 現在の配布DMG: x86_64（Apple SiliconではRosetta 2が必要）
- Xcode Command Line Tools (`xcode-select --install`)
- OpenCV (Homebrew): `brew install opencv`
- LibRaw (Homebrew): `brew install libraw`（RAWをベイヤー配列・カメラ色空間のまま合成するために使用）
- ExifTool (推奨): `brew install exiftool`

### アプリケーションおよびDMGのビルド
```bash
cd MacStarStacker.swiftpm
bash build_app.sh
```
ビルドが完了すると、`dist/` 配下に `MacStarStacker.app` および `MacStarStacker.dmg` が自動生成されます。

---

## 📄 ライセンス
Copyright © 2026 MacStarStacker. All rights reserved.
