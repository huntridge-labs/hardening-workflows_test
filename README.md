# Argus Test Suite

Comprehensive test suite for [huntridge-labs/argus](https://github.com/huntridge-labs/argus) — validates the container security scanning composite actions, reusable workflows, and the full scanner ecosystem.

## What's Being Tested

| Component | Purpose |
|-----------|---------|
| `scanner-container` | Composite action: runs trivy, grype, syft on a single image |
| `scanner-container-summary` | Composite action: combines parallel scan results, deduplicates CVEs |
| `parse-container-config` | Composite action: generates matrix from `container-config.yml` |
| `container-scan.yml` | Thin wrapper workflow: discover (find Dockerfiles) or remote (scan existing images) |
| `infrastructure-scan.yml` | Reusable workflow for trivy-iac + checkov |
| `container-scan-from-config.yml` | Reusable workflow for config-driven multi-container scanning |
| Scanner unit tests | All scanner parsers: checkov, clamav, codeql, opengrep, trivy-iac, zap |
| SCN detector | Significant Change Notification detector: AI classifier, diff helpers, report generation |

## Dashboard

Test results are published to GitHub Pages with each run, showing:
- Current test status and pass rate
- Category breakdown (unit, remote, discover, actions, combination, scn, regression)
- Historical run data (last 20 runs)
- The exact commit SHA of Argus being tested

## Testing Feature Branches

You can test an Argus feature branch before merging to main:

```bash
# Test a feature branch (unit + action tests use the custom ref)
gh workflow run test-suite.yml -f argus_ref=feat/my-feature

# Test only unit tests against a branch
gh workflow run test-suite.yml -f scope=unit -f argus_ref=feat/my-feature

# Test only direct action tests against a branch
gh workflow run test-suite.yml -f scope=actions -f argus_ref=feat/my-feature
```

**Scope of feature branch testing:**
- **Unit tests (U1-U5):** Full support — checkout argus at the specified ref and run pytest
- **Direct action tests (A1-A5):** Full support — checkout argus at the specified ref and use local action paths
- **Remote/Discover/Combination tests:** Always test `@main` — GitHub Actions requires static refs for reusable workflow `uses:` directives
- **Regression tests:** I2 uses the custom ref; I1 always tests `@main`

## Execution Path

```mermaid
flowchart TD
    A[container-scan.yml] --> B{scan_mode?}

    B -->|discover| C[discover-containers job]
    C --> C1["find Dockerfile* in repo"]
    C1 --> C2{Dockerfiles found?}
    C2 -->|no| C3[Skip - no containers]
    C2 -->|yes| C4["build-and-scan job (matrix)"]

    C4 --> D[docker build]
    D --> D1{Build success?}
    D1 -->|no| D2["continue-on-error → summary"]
    D1 -->|yes| E

    B -->|remote| F{registry_username?}
    F -->|yes| F1[docker login] --> G[docker pull] --> E
    F -->|no| G

    E[scanner-container action]
    E --> E1[validate inputs]
    E1 --> E2[get-job-id for unique artifacts]
    E2 --> E3{scanners input}

    E3 -->|contains syft| S1["anchore/sbom-action<br/>(CycloneDX + SPDX)"]
    E3 -->|contains trivy| T1{github.com?}
    T1 -->|yes| T2["aquasecurity/trivy-action<br/>(JSON + SARIF + Table)"]
    T1 -->|GHES| T3["curl install trivy<br/>trivy CLI direct"]
    E3 -->|contains grype| G1["anchore/scan-action<br/>(JSON + SARIF)"]

    S1 --> SEV
    T2 --> SEV
    T3 --> SEV
    G1 --> SEV

    SEV[severity-check]
    SEV --> SEV1["extract CVE IDs from trivy + grype"]
    SEV1 --> SEV2["deduplicate across scanners"]
    SEV2 --> SEV3{fail_on_severity?}
    SEV3 -->|none| PASS[scan_status=pass]
    SEV3 -->|critical/high/medium/low| SEV4{"vulns >= threshold?"}
    SEV4 -->|yes| SEV5{allow_failure?}
    SEV5 -->|true| PASS
    SEV5 -->|false| FAIL["exit 1"]
    SEV4 -->|no| PASS

    PASS --> ART[organize + upload artifacts]
    FAIL --> ART

    ART --> SUM[container-scan-summary job]
    D2 --> SUM

    SUM --> SUM1["download all scan artifacts"]
    SUM1 --> SUM2["map artifacts to containers"]
    SUM2 --> SUM3["deduplicate CVEs per container"]
    SUM3 --> SUM4["generate combined summary"]
    SUM4 --> SUM5{"PR context?"}
    SUM5 -->|yes| SUM6["post PR comment"]
    SUM5 -->|no| SUM7["step summary only"]
```

## Test Matrix (68 tests)

### Unit Tests — `test-unit.yml`

| # | Test | Validates |
|---|------|-----------|
| U1 | parse-container-config | Config parsing, schema validation, matrix generation (Python/pytest) |
| U2 | scanner-container | Trivy parser, Grype parser, summary generation (Python/pytest) |
| U3 | other scanner tests | Checkov, ClamAV, CodeQL, OpenGrep, Trivy-IaC, ZAP parsers (Python/pytest) |
| U4 | scn-detector tests | SCN detector AI classifier, diff helpers, report generation (Python/pytest) |
| U5 | GHES static analysis | No hardcoded github.com URLs in action logic |

### Remote Mode Tests — `test-remote.yml`

| # | Test | Image | Scanners | Severity | allow_failure | Expected | Category |
|---|------|-------|----------|----------|---------------|----------|----------|
| R1 | remote-vuln-all-scanners | nginx:1.19.0 | trivy,grype,syft | none | false | PASS, vulns found | TP-detect |
| R2 | remote-clean-image | distroless/static-debian12 | trivy,grype | none | false | PASS, no findings | TN-detect |
| R3 | remote-trivy-only | alpine:3.18 | trivy | none | false | PASS, trivy only | scanner isolation |
| R4 | remote-grype-only | alpine:3.18 | grype | none | false | PASS, grype only | scanner isolation |
| R5 | remote-syft-only | alpine:3.18 | syft | none | false | PASS, SBOM only | scanner isolation |
| R6 | remote-fail-critical | nginx:1.19.0 | trivy,grype | critical | false | PASS (1) | TP-threshold |
| R7 | remote-pass-none | nginx:1.19.0 | trivy,grype | none | false | PASS despite vulns | TN-threshold |
| R8 | remote-allow-failure | nginx:1.19.0 | trivy | high | true | PASS (bypassed) | allow_failure |
| R9 | remote-bad-image | nonexistent/nosuchimage:v0 | trivy | none | false | Graceful error | error handling |
| R10 | remote-clean-strict | distroless/static-debian12 | trivy,grype | low | false | PASS | TN-threshold |
| R11 | remote-threshold-precision | alpine:3.18 | trivy,grype | critical | false | PASS (no criticals) | TN-precision |
| R12 | remote-dedup-validation | nginx:1.19.0 | trivy,grype | none | false | PASS + dedup verified | dedup logic |

### Discover Mode Tests — `test-discover.yml`

| # | Test | Scanners | Severity | Expected |
|---|------|----------|----------|----------|
| D1 | discover-mixed | trivy,grype | none | Finds good + vulnerable, broken build skipped |
| D2 | discover-trivy-only | trivy | none | Single scanner in discover mode |
| D3 | discover-severity | trivy,grype | critical | Threshold applied to discovered containers |

### Direct Action Tests — `test-actions-direct.yml`

| # | Test | Config | Expected |
|---|------|--------|----------|
| A1 | config-single-public | tests/configs/single-public.yml | 1 entry, has_containers=true |
| A2 | config-multi-container | tests/configs/multi-container.yml | 3 entries, 6+ scan_matrix entries |
| A3 | config-structured-image | tests/configs/structured-image.yml | Image ref built from components |
| A4 | config-all-options | tests/configs/all-options.yml | Full schema: registry, auth, all flags |
| A5 | config-invalid-duplicate | tests/configs/invalid-duplicate.yml | Duplicate names rejected |

### Combination Tests — `test-combination.yml`

Pairwise coverage tests filling gaps in the parameter space (mode x scanners x severity x allow_failure x image).

| # | Mode | Scanners | Severity | allow_failure | Image | Gap filled |
|---|------|----------|----------|---------------|-------|------------|
| C1 | remote | trivy+syft | none | false | nginx:1.19.0 | Scanner pair TS |
| C2 | remote | grype+syft | none | false | nginx:1.19.0 | Scanner pair GS |
| C3 | remote | trivy | medium | false | nginx:1.19.0 | `medium` severity |
| C4 | remote | grype | high | false | nginx:1.19.0 | `high` standalone |
| C5 | remote | grype | critical | false | nginx:1.19.0 | Grype threshold |
| C6 | remote | trivy | low | false | alpine:3.18 | `low` on low-vuln |
| C7 | remote | trivy+grype | high | false | alpine:3.18 | `high` TN precision |
| C8 | remote | trivy+grype | critical | true | nginx:1.19.0 | Multi-scanner + allow_failure |
| C9 | remote | grype | low | true | distroless | grype + allow_failure + clean |
| C10 | discover | trivy | medium | true | — | discover + allow_failure |
| C11 | discover | grype | low | false | — | discover + grype only |
| C12 | discover | trivy+grype+syft | none | false | — | discover + all scanners |
| C13 | discover | syft | high | false | — | discover + syft only |
| C14 | remote | trivy+grype+syft | high | true | alpine:3.18 | All scanners + threshold + allow |
| C15 | remote | trivy+grype | medium | false | distroless | medium TN on clean |

### SCN Detector Tests — `test-scn-detector.yml` (on-demand only)

Validates the [argus scn-detector](https://github.com/huntridge-labs/argus) action — classifies IaC changes into FedRAMP SCN categories. Run with `scope=scn`.

| # | Test | IaC Format | Expected Category | Validates |
|---|------|-----------|-------------------|-----------|
| S1 | routine-tags | Terraform | ROUTINE | `tags.*` pattern match |
| S2 | routine-description | Terraform | ROUTINE | `description` pattern match |
| S3 | adaptive-instance-type | Terraform (modify) | ADAPTIVE | `instance_type` modify rule |
| S4 | adaptive-iam-attachment | Terraform | ADAPTIVE | `aws_iam_policy_attachment` create |
| S5 | transformative-iam-role | Terraform | TRANSFORMATIVE | `aws_iam_role` create |
| S6 | transformative-db-engine | Terraform (modify) | TRANSFORMATIVE | `aws_rds_*` engine modify |
| S7 | impact-encryption | Terraform (modify) | IMPACT | Encryption removal |
| S8 | impact-public-sg | Terraform | IMPACT | `0.0.0.0/0` ingress pattern |
| S9 | impact-iam-user | Terraform | IMPACT | `aws_iam_user` create |
| S10 | kubernetes-detection | Kubernetes | detected | K8s YAML format detection |
| S11 | cloudformation-detection | CloudFormation | detected | CFN YAML format detection |
| S12 | no-iac-changes | non-IaC | NONE | `has_changes=false` |
| S13 | fail-on-impact | Terraform | IMPACT (fails) | `fail_on_category=impact` enforcement |
| S14 | fail-on-adaptive | Terraform | ADAPTIVE (fails) | `fail_on_category=adaptive` enforcement |
| S15 | mixed-multi-category | Terraform (multi-file) | IMPACT | Highest category wins |
| S16 | dry-run-issues | Terraform | ADAPTIVE | Dry-run mode: issue payloads without API calls |
| S17 | manual-review | Terraform | MANUAL_REVIEW | Unmatched resource triggers manual review |
| S18-S25 | additional coverage | Various | Various | Delete ops, custom profiles, multi-resource, AI fallback |

### Regression Tests — `test-suite.yml`

| # | Test | Validates |
|---|------|-----------|
| I1 | infrastructure-scan | trivy-iac + checkov still work |
| I2 | no-hardcoded-urls | No github.com URLs in action shell scripts |
| I3 | config-driven-scan | container-scan-from-config.yml reusable workflow still works |

## Quick Start

```bash
# Runs automatically on every push to main (concurrency: 1)
# Also runs weekly on Sunday 9am UTC

# Run full suite manually
gh workflow run test-suite.yml

# Run specific scope
gh workflow run test-suite.yml -f scope=unit
gh workflow run test-suite.yml -f scope=remote
gh workflow run test-suite.yml -f scope=discover
gh workflow run test-suite.yml -f scope=actions
gh workflow run test-suite.yml -f scope=combination
gh workflow run test-suite.yml -f scope=scn

# Test an argus feature branch
gh workflow run test-suite.yml -f argus_ref=feat/my-feature

# Monitor
gh run watch
```

## Repository Structure

```
.github/workflows/
  test-suite.yml             Orchestrator (push + dispatch + weekly)
  test-remote.yml            12 remote mode tests
  test-discover.yml          3 discover mode tests
  test-actions-direct.yml    5 composite action tests
  test-combination.yml       15 pairwise combination tests
  test-scn-detector.yml      25 SCN detector tests (on-demand)
  test-unit.yml              5 unit tests (Python/pytest)

.github/scripts/
  generate-dashboard.sh      Dashboard HTML generator

tests/
  dockerfiles/
    good/Dockerfile           FROM alpine:3.18
    vulnerable/Dockerfile     FROM node:14-slim (known CVEs)
    broken/Dockerfile         Invalid (tests error handling)
  configs/
    single-public.yml         1 public container
    multi-container.yml       3 containers, mixed scanners
    structured-image.yml      Structured image object format
    all-options.yml           Every config field populated
    invalid-duplicate.yml     Duplicate names (schema error)
    custom-scn-profile.yml    Custom SCN classification profile
```

## TP/TN Coverage Matrix

|  | Scanner finds vulns | Scanner finds nothing |
|--|--------------------|-----------------------|
| **Image IS vulnerable** | R1, R6, R8, R12 (True Positive) | Bug — caught by R1 assertion |
| **Image is clean** | Bug — caught by R2/R10 assertion | R2, R10 (True Negative) |

|  | Threshold triggers failure | Threshold allows pass |
|--|---------------------------|-----------------------|
| **Vulns meet threshold** | C3, C4, C5 internally (1) | Bug — caught by C3/C4/C5 |
| **Vulns below threshold** | Bug — caught by R11/C7 | R7, R10, R11, C7 (True Negative) |

## Pairwise Coverage

After the C-series combination tests, parameter pair coverage is:

| Parameter Pair | Coverage |
|---------------|----------|
| mode x scanners | 14/14 (100%) |
| mode x severity | 10/10 (100%) |
| mode x allow_failure | 4/4 (100%) |
| severity x allow_failure | 8/10 (80%) |
| scanners x severity | 19/35 (54%) |

Remaining gaps are syft-involving severity combos (meaningless — syft is SBOM-only, doesn't do vulnerability scanning).

**(1)** `container-scan.yml` uses `continue-on-error: true` on scan jobs, so the reusable workflow always returns `success` even when the `scanner-container` action triggers a severity failure internally. The threshold enforcement happens inside the action (`exit 1`), but the wrapper absorbs it. Tests validate the workflow completed; the severity check ran correctly inside.
