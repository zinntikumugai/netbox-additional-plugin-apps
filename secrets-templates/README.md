# secrets-templates

パブリックリポジトリに実値を置かないための Secret テンプレート集。
**このディレクトリは App-of-Apps `netbox-git`（`source.path: argocd/applications`）の
同期対象外**のため、ArgoCD に上書きされません。ユーザーが手動で apply します。

> ⚠️ **適用順序（重要）**: `netbox-app-secret` の 7 キー（`email_password` は空文字でも
> キー自体は必須）は、NetBox チャートの projected volume で **全て必須**です。ArgoCD で
> `netbox` アプリを sync する**前に**この Secret を apply しておかないと、キー欠落で Pod が
> `ContainerCreating` のまま起動しません。**順序は「Secret を apply → その後にアプリを sync/rollout」**。

## 適用手順

1. `.example` をコピーして拡張子を外す:
   ```bash
   cp netbox-app-secret.yaml.example netbox-app-secret.yaml
   cp netbox-postgresql-auth.yaml.example netbox-postgresql-auth.yaml
   ```
2. `<...>` プレースホルダを実値に置換。
   - `secret_key`: `python3 -c 'import secrets; print(secrets.token_urlsafe(50))'`
3. 適用（namespace は `netbox2`）:
   ```bash
   kubectl apply -f netbox-app-secret.yaml -n netbox2
   kubectl apply -f netbox-postgresql-auth.yaml -n netbox2
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

## ⚠️ 実値ファイルを絶対にコミットしないこと

`.example` を外したファイルは `.gitignore` で無視されます（リポジトリ直下参照）。
