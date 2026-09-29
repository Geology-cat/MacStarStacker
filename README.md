# MacStarStacker

星景写真に特化したMacネイティブの画像スタッキング・コンポジットアプリケーションです。
Windows用ソフトウェア「Sequator」のように、星の日周運動を追尾しながら地上の風景を固定して合成する「空と地上の分離」スタッキングを実現します。

**このブランチ（`macos10.13`）は macOS 10.13 (High Sierra) 以降に対応した版です。**
Intel Mac は macOS 10.13 以降、Apple Silicon Mac は macOS 11 以降でネイティブに動作するUniversal版です
（macOS 15.7でビルド・検証。10.13実機での検証は別途必要）。

> 最新OS向けに機能を拡充する版（macOS 14以降）は `main` ブランチで開発しています。

### macOS 14以降向け（main）との違い
- **RAWの読み込み**: 常にLibRawで現像します。古いmacOSのRAWエンジンは新しい機種やCR3を読めず、
  小さな埋め込みプレビューを返すことがあるためです。表示の色味はmacOS標準の現像と少し異なります。
  そのぶんプレビュー・光跡検出・タイムラプス書き出しでのRAWの読み込みはmain版より時間がかかります
  （プレビューはバックグラウンドで読み込み、読み込み中はファイル名に「読み込み中…」と表示）。
- **撮影情報**: macOSが読めないRAW（10.13でのCR3など）は、LibRawで機種・レンズ・撮影条件を補完します。
- **H.265/HEVC書き出し**: HEVCのハードウェアエンコーダーを持つMacでのみ選択できます。
- **GPU合成**: Metal非対応のMac（おおむね2011年以前）ではCPUで合成します。
- **Swiftランタイム**: macOS 10.14.4 より前のOS向けに、アプリへ同梱します（ビルドにはXcode 16.xが必要）。
- 新しいAPI（macOS 11以降のUTType、macOS 12以降のCIRAWFilterなど）は `#available` で分岐し、古いOSでは代替処理を使います。

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
│   └── build_deps.sh                  # OpenCV・LibRawをUniversal静的ライブラリとしてビルド
├── MacStarStacker.swiftpm/            # Swift/C++ ソースコード & ビルド設定
│   ├── Package.swift
│   ├── build_app.sh                   # dist/ にビルド・パッケージングするスクリプト
│   ├── Vendor/                        # build_deps.sh の出力先（Git管理外）
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
- macOS 14 以降（ビルド環境。動作対象は macOS 10.13 以降）
- Xcode 16.x（`xcode-select` でXcode本体を選択しておく。10.13向けのSwiftランタイム同梱に必要）
- CMake・Ninja（依存ライブラリのビルド用）: `brew install cmake ninja`
- ExifTool (推奨): `brew install exiftool`

OpenCV 4.13.0 と LibRaw 0.22.2 は、`scripts/build_deps.sh` が公式GitHubからソースを取得し、
Universal（x86_64 + arm64）の静的ライブラリとして `MacStarStacker.swiftpm/Vendor/` にビルドします
（初回のみ数分〜十数分。以降はビルド済みのものを再利用）。Homebrew版のOpenCV・LibRawは使いません。

### 開発時のビルド・テスト
```bash
scripts/build_deps.sh 10.13
swift test --package-path MacStarStacker.swiftpm
```

### アプリケーションおよびDMGのビルド
```bash
cd MacStarStacker.swiftpm
bash build_app.sh
```
ビルドが完了すると、`dist/` 配下に `MacStarStacker.app` および `MacStarStacker.dmg` が自動生成されます。

---

## 📄 ライセンス
Copyright © 2026 MacStarStacker. All rights reserved.
