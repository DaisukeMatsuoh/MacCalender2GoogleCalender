# MacCalendarSync

MacのローカルカレンダーをGoogleカレンダーに自動同期する軽量なバックグラウンドアプリ

Swift製の軽量なデーモンプロセスとして動作し、Macのカレンダーアプリのローカルカレンダー（「マイMac」）に追加された予定を自動的にGoogleカレンダーに同期します。

## 特徴

- **軽量**: Swiftネイティブで、依存関係なし
- **自動監視**: EventKitを使用してカレンダーの変更を自動検知
- **バックグラウンド動作**: LaunchAgentとして常駐可能
- **設定可能**: JSONファイルで同期範囲や対象カレンダーをカスタマイズ
- **ローカルカレンダー専用**: iCloudやGoogleカレンダーは同期対象外（重複を防ぐ）

## 必要な環境

- macOS 13.0以降
- Swift 5.9以降
- Xcode Command Line Tools
- Google Calendar API アクセス

## クイックスタート

詳細なセットアップ手順は [SETUP.md](SETUP.md) を参照してください。

### 1. ビルド

```bash
swift build -c release
```

### 2. 設定ファイルの作成

```bash
cp config.example.json config.json
# config.jsonを編集してGoogle APIの認証情報を設定
```

### 3. 実行

```bash
.build/release/MacCalendarSync
```

## プロジェクト構造

```
MacCalenderToCloud/
├── Sources/
│   ├── main.swift                  # エントリーポイント
│   ├── CalendarSyncApp.swift       # メインアプリケーションロジック
│   ├── GoogleCalendarAPI.swift     # Google Calendar API統合
│   ├── EventConverter.swift        # EKEvent → Google Calendar形式の変換
│   └── Config.swift                # 設定ファイルの読み込み
├── Package.swift                   # Swift Package Manager設定
├── config.example.json             # 設定ファイルのサンプル
├── com.user.maccalendarsync.plist  # LaunchAgent設定のサンプル
├── README.md                       # このファイル
└── SETUP.md                        # 詳細なセットアップガイド
```

## 仕組み

1. **カレンダー監視**: EventKitの`EKEventStoreChanged`通知を使用
2. **ローカルカレンダーフィルタ**: `sourceType == .local`でフィルタリング
3. **イベント変換**: EKEventをGoogle Calendar API形式に変換
4. **Google同期**: REST API経由でイベントを作成

## 実装状況

- [x] EventKitでローカルカレンダーの読み取り
- [x] カレンダー変更の監視
- [x] イベントデータの変換
- [x] 設定ファイルのサポート
- [x] 基本的なGoogle Calendar API統合の骨組み
- [ ] OAuth 2.0認証フロー（要実装）
- [ ] 実際のGoogleカレンダーへのイベント作成（認証が必要）
- [ ] 重複チェックの改善
- [ ] イベントの更新・削除のサポート
- [ ] エラーハンドリングとリトライロジック

## 今後の拡張案

- OAuth 2.0認証フローの完全実装
- イベントの更新・削除対応
- 双方向同期のサポート
- 複数カレンダーの個別設定
- 同期履歴の永続化
- GUI設定アプリの追加

## トラブルシューティング

詳細は [SETUP.md](SETUP.md) の「トラブルシューティング」セクションを参照してください。

## ライセンス

MIT
