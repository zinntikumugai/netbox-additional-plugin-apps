# secrets-templates

パブリックリポジトリに実値を置かないための Secret テンプレート集。
**このディレクトリは App-of-Apps `netbox-git`（`source.path: argocd/applications`）の
同期対象外**のため、ArgoCD に上書きされません。ユーザーが手動で apply します。

> ⚠️ **適用順序（重要）**: `netbox-app-secret` の 7 キー（`email_password` は空文字でも
> キー自体は必須）は、NetBox チャートの projected volume で **全て必須**です。ArgoCD で
> `netbox` アプリを sync する**前に**この Secret を apply しておかないと、キー欠落で Pod が
> `ContainerCreating` のまま起動しません。**順序は「Secret を apply → その後にアプリを sync/rollout」**。
> `netbox-valkey-auth` も同様で、未作成のまま sync すると valkey Pod 自体が起動できません。

## 適用手順

1. `.example` をコピーして拡張子を外す:
   ```bash
   cp netbox-app-secret.yaml.example netbox-app-secret.yaml
   cp netbox-postgresql-auth.yaml.example netbox-postgresql-auth.yaml
   cp netbox-valkey-auth.yaml.example netbox-valkey-auth.yaml
   ```
2. `<...>` プレースホルダを実値に置換。ランダム値は `openssl` で生成する:
   ```bash
   # secret_key（token_urlsafe(50) 相当・67 文字）
   openssl rand -base64 50 | tr -d '\n' | tr '+/' '-_' | tr -d '='
   # valkey-password / DB パスワード（token_urlsafe(32) 相当・43 文字）
   openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_' | tr -d '='
   ```
   出力は base64url なので `$` やクォートを含まず、YAML にも valkey の `requirepass` にも
   そのまま入れて安全。
   > このリポジトリの devcontainer には `python3-minimal` しか入っておらず標準ライブラリが
   > 欠けているため、`python3 -c 'import secrets; ...'` は `ModuleNotFoundError` になる。
   > Python を使いたい場合は先に `sudo apt-get install -y libpython3.13-stdlib` が必要。
3. 適用（namespace は `netbox2`）:
   ```bash
   kubectl apply -f netbox-app-secret.yaml -n netbox2
   kubectl apply -f netbox-postgresql-auth.yaml -n netbox2
   kubectl apply -f netbox-valkey-auth.yaml -n netbox2
   ```
4. NetBox を再起動:
   ```bash
   kubectl rollout restart deployment -n netbox2 -l app.kubernetes.io/name=netbox
   ```

## Secret とキー

| Secret | キー | 用途 |
|---|---|---|
| `netbox-app-secret` | `secret_key` | セッション暗号化（50文字以上） |
| | `ldap_bind_password` | LDAP bind パスワード |
| | `email_password` | メール（空可） |
| | `username` / `email` | superuser 名 / メール |
| | `password` / `api_token` | superuser パスワード / API トークン |
| `netbox-postgresql-auth` | `password` | netbox DB ユーザー |
| | `postgres-password` | postgres 管理ユーザー |
| `netbox-valkey-auth` | `valkey-password` | Valkey（tasks / caching）認証 |

## パスワードローテーション時の注意

`netbox-postgresql-auth` / `netbox-valkey-auth` はいずれも **Secret を書き換えるだけでは
サーバ側のパスワードは変わりません**。順序を誤ると probe と実際のパスワードが食い違い、
Pod が不健全になります。

- **PostgreSQL**: Bitnami チャートは Secret の値を initdb 時にしか使いません。
  1. `kubectl exec -n netbox2 netbox-postgresql-0 -- psql -U postgres` で
     `ALTER USER netbox WITH PASSWORD '<新>';` / `ALTER USER postgres WITH PASSWORD '<新admin>';`
  2. `kubectl apply -f netbox-postgresql-auth.yaml -n netbox2`
  3. `kubectl rollout restart statefulset/netbox-postgresql deployment/netbox deployment/netbox-worker -n netbox2`
- **Valkey**: `requirepass` はサーバ起動時に Secret から読まれます。Secret を apply したあと
  valkey → NetBox の順に再起動すれば整合します（キャッシュ / RQ キュー用途のためデータ影響なし）。

> ⚠️ 旧 `argocd/applications/netbox-secrets.yaml` に平文コミットされていた PostgreSQL の
> パスワードは git 履歴に残っており、**現在もそのまま使われています**。公開リポジトリのため
> 履歴からは消せないので、上記手順でのローテーションが実効的な是正策です。

## ⚠️ 実値ファイルを絶対にコミットしないこと

`.example` を外したファイルは `.gitignore` で無視されます（リポジトリ直下参照）。
