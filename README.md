# Terraform AWS Template

Ausgangspunkt für ein AWS-Projekt mit Terraform oder OpenTofu. Du legst daraus ein eigenes Repository an, ersetzt die Platzhalter und schreibst deine Ressourcen dazu. Ein privater Beispiel-Bucket zeigt, wie Ressource, Variablen und Tags zusammenhängen.

## Worum es geht

Dieselbe Codebasis beschreibt mehrere Umgebungen. Jede Umgebung ist ein eigener Terraform-Workspace mit eigenem State: `dev`, `staging`, `prod` und beliebig viele `preview-<name>`. Der State liegt in einem gemeinsamen S3-Bucket. Der Workspace trennt ihn, zum Beispiel `env:/prod/...` und `env:/dev/...`.

Der Git-Branch sagt, welche Umgebung gemeint ist. `main` ist Produktion, `develop` ist Development, `staging` ist Staging, `preview/<name>` ist eine eigene, kurzlebige Umgebung. Die genaue Zuordnung steht unter [Branch und Workspace](#branch-und-workspace).

Alle Umgebungsdateien liegen auf jedem Branch. Ein Merge von `develop` nach `staging` und weiter nach `main` ändert deshalb nicht, in welchen State geschrieben wird. Lokal entscheidet der ausgecheckte Branch. In einem Pull Request entscheidet der Zielbranch, außer der Head heißt `preview/<name>`: dann gilt immer dieser Preview-Branch. Details stehen unter [Pipeline](#pipeline).

## Warum

Branch, Workspace, State und die Bedienung in GitHub sind hier schon festgelegt. Ein neues Projekt übernimmt diese Entscheidungen.

- Lokal reichen `scripts/tf plan` und `scripts/tf apply`. Das Skript wählt Workspace, Variablen und Backend.
- `apply` nimmt nur die Plan-Datei, die direkt davor entstanden ist.
- In GitHub steuerst du denselben Ablauf per Kommentar. `/tf plan` schreibt den Plan in den Pull Request. `/tf apply` wendet genau diesen Plan an.
- Zwei offene Pull Requests gegen dieselbe Umgebung teilen sich eine Sperre. Der erste `/tf plan` hält sie, bis dieser Pull Request applied oder `/tf unlock` kommt. Der andere Pull Request plant erst danach neu.
- Die Pipeline meldet sich bei AWS per OIDC an, mit kurzlebigen Credentials und ohne Access-Key im Repository.
- Ein Branch `preview/<name>` bekommt eine eigene Umgebung. Jeder Push dorthin plant und wendet an. Der Weg von develop über staging nach Produktion bleibt davon unberührt.

## So arbeitest du damit

1. Lege aus diesem Template dein Repository an und geh die Checkliste unter [How to setup](#how-to-setup) durch. Damit stehen State-Bucket, Namen und, wenn du sie willst, die GitHub-Pipeline.
2. Für die tägliche Arbeit an Development checkst du `develop` aus. Änderungen wandern per Merge von `develop` nach `staging` und von `staging` nach `main`.
3. Im Pull Request kommentierst du `/tf plan` und liest den Plan in der Antwort. Passt er, kommentierst du `/tf apply`. Auf dem Weg nach Staging und Produktion wartet Apply auf eine zusätzliche Freigabe in GitHub.
4. Zum Ausprobieren, ohne `dev` zu verändern, legst du `preview/<name>` an. Push auf diesen Branch plant und wendet diese Umgebung an.
5. Eigene Ressourcen kommen als weitere `.tf`-Dateien neben [`example-s3-bucket.tf`](example-s3-bucket.tf). Neue Variablen kommen nach `_variables.tf` und in `environments/<env>.tfvars`.

## How to setup

1. Lege aus diesem Template ein neues Repository an oder klone es. Für die lokale Arbeit an dev checke `develop` aus. `main` ist prod, `staging` ist staging.
2. Installiere Terraform `>= 1.10` oder OpenTofu, und richte AWS-Credentials für das Zielkonto ein. OpenTofu wählst du mit `export EXECUTABLE=tofu`.
3. Ersetze in `environments/<env>.tfvars` und `environments/<env>.backend.tfvars` jeden Namen, der mit `REPLACE_ME` beginnt. Der State-Bucket-Name ist in allen Backend-Dateien und im TODO-Block von `_terraform.tf` derselbe.
4. Lege den State-Bucket einmalig an, wie unter [State-Bucket bootstrapen](#state-bucket-bootstrapen) beschrieben.
5. Initialisiere das Environment und wende den Plan an:

```bash
scripts/tf init
scripts/tf plan
scripts/tf apply
```

6. Richte die [OIDC-Anmeldung](#oidc-anmeldung) ein.
7. Benenne die Workflow-Vorlagen um, damit GitHub sie in dem neuen Repository ausführt:

```bash
git mv .github/workflows/terraform-commands.yml.template .github/workflows/terraform-commands.yml
git mv .github/workflows/terraform-preview.yml.template .github/workflows/terraform-preview.yml
```

In diesem Template bleiben die Endungen `.template`. GitHub startet nur Dateien, die auf `.yml` oder `.yaml` enden.

Lokal geht das auch gegen einen anderen Branch, zum Beispiel `scripts/tf -e dev plan`. Die Pipeline setzt `-e` selbst, siehe [Pipeline](#pipeline).

## Branch und Workspace

| Branch           | Workspace und Dateiname |
| ---------------- | ----------------------- |
| `main`           | `prod`                  |
| `develop`        | `dev`                   |
| `staging`        | `staging`               |
| `preview/<name>` | `preview-<name>`        |

Beim Preview wird nur das erste `/` zum Bindestrich. `preview/feature123` wird `preview-feature123`, `preview/ticket-769` wird `preview-ticket-769`.

Alle Env-Dateien liegen auf jedem Branch. Der Branch entscheidet, welche Dateien das Skript benutzt. Merges von `develop` nach `staging` nach `main` ändern damit nicht versehentlich das State-Ziel.

## Aufrufe

```bash
scripts/tf init
scripts/tf plan
scripts/tf apply
scripts/tf import aws_s3_bucket.example my-bucket
```

Lokal, unabhängig vom ausgecheckten Branch:

```bash
scripts/tf -e dev plan
scripts/tf --env prod apply
scripts/tf --env preview-feature123 init
```

`-e` und `--env` sind gleichwertig und stehen vor dem Subcommand. Weicht der Name vom Branch ab, schreibt das Skript einen Hinweis auf stderr und arbeitet weiter. Die Pipeline übergibt `-e` mit dem Workspace aus [Pipeline](#pipeline).

`plan` schreibt `environments/<env>.tfplan`. `apply` wendet nur diese Datei an und löscht sie danach. Liegt keine Plan-Datei, bricht `apply` ab.

`environments/<env>.secrets.tfvars` wird automatisch mitgegeben, sobald die Datei existiert. Sie ist gitignored. Eine Vorlage liegt unter `environments/secrets.tfvars.example`. In der Pipeline schreibt das Secret `TF_SECRETS_TFVARS` diese Datei, wenn es gesetzt ist.

## Pipeline

Die Workflows liegen als Vorlagen unter `.github/workflows/*.yml.template`. Erst nach dem Umbenennen aus [How to setup](#how-to-setup) führt GitHub sie aus. Kommentare liest GitHub vom Default-Branch `main`. Ein Push auf `preview/<name>` liest den Workflow von diesem Branch.

Der Code ist immer der Commit des Pull Requests oder des Pushes. Der Workspace kommt so zustande:

- Beginnt der Head mit `preview/<name>`, gilt dieser Branch. `preview/feature123` wird `preview-feature123`, auch wenn der Pull Request nach `develop` zeigt.
- Sonst gilt der Zielbranch: ein Feature-Branch nach `develop` trifft `dev`, `develop` nach `staging` trifft `staging`, `staging` nach `main` trifft `prod`.
- Ein unbekannter Zielbranch, der kein `main`, `develop`, `staging` oder `preview/<name>` ist, bricht ab.

Kommentare auf einem Pull Request, exakt und mit Schreibrecht im Repository:

- `/tf plan` plant und schreibt die Ausgabe als Antwort in den Pull Request. Die binäre Plan-Datei liegt als Artifact `tfplan-<pr>-<sha>-<workspace>`.
- `/tf apply` wendet genau dieses Artifact an. Ein neuer Commit braucht einen neuen Plan.
- `/tf unlock` hebt die Sperre ohne Apply auf. Der gespeicherte Plan gilt danach nicht mehr.

Forks sind ausgeschlossen. Apply auf `prod` und `staging` wartet auf die Freigabe des GitHub-Environments mit demselben Namen. Plan und Unlock warten nicht. `dev` und `preview-*` haben diese Pause nicht.

Pro Workspace hält höchstens ein Pull Request die Sperre. Sie liegt im State-Bucket neben dem State-Key, beim Key `terraform-aws-template/terraform.tfstate` also unter `terraform-aws-template/pr-locks/<workspace>.json`. `/tf plan` legt sie an. Ein zweiter Pull Request gegen denselben Workspace bekommt keinen Plan und einen Kommentar mit dem Link auf den sperrenden Pull Request. `/tf apply` läuft nur für den Pull Request und den Commit der Sperre und löst sie danach. Schlägt der Plan fehl, wird die Sperre gelöst. Schlägt Apply fehl, bleibt sie bestehen.

Ein Push auf `preview/<name>` führt init, plan und apply für `preview-<name>` aus, ohne Kommentar. Fehlen die Env-Dateien im Branch, legt `init` nur die Vorlagen an und der Lauf endet, bevor etwas angewendet wird. Die Dateien müssen im Branch stehen. Hält ein Pull Request die Sperre dieses Workspaces, bricht der Push ab.

## OIDC-Anmeldung

Die Pipeline hat keine langlebigen Access-Keys. Sie nimmt die Repository-Variable `AWS_ROLE_ARN` und tauscht ein GitHub-JWT gegen kurzlebige Credentials.

### Provider und Role

Einmal pro AWS-Konto, falls der Provider noch fehlt. Die Thumbprints verlangt die API. AWS prüft sie für diesen Provider nicht.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd
```

Lege eine Role an, die nur diesen Subjects vertraut. `ORG` und `REPO` sind der GitHub-Name, `ACCOUNT_ID` die AWS-Kontonummer. Audience ist `sts.amazonaws.com`.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": [
                        "repo:ORG/REPO:ref:refs/heads/main",
                        "repo:ORG/REPO:environment:prod",
                        "repo:ORG/REPO:environment:staging",
                        "repo:ORG/REPO:ref:refs/heads/preview/*"
                    ]
                }
            }
        }
    ]
}
```

`repo:ORG/REPO:ref:refs/heads/main` gilt für `/tf plan`, für `/tf unlock` und für Apply ohne GitHub-Environment (`dev`, Preview-Kommentar). Ein Kommentar-Workflow läuft auf dem Default-Branch, deshalb ist der Subject `main`. `environment:prod` und `environment:staging` gelten, sobald Apply das Environment setzt; der Subject ersetzt dann den Branch. `preview/*` gilt für den Push auf `preview/<name>`.

```bash
aws iam create-role \
  --role-name REPLACE_ME-github-terraform \
  --assume-role-policy-document file://trust.json
```

### Rechte der Role

Die Role braucht den State-Bucket aus `environments/*.backend.tfvars`: State unter `env:/<workspace>/`, die Terraform-Lockdatei und `pr-locks/`. Passe den Bucket-Namen und das Key-Präfix an, wenn du sie geändert hast. Der Beispiel-Bucket aus `example-s3-bucket.tf` braucht eigene Rechte, passend zu den Namen in den tfvars.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "StateList",
            "Effect": "Allow",
            "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
            "Resource": "arn:aws:s3:::REPLACE_ME-tfstate"
        },
        {
            "Sid": "StateObjects",
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
            "Resource": [
                "arn:aws:s3:::REPLACE_ME-tfstate/env:/*",
                "arn:aws:s3:::REPLACE_ME-tfstate/terraform-aws-template/pr-locks/*"
            ]
        }
    ]
}
```

```bash
aws iam put-role-policy \
  --role-name REPLACE_ME-github-terraform \
  --policy-name terraform-state \
  --policy-document file://state.json
```

### GitHub

Unter Settings → Secrets and variables → Actions → Variables die Variable `AWS_ROLE_ARN` auf die Role-ARN setzen. Das ist kein Secret. Optional `AWS_REGION`, sonst nimmt die Pipeline `eu-central-1`. Optional `EXECUTABLE` mit dem Wert `tofu`.

Lege die Environments `prod` und `staging` an und setze Required reviewers. Liegt dort ebenfalls `AWS_ROLE_ARN`, gilt diese Role nur für das geschützte Apply. Ihre Trust-Policy braucht dann den Subject `repo:ORG/REPO:environment:prod` oder `environment:staging`, und dieselben State-Rechte, weil Apply den State liest und die Sperre löst.

Der Default-Branch bleibt `main`.

### Was jeder Lauf tut

Das Workflow-Recht `id-token: write` stellt das JWT aus. `aws-actions/configure-aws-credentials` tauscht es gegen kurzlebige Credentials der Role aus `vars.AWS_ROLE_ARN`. Danach laufen `scripts/tf` und die Sperre mit diesen Credentials. Ohne Variable oder ohne passenden Subject endet der Lauf an der Anmeldung, bevor Terraform startet.

## Terraform oder OpenTofu

`EXECUTABLE` legt fest, welches Programm `scripts/tf` aufruft. Erlaubt sind `terraform` und `tofu`. Ohne Angabe wird `terraform` verwendet.

```bash
EXECUTABLE=tofu scripts/tf plan
```

## Dateien

- `_terraform.tf` — Terraform-Version, Provider, S3-Backend
- `_providers.tf` — Alle Provider für das Projekt werden hier definiert
- `_variables.tf` — Variablen
- `_locals.tf` — gemeinsame Locals und Tags
- `_outputs.tf` — Outputs
- `example-s3-bucket.tf` — privater Beispiel-Bucket
- `environments/<env>.tfvars` — Variablen des Environments
- `environments/<env>.backend.tfvars` — Backend-Konfiguration
- `environments/<env>.secrets.tfvars` — optionale Secrets, nicht im Git
- `environments/<env>.tfplan` — Plan-Datei, nicht im Git
- `.github/workflows/terraform-commands.yml.template` — Kommentar-Workflow, inaktiv bis die Endung `.template` fehlt
- `.github/workflows/terraform-preview.yml.template` — Preview-Push, ebenfalls inaktiv
- `.github/actions/tf-run/` — gemeinsame Schritte für OIDC, Sperre und `scripts/tf`

`bucket`, `key` und `region` stehen in der Backend-tfvars. Der State-Key ist für alle Environments gleich (`terraform-aws-template/terraform.tfstate`). Die Trennung macht der Workspace, zum Beispiel `env:/prod/terraform-aws-template/terraform.tfstate`.

## State-Bucket bootstrapen

Der State-Bucket steht in `_terraform.tf` auskommentiert, mit dem Platzhalter `REPLACE_ME-tfstate`. Derselbe Platzhalter steht in den `*.backend.tfvars`.

1. In `_terraform.tf` den Block `backend "s3"` auskommentieren.
2. Die Ressource `aws_s3_bucket.tfstate` samt Versionierung, Verschlüsselung und Public-Access-Block einkommentieren und den Bucket-Namen setzen.
3. Mit lokalem State applyen.
4. Die Ressource wieder auskommentieren, das Backend aktivieren und `scripts/tf init` ausführen. Terraform fragt nach der Migration; alternativ `terraform init -migrate-state` mit derselben `-backend-config` wie das Skript.

Im normalen Apply bleibt die Ressource auskommentiert, damit nicht jedes Environment den gemeinsamen State-Bucket neu anlegen will.

Bucket-Namen in den `*.tfvars` beginnen mit `REPLACE_ME`. S3 lehnt Großbuchstaben ab, deshalb scheitert ein Apply, bis die Namen ersetzt sind.

## Preview-Environment

```bash
git checkout develop
git checkout -b preview/feature123
scripts/tf init
```

Fehlen die Dateien, kopiert `init` die Vorlagen nach `environments/preview-feature123.tfvars` und `environments/preview-feature123.backend.tfvars` und stoppt. Nach dem Anpassen der Werte `init` erneut ausführen, danach `plan` und `apply`.

Dieselben Dateien entstehen mit `scripts/tf -e preview-feature123 init`, auch von einem anderen Branch aus.
