# Copipe

- ビルドとインストールは `./build.sh install`。動いている Copipe を終了してから `/Applications/Copipe.app` を起動し直す
- 署名はキーチェーンの「Copipe Local Signing」証明書で行う（なければ `build.sh` が作る）。仮の署名（adhoc）で入れ替えると、アクセシビリティの許可が外れて自動で貼り付けられなくなる
- 「貼り付けられない」「許可が外れた」と言われたら、まず README の「アクセシビリティ」のところの手順で、署名と許可を確かめる
- 本物の履歴（`~/Library/Application Support/Copipe/`）の中身は表示しない。動作確認は架空の履歴か、件数・時間だけを見る
