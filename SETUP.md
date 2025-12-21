# セットアップガイド

## 1. Google Calendar APIの設定

### Google Cloud Consoleでの設定

1. [Google Cloud Console](https://console.cloud.google.com/)にアクセス
2. 新しいプロジェクトを作成（または既存のプロジェクトを選択）
3. 左側のメニューから「APIとサービス」→「ライブラリ」を選択
4. 「Google Calendar API」を検索して有効化
5. 「APIとサービス」→「認証情報」を選択
6. 「認証情報を作成」→「OAuth クライアント ID」を選択
7. アプリケーションの種類で「デスクトップアプリ」を選択
8. 名前を入力（例：MacCalendarSync）
9. 作成後、クライアントIDとクライアントシークレットをメモ

### OAuth同意画面の設定

1. 「OAuth同意画面」タブを選択
2. ユーザータイプで「外部」を選択（個人利用の場合）
3. アプリ名、ユーザーサポートメール、デベロッパー連絡先を入力
4. スコープの追加で「Google Calendar API」の「.../auth/calendar」を選択
5. テストユーザーに自分のGoogleアカウントを追加

## 2. 設定ファイルの作成

```bash
cd /Users/matsuohd/GithubLoacalSpace/MacCalenderToCloud
cp config.example.json config.json
```

`config.json`を編集して、Google Cloud Consoleで取得した情報を入力：

```json
{
  "google": {
    "clientID": "あなたのクライアントID.apps.googleusercontent.com",
    "clientSecret": "あなたのクライアントシークレット",
    "calendarID": "primary"
  },
  "sync": {
    "pastDays": 7,
    "futureDays": 30,
    "syncIntervalSeconds": 300
  }
}
```

## 3. ビルド

```bash
swift build -c release
```

ビルドされたバイナリは `.build/release/MacCalendarSync` に生成されます。

## 4. 初回実行とテスト

```bash
.build/release/MacCalendarSync
```

初回実行時、以下のダイアログが表示されます：
- カレンダーへのアクセス許可を求めるダイアログ → 「OK」を選択

許可しない場合は、以下の手順で手動で許可できます：
1. システム設定を開く
2. 「プライバシーとセキュリティ」を選択
3. 「カレンダー」を選択
4. MacCalendarSyncにチェックを入れる

## 5. バックグラウンド実行の設定

### LaunchAgentとして登録

1. plistファイルを編集：

```bash
nano com.user.maccalendarsync.plist
```

ProgramArgumentsのパスを実際のパスに変更：
```xml
<string>/Users/あなたのユーザー名/GithubLoacalSpace/MacCalenderToCloud/.build/release/MacCalendarSync</string>
```

2. LaunchAgentsディレクトリにコピー：

```bash
cp com.user.maccalendarsync.plist ~/Library/LaunchAgents/
```

3. 権限を設定：

```bash
chmod 644 ~/Library/LaunchAgents/com.user.maccalendarsync.plist
```

4. LaunchAgentを読み込み：

```bash
launchctl load ~/Library/LaunchAgents/com.user.maccalendarsync.plist
```

5. 起動を確認：

```bash
launchctl list | grep maccalendarsync
```

### ログの確認

```bash
# 標準出力ログ
tail -f /tmp/maccalendarsync.log

# エラーログ
tail -f /tmp/maccalendarsync.error.log
```

### LaunchAgentの停止・削除

```bash
# 停止
launchctl unload ~/Library/LaunchAgents/com.user.maccalendarsync.plist

# 削除
rm ~/Library/LaunchAgents/com.user.maccalendarsync.plist
```

## トラブルシューティング

### カレンダーアクセスが拒否される

システム設定 > プライバシーとセキュリティ > カレンダー で MacCalendarSync を許可してください。

### ローカルカレンダーが見つからない

Mac の「カレンダー」アプリを開いて、「マイ Mac」配下にカレンダーが存在することを確認してください。
iCloudカレンダーやGoogleカレンダーは同期対象外です。

### Google Calendar APIのエラー

- クライアントIDとシークレットが正しいか確認
- Google Calendar APIが有効化されているか確認
- OAuth同意画面でテストユーザーに自分のアカウントが追加されているか確認

## 現在の制限事項

現在のバージョンでは、以下の機能がまだ実装されていません：

1. **OAuth 2.0認証フロー**: Google Calendar APIの認証は骨組みのみで、実際の認証フローは未実装です
2. **重複チェック**: 同じイベントを複数回同期してしまう可能性があります
3. **双方向同期**: MacからGoogleへの一方向のみです
4. **イベントの更新・削除**: 新規作成のみで、更新や削除は未対応です

これらの機能を実装するには、追加の開発が必要です。
