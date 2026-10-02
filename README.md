# Terraform AWS Template

Ein Environment ist immer genau ein Terraform-Workspace. CI leitet das Environment aus dem Git-Branch ab. Lokal kann es mit `-e` oder `--env` gesetzt werden.

## Branch und Workspace

| Branch | Workspace und Dateiname |
| --- | --- |
| `main` | `prod` |
| `develop` | `dev` |
| `staging` | `staging` |
| `preview/<name>` | `preview-<name>` |

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

`-e` und `--env` sind gleichwertig und stehen vor dem Subcommand. Weicht der Name vom Branch ab, schreibt das Skript einen Hinweis auf stderr und arbeitet weiter. Die Pipeline setzt das Flag nicht.

`plan` schreibt `environments/<env>.tfplan`. `apply` wendet nur diese Datei an und löscht sie danach. Liegt keine Plan-Datei, bricht `apply` ab.

`environments/<env>.secrets.tfvars` wird automatisch mitgegeben, sobald die Datei existiert. Sie ist gitignored. Eine Vorlage liegt unter `environments/secrets.tfvars.example`.

## Dateien

- `_terraform.tf` — Terraform-Version, Provider, S3-Backend
- `_providers.tf` — AWS-Provider
- `_variables.tf` — Variablen
- `_locals.tf` — gemeinsame Locals und Tags
- `_outputs.tf` — Outputs
- `example.tf` — privater Beispiel-Bucket
- `environments/<env>.tfvars` — Variablen des Environments
- `environments/<env>.backend.tfvars` — Backend-Konfiguration
- `environments/<env>.secrets.tfvars` — optionale Secrets, nicht im Git
- `environments/<env>.tfplan` — Plan-Datei, nicht im Git

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
