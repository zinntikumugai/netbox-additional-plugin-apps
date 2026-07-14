# existingSecret 方式への移行 + Traefik TLS 化 設計書

- 日付: 2026-07-14
- ブランチ: `feat/existing-secret-and-tls`
- 対象リポジトリ: netbox-additional-plugin-apps（**パブリック**）

## 背景と目的

このリポジトリはパブリックのため、パスワード等の秘密情報を保持したくない。
現状は以下の問題がある。

1. **Helm 自動生成 Secret の値churn**: NetBox チャートは `netbox-config`（`secret_key` /
   `ldap_bind_password` / `email_password`）と `netbox-superuser`（`password` / `api_token`）を
   自動生成する。値は Helm テンプレートのレンダリング時に決まり、`secretKey` は `randAscii 60`、
   superuser 認証情報も乱数。ArgoCD は `helm template`（`lookup` 不可）でレンダリングし、`netbox`
   Application は `syncPolicy.automated.selfHeal: true` のため、**sync のたびに値が変わり得る**。
   → `kubectl edit secret netbox-config` で LDAP パスワードを手動投入しても selfHeal で上書き（消滅）する。
2. **秘密情報の平文コミット**: `argocd/applications/netbox-secrets.yaml` に PostgreSQL パスワードが
   平文（Base64相当文字列）でコミットされており、パブリックリポジトリから閲覧可能。

本設計では、秘密情報をチャート外の **existingSecret** に切り出し、テンプレート（プレースホルダ）
のみをリポジトリに残す。実値の投入はユーザーが手動 `kubectl apply` で行う。
併せて NetBox の Ingress を Traefik + TLS 化する。

## 前提（調査で確定した事実）

### App-of-Apps 構成
- `netbox-app.yaml` = Application `netbox-git`。`source.path: argocd/applications`、`targetRevision: HEAD`。
  `syncPolicy` に `automated` ブロックが**無い**（= 手動 sync、自動 prune なし）。
- `netbox-git` は `argocd/applications/` 配下の**全 `.yaml`** を同期する（生 Secret も含む）。
  → **このディレクトリに Secret テンプレートを置くと、プレースホルダ値で本物の Secret を上書きする。**
  → テンプレートは同期対象外の場所に置く必要がある。
- 子 Application `netbox`（`argocd/applications/netbox.yaml`, Helm チャート）は
  `syncPolicy.automated.selfHeal: true` / `prune: true`。

### チャートの existingSecret 仕様（netbox chart 7.1.10）
- `templates/secret.yaml:1` は `{{- if not .Values.existingSecret }}` でガード。
  トップレベル `existingSecret` を設定すると `netbox-config` Secret を**生成しなくなる**。
- `templates/deployment.yaml` の projected volume / env で、以下のキーを参照する（**キー欠落だと Pod 起動不可**）。

| 参照元 values | 参照する Secret 名 | 必要キー |
|---|---|---|
| `existingSecret`（config） | 設定した名前そのまま | `secret_key`, `ldap_bind_password`（LDAP有効時）, `email_password` |
| `superuser.existingSecret` | 設定した名前そのまま | `username`, `email`, `password`, `api_token` |

- 上記2つのキー集合に重複は無いため、**1つの Secret に全キーをまとめ、両方の値に同じ名前を指定できる**。

### クラスタの TLS 発行パターン（既存 home-assistant を参照）
- cert-manager 稼働、`ClusterIssuer` = **`cf-cluster-issuer`**（Ready）。
- 既存サービスは **k8s `Ingress` + cert-manager ingress-shim** で TLS を張る。
  - annotation `cert-manager.io/cluster-issuer: cf-cluster-issuer`（Certificate と Secret を自動生成）
  - annotation `traefik.ingress.kubernetes.io/router.entrypoints: web,websecure`
  - `spec.tls[].secretName`（cert-manager が自動作成）
- → TLS 用の秘密情報はリポジトリに置かず、cert-manager がクラスタ内で生成する。

## 設計

### パート A: config / superuser を単一 existingSecret 化

**Secret 名**: `netbox-app-secret`（`existingSecret` と `superuser.existingSecret` の両方に指定）

**必要キー（7個）**:

| キー | 用途 | 備考 |
|---|---|---|
| `secret_key` | セッション暗号化トークン | 50文字以上の乱数 |
| `ldap_bind_password` | LDAP bind パスワード | |
| `email_password` | メール送信パスワード | 未使用なら空文字 `""` |
| `username` | superuser 名 | 例: `admin` |
| `email` | superuser メール | |
| `password` | superuser パスワード | |
| `api_token` | superuser API トークン | UUID 形式など |

**`argocd/applications/netbox.yaml`（Helm values）の変更**:
- 最上位に `existingSecret: "netbox-app-secret"` を追加。
- `superuser.existingSecret: "netbox-app-secret"` を追加（`superuser` ブロックを新設）。
- `remoteAuth.ldap.bindPassword` は設定しない（Secret から読むため）。
- 既存の誤解を招くコメント（`kubectl edit secret netbox-config` で更新、の旨）を、
  「`netbox-app-secret` の `ldap_bind_password` を更新し、DaemonSet/Deployment を再起動」に修正。

効果: Helm は `netbox-config` / `netbox-superuser` を生成しなくなり、selfHeal による値churn が解消。

### パート B: 既存 leak 対処（`netbox-secrets.yaml`）

`argocd/applications/netbox-secrets.yaml` を分割する。

- `netbox-postgresql-auth`（PostgreSQL パスワード、平文コミット済み）
  → テンプレート化して**同期対象外へ移動**（下記 `secrets-templates/`）。
- `netbox-env-config`（`DB_CONN_MAX_AGE`、秘密情報ではない設定値）
  → `argocd/applications/netbox-env-config.yaml` として**通常同期を維持**。
- 移動後 `argocd/applications/netbox-secrets.yaml` は削除する。
  `netbox-git` は自動 prune 無しのため、ライブの Secret は即座には消えない（手動 apply 済み値が残る）。

⚠️ **git 履歴に旧 PostgreSQL パスワードが残る**。真の是正は DB パスワードのローテーション。
履歴書き換え（filter-repo 等）は破壊的なため本設計の対象外とし、README に注意を記載する。

### パート C: テンプレート配置（同期対象外の新ディレクトリ）

```
secrets-templates/
├── README.md                             # 値の投入と kubectl apply 手順
├── netbox-app-secret.yaml.example        # パート A の7キー（プレースホルダ）
└── netbox-postgresql-auth.yaml.example   # PostgreSQL パスワード（プレースホルダ）
```

- `argocd/applications/` の**外**なので `netbox-git` に同期されない（上書きされない）。
- `.example` 拡張子で「そのまま apply しない」ことを明示。
- ユーザー手順（README）:
  1. `.example` をコピーしてプレースホルダを実値に置換。
  2. `kubectl apply -f <filled>.yaml`（namespace `netbox2`）。
  3. Secret 変更後は NetBox Deployment / worker を `kubectl rollout restart`。

### パート D: Traefik TLS 化（`argocd/applications/netbox-ingress.yaml`）

既存 home-assistant と同じ cert-manager ingress-shim パターン + **HTTPS 強制リダイレクト**。

追加/変更する manifest（同一ファイル内、いずれも namespace `netbox2`）:

1. **Middleware `netbox-https-redirect`**（`traefik.io/v1alpha1`）
   - `redirectScheme: { scheme: https, permanent: true }`
   - Traefik はリダイレクト後 URL が同一（既に https）の場合はリダイレクトしないため、
     web/websecure 両エントリポイントに適用してもループしない。

2. **`Ingress netbox-ingress`** の変更
   - annotations 追加:
     - `cert-manager.io/cluster-issuer: cf-cluster-issuer`
     - `traefik.ingress.kubernetes.io/router.entrypoints: web,websecure`
     - `traefik.ingress.kubernetes.io/router.middlewares: netbox2-netbox-https-redirect@kubernetescrd`
     - 既存の `external-dns.alpha.kubernetes.io/*` は維持
   - `spec.tls` を有効化:
     ```yaml
     tls:
     - hosts: [netbox2.service.z1n.in]
       secretName: netbox2-tls   # cert-manager が自動生成
     ```
   - `spec.rules` は既存のまま（host `netbox2.service.z1n.in` → service `netbox:80`）。

- 秘密情報を含まないため、このファイルは `argocd/applications/` に残し GitOps 同期を継続。

### パート E: ドキュメント更新（`CLAUDE.md`）

- LDAP セクションの記述を existingSecret 方式に合わせて更新
  （`superuser.existingSecret` / トップレベル `existingSecret` = `netbox-app-secret`、
  秘密情報は `secrets-templates/` テンプレート経由で手動 apply、の旨）。

## 適用順序（ユーザー作業）

1. ブランチ `feat/existing-secret-and-tls` をマージ（またはレビュー用 PR）。
2. `secrets-templates/netbox-app-secret.yaml.example` と
   `netbox-postgresql-auth.yaml.example` に実値を投入し `kubectl apply`（namespace `netbox2`）。
   ※ 既存の `netbox-postgresql-auth` が既にライブに存在するなら値を再投入すれば足りる。
3. `netbox-git` を sync（App-of-Apps）→ 子 `netbox`（自動 selfHeal）が Helm 変更を適用。
4. NetBox Deployment / worker を `kubectl rollout restart`。
5. cert-manager が `netbox2-tls` を発行完了後、`https://netbox2.service.z1n.in` で確認。

## スコープ外（明示）

- `netbox-diode-secrets.yaml` / `orb-agent-secrets.yaml` 等、他の既存コミット済み Secret の
  テンプレート化（今回は `netbox-secrets.yaml` のみ対象）。
- git 履歴の書き換え（旧パスワード除去）。
- Traefik 静的設定（entryPoint レベルの全体リダイレクト）変更。

## 成功基準

- リポジトリの追跡ファイルに実パスワード等の秘密情報が含まれない
  （`netbox-app-secret` / `netbox-postgresql-auth` はプレースホルダのみ）。
- `helm template`（本 values 相当）で `netbox-config` / `netbox-superuser` Secret が生成されない。
- LDAP パスワードが `netbox-app-secret` から読まれ、selfHeal で上書きされない。
- `https://netbox2.service.z1n.in` が有効な cert-manager 証明書で応答し、HTTP はリダイレクトされる。
