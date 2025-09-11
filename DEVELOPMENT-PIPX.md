開発時のワークフロー（コード変更 → pipx 反映）

このリポジトリでのローカル開発サイクルの覚え書きです。

前提
- pipx がインストールされていること（`pipx --version` で確認）
- 作業はリポジトリのルートで行う（例: `/path/to/git-remote-dropbox`）
- rclone が使える環境（テストでは `alias` リモートを使うことが多い）

手順
1. コードを編集する
   - 変更を `src/` 下で行う。

2. （オプション）ローカルで動作確認するためにユニット／スクリプトを実行
   - 例: `python -m pytest -q` や `./tests/test-rclone-incremental.sh` など

3. pipx にインストール済みの旧バージョンをアンインストール
   - `pipx uninstall git-remote-dropbox`

4. 現在のカレントディレクトリ（このリポジトリ）を編集可能モードで pipx にインストール
   - `pipx install --editable .`
   - これにより `git-remote-rclone` などの console_scripts がグローバルに利用可能になります。

5. インストール確認
   - `which git-remote-rclone` でパスを確認
   - 必要なら `git-remote-rclone --help` や `git-remote-rclone` を呼んで簡単に動作確認

6. テスト実行
   - 単体スクリプト: `CI=true DEBUG=1 ./tests/test-rclone.sh` など
   - テストは `set -euo pipefail` を使っているので最初のエラーで止まります。

7. 問題が見つかったらコードを修正し、3〜6 を繰り返す

補足メモ
- rclone のリモート（例: `alias`）が正しく設定されているかを常に確認してください。
- console_scripts の引数が不足している場合にスクリプトがエラーを出すことがありますが、テストの進行上問題なければ無視して先へ進めてください。
- デバッグログを増やしたい場合は `DEBUG=1` 環境変数を渡してテストスクリプトを実行します。ログは rclone の stdout/stderr と helper の送受信を含みます。

以上。
