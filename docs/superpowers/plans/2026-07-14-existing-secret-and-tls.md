# existingSecret 移行 + Traefik TLS 化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** NetBox の秘密情報をチャート外の単一 `netbox-app-secret`（existingSecret）へ切り出し、平文コミット済み PostgreSQL Secret をテンプレート化し、NetBox Ingress を cert-manager + Traefik TLS（HTTPS 強制リダイレクト）へ移行する。

**Architecture:** NetBox Helm チャート（ArgoCD 経由, `helm template` レンダリング）の values を `existingSecret` / `superuser.existingSecret` に切り替え、自動生成 Secret を無効化する。秘密情報テンプレートは App-of-Apps `netbox-git` の同期対象（`argocd/applications/`）**外**の `secrets-templates/` に置き、ユーザーが手動 apply する。TLS は cert-manager ingress-shim（`cf-cluster-issuer`）で証明書 Secret を自動生成するため、Ingress マニフェストに秘密情報は含まれない。

**Tech Stack:** NetBox Helm chart 7.1.10 / ArgoCD / Traefik (rke2-traefik) / cert-manager / Kubernetes (RKE2)

## Global Constraints

- リポジトリはパブリック。追跡ファイルに実パスワード・トークン・鍵を含めない（プレースホルダのみ）。
- `git push` は実行しない（ユーザーが実施）。`kubectl apply` は実行しない（ArgoCD 管理、ユーザーが sync）。
- 対象 namespace: `netbox2`。
- existingSecret 名: `netbox-app-secret`（config + superuser 兼用）。
- TLS 証明書 Secret 名: `netbox2-tls`（cert-manager 自動生成）。ClusterIssuer: `cf-cluster-issuer`。
- ホスト名: `netbox2.service.z1n.in`。
- NetBox chart バージョン: `7.1.10`（`argocd/applications/netbox.yaml` の `targetRevision` と一致させる）。
- レンダリング検証用ローカルチャートは `helm repo add netbox https://charts.netbox.oss.netboxlabs.com/` で取得可能。
- 作業ブランチ: `feat/existing-secret-and-tls`（既存。全コミットはこのブランチ）。

---

## Task 1: NetBox values を existingSecret 方式へ切り替え

**Files:**
- Modify: `argocd/applications/netbox.yaml`（values 内。`superuser`/`existingSecret` 追加、LDAP コメント修正）

**Interfaces:**
- Consumes: なし（チャート仕様に依存）。
- Produces: Helm values に `existingSecret: "netbox-app-secret"` と `superuser.existingSecret: "netbox-app-secret"` が存在し、`remoteAuth.ldap.bindPassword` を含まない状態。後続 Task 2 のテンプレートが提供するキー（`secret_key`, `ldap_bind_password`, `email_password`, `username`, `email`, `password`, `api_token`）を参照する。

- [ ] **Step 1: レンダリング検証スクリプトの準備（失敗確認用）**

ローカルにチャートを取得（未取得の場合のみ）:

```bash
helm repo add netbox https://charts.netbox.oss.netboxlabs.com/ 2>/dev/null || true
helm repo update netbox
```

現状の values を単体ファイルに抽出してレンダリングし、`netbox-config` Secret が**生成されている**ことを確認（この時点では「まだ存在する」= 変更前の失敗状態）:

```bash
python3 - <<'PY'
import re
s=open('argocd/applications/netbox.yaml').read()
# helm.values: | ブロックを抽出
m=re.search(r'\n      values: \|\n(.*?)(?=\n  [a-zA-Z]|\Z)', s, re.S)
body=m.group(1)
# 先頭の共通インデント(8スペース)を除去
import textwrap
lines=[l[8:] if l.startswith(' '*8) else l for l in body.splitlines()]
open('/tmp/nb-values.yaml','w').write('\n'.join(lines)+'\n')
print("extracted", len(lines), "lines")
PY
helm template netbox netbox/netbox --version 7.1.10 -f /tmp/nb-values.yaml 2>/dev/null \
  | grep -E "name: netbox-config|name: netbox-superuser" || echo "NO AUTO SECRET"
```

Expected: `name: netbox-config` と `name: netbox-superuser` が**出力される**（＝まだ自動生成されている＝これから消す対象）。

- [ ] **Step 2: values を編集**

`argocd/applications/netbox.yaml` の Helm `values:` ブロックに対して以下を行う。

(a) values 最上位（`global:` と同階層、インデント8スペース）に `existingSecret` を追加:

```yaml
        # --- 秘密情報は existingSecret 経由（パブリックリポジトリのため実値を保持しない）---
        # netbox-app-secret のキー: secret_key / ldap_bind_password / email_password
        #   （secrets-templates/netbox-app-secret.yaml.example から手動 apply）
        existingSecret: "netbox-app-secret"
```

(b) `superuser` ブロックを追加（同じく最上位、インデント8スペース）:

```yaml
        # superuser 認証情報も同じ Secret から読む（username/email/password/api_token キー）
        superuser:
          existingSecret: "netbox-app-secret"
```

(c) `remoteAuth.ldap` に `bindPassword` の行があれば削除する（存在しなければ何もしない）。現状の
`argocd/applications/netbox.yaml` には `bindPassword` の記述は無いため、通常この (c) は変更不要。

(d) `remoteAuth` 直上のコメント（`ldap_bind_password は Helm が自動生成する netbox-config Secret に含まれます` / `kubectl edit secret netbox-config` を案内している 3〜4 行）を以下に置換:

```yaml
        # --- LDAP認証設定 ---
        # 注意: ldap_bind_password は existingSecret "netbox-app-secret" から読み込まれます。
        # 更新するには secrets-templates/netbox-app-secret.yaml.example を編集して
        #   kubectl apply -f <filled>.yaml -n netbox2
        # を実行し、その後 NetBox Deployment / worker を rollout restart してください。
```

同様に `remoteAuth.ldap` 内の `bindPasswordは Helm 自動生成の netbox-config Secret の ldap_bind_password キーから読み込み` / `(kubectl edit secret netbox-config ...)` のコメント 2 行を以下に置換:

```yaml
            # bindPassword は existingSecret "netbox-app-secret" の ldap_bind_password キーから読み込み
```

- [ ] **Step 3: レンダリングで自動生成 Secret が消えたことを確認**

Step 1 と同じ抽出＋レンダリングを再実行:

```bash
python3 - <<'PY'
import re
s=open('argocd/applications/netbox.yaml').read()
m=re.search(r'\n      values: \|\n(.*?)(?=\n  [a-zA-Z]|\Z)', s, re.S)
lines=[l[8:] if l.startswith(' '*8) else l for l in m.group(1).splitlines()]
open('/tmp/nb-values.yaml','w').write('\n'.join(lines)+'\n')
PY
echo "=== netbox-config / netbox-superuser は生成されないはず ==="
helm template netbox netbox/netbox --version 7.1.10 -f /tmp/nb-values.yaml 2>/dev/null \
  | grep -E "name: netbox-config$|name: netbox-superuser$" && echo "!! まだ生成されている(NG)" || echo "OK: 自動生成なし"
echo "=== deployment が netbox-app-secret を参照するはず ==="
helm template netbox netbox/netbox --version 7.1.10 -f /tmp/nb-values.yaml 2>/dev/null \
  | grep -c "netbox-app-secret" | xargs -I{} echo "netbox-app-secret 参照数: {}"
```

Expected: `OK: 自動生成なし` と表示され、`netbox-app-secret 参照数` が 1 以上。

- [ ] **Step 4: Helm values の YAML 妥当性を確認**

```bash
python3 -c "import yaml; yaml.safe_load(open('/tmp/nb-values.yaml')); print('values YAML OK')"
```

Expected: `values YAML OK`

- [ ] **Step 5: コミット**

```bash
git add argocd/applications/netbox.yaml
git commit -m "feat: Switch NetBox to existingSecret (netbox-app-secret) for config and superuser

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: 秘密情報テンプレートと README を作成

**Files:**
- Create: `secrets-templates/netbox-app-secret.yaml.example`
- Create: `secrets-templates/netbox-postgresql-auth.yaml.example`
- Create: `secrets-templates/README.md`

**Interfaces:**
- Consumes: Task 1 が要求するキー集合（`secret_key`, `ldap_bind_password`, `email_password`, `username`, `email`, `password`, `api_token`）と、PostgreSQL Secret 名 `netbox-postgresql-auth`（キー `password`, `postgres-password`）。
- Produces: 手動 apply 用テンプレート。実値を含まない。

- [ ] **Step 1: `netbox-app-secret.yaml.example` を作成**

```yaml
# NetBox アプリ用 Secret テンプレート（config + superuser 兼用）
# 使い方:
#   1. このファイルをコピーし .example を外す
#   2. 各 <...> を実値に置換（secret_key は 50 文字以上のランダム文字列）
#      生成例: python3 -c 'import secrets; print(secrets.token_urlsafe(50))'
#   3. kubectl apply -f netbox-app-secret.yaml -n netbox2
#   4. kubectl rollout restart deployment,statefulset -n netbox2 -l app.kubernetes.io/name=netbox
# 注意: このファイル(.example)は argocd/applications/ の外にあり ArgoCD の同期対象外です。
apiVersion: v1
kind: Secret
metadata:
  name: netbox-app-secret
  namespace: netbox2
  labels:
    app.z1n.in/stack: netbox
    app.z1n.in/component: app-secret
type: Opaque
stringData:
  # --- config (トップレベル existingSecret) ---
  secret_key: "<50文字以上のランダム文字列>"
  ldap_bind_password: "<LDAP bind パスワード>"
  email_password: ""            # メール未使用なら空のまま
  # --- superuser (superuser.existingSecret) ---
  username: "admin"
  email: "admin@example.com"
  password: "<superuser パスワード>"
  api_token: "<superuser API トークン (任意の 40 文字程度)>"
```

- [ ] **Step 2: `netbox-postgresql-auth.yaml.example` を作成**

```yaml
# PostgreSQL 認証 Secret テンプレート
# 使い方:
#   1. このファイルをコピーし .example を外す
#   2. <...> を実値に置換
#   3. kubectl apply -f netbox-postgresql-auth.yaml -n netbox2
# 注意: 旧 argocd/applications/netbox-secrets.yaml に平文コミットされていた値は
#       git 履歴に残っています。真の是正として DB パスワードのローテーションを推奨します。
apiVersion: v1
kind: Secret
metadata:
  name: netbox-postgresql-auth
  namespace: netbox2
  labels:
    app.z1n.in/stack: netbox
    app.z1n.in/component: postgresql
type: Opaque
stringData:
  password: "<netbox DB ユーザーパスワード>"
  postgres-password: "<postgres 管理ユーザーパスワード>"
```

- [ ] **Step 3: `README.md` を作成**

```markdown
# secrets-templates

パブリックリポジトリに実値を置かないための Secret テンプレート集。
**このディレクトリは App-of-Apps `netbox-git`（`source.path: argocd/applications`）の
同期対象外**のため、ArgoCD に上書きされません。ユーザーが手動で apply します。

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
```

- [ ] **Step 4: テンプレートの YAML 妥当性と「実値が無いこと」を確認**

```bash
for f in secrets-templates/*.yaml.example; do
  python3 -c "import yaml; list(yaml.safe_load_all(open('$f'))); print('YAML OK: $f')"
done
echo "=== プレースホルダ(<...>)が残っていること / 実値らしき base64 が無いこと ==="
grep -q "<" secrets-templates/netbox-app-secret.yaml.example && echo "OK: placeholder present"
```

Expected: 各ファイル `YAML OK`、`OK: placeholder present`。

- [ ] **Step 5: コミット**

```bash
git add secrets-templates/
git commit -m "feat: Add out-of-sync secret templates for netbox-app-secret and postgres

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 平文コミット済み Secret の分割・除去

**Files:**
- Create: `argocd/applications/netbox-env-config.yaml`（`DB_CONN_MAX_AGE` のみ、秘密情報でない）
- Delete: `argocd/applications/netbox-secrets.yaml`（PostgreSQL 平文 Secret を含む）

**Interfaces:**
- Consumes: なし。
- Produces: `argocd/applications/` に平文パスワードが存在しない状態。`netbox-env-config` Secret（非秘密）は引き続き同期される。

- [ ] **Step 1: `netbox-env-config.yaml` を作成**

`argocd/applications/netbox-secrets.yaml` の後半（`netbox-env-config` 部分）のみを新ファイルに移す:

```yaml
---
# NetBox extraConfig Secret (DB connection pool optimization)
# Helm values の extraConfig から参照される
# /run/config/extra/0/db_conn_max_age.py としてマウントされ NetBox の追加設定として読み込まれる
# 注意: これは秘密情報ではない（DB 接続の CONN_MAX_AGE 設定値のみ）ため ArgoCD 同期対象のまま。
apiVersion: v1
kind: Secret
metadata:
  name: netbox-env-config
  namespace: netbox2
  labels:
    app.z1n.in/stack: netbox
    app.z1n.in/component: config
type: Opaque
stringData:
  DB_CONN_MAX_AGE: |
    DATABASE['CONN_MAX_AGE'] = 300
```

- [ ] **Step 2: 平文 Secret ファイルを削除**

```bash
git rm argocd/applications/netbox-secrets.yaml
```

- [ ] **Step 3: `argocd/applications/` に平文パスワードが残っていないことを確認**

```bash
echo "=== netbox-postgresql-auth の定義が argocd/applications/ から消えたこと ==="
grep -rl "name: netbox-postgresql-auth" argocd/applications/ && echo "!! まだ存在(NG)" || echo "OK: 平文 postgres secret なし"
echo "=== netbox-env-config は残っていること ==="
grep -rl "name: netbox-env-config" argocd/applications/
```

Expected: `OK: 平文 postgres secret なし` と、`netbox-env-config.yaml` が列挙される。

- [ ] **Step 4: netbox.yaml が参照する netbox-env-config が引き続き解決可能か確認**

`argocd/applications/netbox.yaml` の `extraConfig` は `secretName: netbox-env-config` を参照している。
Step 1 のファイルで同名 Secret を維持しているため参照は保たれる。確認:

```bash
grep -n "secretName: netbox-env-config" argocd/applications/netbox.yaml
python3 -c "import yaml; list(yaml.safe_load_all(open('argocd/applications/netbox-env-config.yaml'))); print('env-config YAML OK')"
```

Expected: `secretName: netbox-env-config` がヒットし、`env-config YAML OK`。

- [ ] **Step 5: コミット**

```bash
git add argocd/applications/netbox-env-config.yaml
git commit -m "refactor: Split non-secret env-config out and remove plaintext postgres secret

netbox-postgresql-auth is now managed via secrets-templates/ (manual apply).
DB_CONN_MAX_AGE moves to netbox-env-config.yaml (not sensitive, stays synced).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Ingress を Traefik TLS + HTTPS リダイレクトへ

**Files:**
- Modify: `argocd/applications/netbox-ingress.yaml`（Middleware 追加、Ingress に annotations と tls を追加）

**Interfaces:**
- Consumes: クラスタの `ClusterIssuer/cf-cluster-issuer`、Traefik エントリポイント `web` / `websecure`。
- Produces: `https://netbox2.service.z1n.in` を提供する Ingress と HTTP→HTTPS リダイレクト Middleware。証明書 Secret `netbox2-tls` は cert-manager が自動生成。

- [ ] **Step 1: `netbox-ingress.yaml` を全面更新**

ファイル全体を以下で置換:

```yaml
---
# HTTP を HTTPS へ 301 リダイレクトする Traefik Middleware
# 既に https のリクエストはリダイレクト後 URL が同一となり Traefik がスキップするためループしない
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: netbox-https-redirect
  namespace: netbox2
spec:
  redirectScheme:
    scheme: https
    permanent: true
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: netbox-ingress
  namespace: netbox2
  annotations:
    # External DNS設定
    external-dns.alpha.kubernetes.io/hostname: netbox2.service.z1n.in
    external-dns.alpha.kubernetes.io/ttl: "300"
    # cert-manager が Certificate と netbox2-tls Secret を自動生成（既存 home-assistant と同方式）
    cert-manager.io/cluster-issuer: cf-cluster-issuer
    # Traefik: HTTP/HTTPS 両エントリポイントで受け付ける
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    # HTTP→HTTPS 強制リダイレクト（<namespace>-<middleware>@kubernetescrd 形式）
    traefik.ingress.kubernetes.io/router.middlewares: netbox2-netbox-https-redirect@kubernetescrd
  labels:
    app.kubernetes.io/name: netbox
    app.kubernetes.io/instance: netbox
    app.kubernetes.io/component: ingress
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - netbox2.service.z1n.in
    secretName: netbox2-tls
  rules:
  - host: netbox2.service.z1n.in
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: netbox
            port:
              number: 80
```

- [ ] **Step 2: YAML 妥当性と必須要素を確認**

```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('argocd/applications/netbox-ingress.yaml'))); print('ingress YAML OK')"
echo "=== 必須要素チェック ==="
for needle in \
  "kind: Middleware" \
  "scheme: https" \
  "cert-manager.io/cluster-issuer: cf-cluster-issuer" \
  "router.entrypoints: web,websecure" \
  "netbox2-netbox-https-redirect@kubernetescrd" \
  "secretName: netbox2-tls"; do
  grep -q "$needle" argocd/applications/netbox-ingress.yaml && echo "OK: $needle" || echo "MISSING: $needle"
done
```

Expected: `ingress YAML OK` と、全 needle が `OK:`。

- [ ] **Step 3: dry-run（サーバ検証, apply はしない）**

`kubectl apply` は禁止のため `--dry-run=client` でスキーマ検証のみ（クラスタ変更なし）:

```bash
kubectl apply --dry-run=client -f argocd/applications/netbox-ingress.yaml
```

Expected: `middleware.traefik.io/netbox-https-redirect created (dry run)` と
`ingress.networking.k8s.io/netbox-ingress configured (dry run)`（エラーが出ないこと）。
※ CRD 未認識等で client dry-run が Middleware を検証できない場合は Ingress 部分がエラーなく通ればよい。

- [ ] **Step 4: コミット**

```bash
git add argocd/applications/netbox-ingress.yaml
git commit -m "feat: Enable Traefik TLS with cert-manager and HTTPS redirect for NetBox ingress

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `.gitignore` と `CLAUDE.md` の更新

**Files:**
- Modify: `.gitignore`（実値の Secret ファイルを無視）
- Modify: `CLAUDE.md`（LDAP / Secret 運用手順を existingSecret 方式へ更新）

**Interfaces:**
- Consumes: Task 1〜4 の成果（名前・パス）。
- Produces: 実値ファイルの誤コミット防止と、最新運用を反映したドキュメント。

- [ ] **Step 1: `.gitignore` に実値ファイルの無視ルールを追加**

現状 `.gitignore` は `.env` のみ。以下を追記（`secrets-templates/` 内で `.example` を外した実ファイルを無視）:

```gitignore
# secrets-templates 内の実値ファイル（.example のみ追跡する）
secrets-templates/*.yaml
!secrets-templates/*.yaml.example
```

- [ ] **Step 2: 無視ルールの動作確認**

```bash
touch secrets-templates/netbox-app-secret.yaml
git check-ignore secrets-templates/netbox-app-secret.yaml && echo "OK: 実値ファイルは無視される" || echo "NG: 無視されていない"
git check-ignore secrets-templates/netbox-app-secret.yaml.example && echo "NG: example まで無視" || echo "OK: example は追跡される"
rm -f secrets-templates/netbox-app-secret.yaml
```

Expected: `OK: 実値ファイルは無視される` と `OK: example は追跡される`。

- [ ] **Step 3: `CLAUDE.md` の LDAP / Secret 記述を更新**

`CLAUDE.md` の LDAP Authentication セクションおよび Configuring NetBox LDAP Authentication 手順で、
`netbox-app-secret` を「Helm 自動生成 `netbox-config` を編集」ではなく「`secrets-templates/` の
テンプレートから手動 apply する existingSecret」として説明するよう修正する。具体的には:

(a) LDAP Authentication セクションの `superuser.existingSecret` / `bindPassword` の説明箇所を、
`existingSecret: "netbox-app-secret"`（config + superuser 兼用）と、キーが `secrets-templates/` の
テンプレート由来である旨に更新。

(b) `### Configuring NetBox LDAP Authentication` 手順の「Update `netbox-app-secret.yaml`」の参照先を
`secrets-templates/netbox-app-secret.yaml.example` に修正し、apply コマンドを
`kubectl apply -f secrets-templates/netbox-app-secret.yaml -n netbox2` に更新。

(c) `netbox-env-config` に関する記述があれば、DB_CONN_MAX_AGE 用の非秘密 Secret であり
`argocd/applications/netbox-env-config.yaml` に定義される旨を追記。

編集後、参照整合を確認:

```bash
echo "=== 旧記述が残っていないこと ==="
grep -n "kubectl edit secret netbox-config" CLAUDE.md && echo "!! 旧記述あり(要修正)" || echo "OK: 旧 netbox-config 編集手順なし"
echo "=== 新記述があること ==="
grep -n "netbox-app-secret\|secrets-templates" CLAUDE.md | head
```

Expected: `OK: 旧 netbox-config 編集手順なし`、および `netbox-app-secret` / `secrets-templates` がヒット。

- [ ] **Step 4: コミット**

```bash
git add .gitignore CLAUDE.md
git commit -m "docs: Ignore real secret files and document existingSecret/TLS workflow

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 最終検証（全体レンダリング & リポジトリの秘密情報スキャン）

**Files:**
- なし（検証のみ）

**Interfaces:**
- Consumes: Task 1〜5 の全成果。
- Produces: 成功基準の充足エビデンス。

- [ ] **Step 1: Helm レンダリングで自動生成 Secret が無いことを再確認**

```bash
python3 - <<'PY'
import re
s=open('argocd/applications/netbox.yaml').read()
m=re.search(r'\n      values: \|\n(.*?)(?=\n  [a-zA-Z]|\Z)', s, re.S)
lines=[l[8:] if l.startswith(' '*8) else l for l in m.group(1).splitlines()]
open('/tmp/nb-values.yaml','w').write('\n'.join(lines)+'\n')
PY
helm template netbox netbox/netbox --version 7.1.10 -f /tmp/nb-values.yaml 2>/dev/null \
  | grep -E "name: netbox-config$|name: netbox-superuser$" && echo "NG" || echo "OK: 自動生成 Secret なし"
```

Expected: `OK: 自動生成 Secret なし`。

- [ ] **Step 2: 追跡ファイルに実秘密情報が無いことをスキャン**

```bash
echo "=== 追跡ファイル内に実 base64 パスワードらしき文字列が無いか（テンプレートはプレースホルダのみ） ==="
git ls-files | grep -vE 'docs/|\.example$' | while read f; do
  grep -HnE 'password: "[A-Za-z0-9+/=]{16,}"|postgres-password: "[A-Za-z0-9+/=]{16,}"' "$f"
done && echo "(該当があれば上に表示)"
echo "=== プレースホルダ以外の secret_key が無いこと ==="
git ls-files | grep -vE '\.example$' | xargs grep -nE 'secret_key: "[^<]' 2>/dev/null && echo "!! 実値の可能性" || echo "OK: 実 secret_key なし"
```

Expected: 実値ヒットが無く、`OK: 実 secret_key なし`。

- [ ] **Step 3: 全マニフェストの YAML 妥当性を一括確認**

```bash
for f in argocd/applications/netbox.yaml argocd/applications/netbox-ingress.yaml \
         argocd/applications/netbox-env-config.yaml secrets-templates/*.yaml.example; do
  python3 -c "import yaml; list(yaml.safe_load_all(open('$f'))); print('OK: $f')" || echo "NG: $f"
done
```

Expected: 全ファイル `OK:`。

- [ ] **Step 4: 変更サマリを確認（コミット済みであること）**

```bash
git log --oneline main..HEAD
git status --short
```

Expected: Task 1〜5 の 5 コミットが並び、`git status` はクリーン（未追跡の実値ファイルなし）。

- [ ] **Step 5: ユーザーへ適用手順を提示（コード変更なし）**

以下をユーザーに案内する（実行はユーザー）:
1. `secrets-templates/*.example` を埋めて `kubectl apply -n netbox2`。
2. ブランチ `feat/existing-secret-and-tls` を push → PR / マージ。
3. `netbox-git` を ArgoCD で sync → 子 `netbox` が Helm 変更適用。
4. `kubectl rollout restart deployment -n netbox2 -l app.kubernetes.io/name=netbox`。
5. cert-manager が `netbox2-tls` 発行後、`https://netbox2.service.z1n.in` を確認。

---

## 適用順序（参考・ユーザー作業）

設計書 `docs/superpowers/specs/2026-07-14-existing-secret-and-tls-design.md` の「適用順序」を参照。
