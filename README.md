# validate-otel-config

Fail a build when an OpenTelemetry Collector config is invalid — checked against the **real
collector binary** for the version you name, not a schema emulation.

```yaml
- uses: OllyStack/validate-otel-config@v1
  with:
    config: otel-config.yaml
    version: "0.157.0"
```

A failure is annotated on the offending file in the PR diff, with the collector's own message:

> ❌ `otel-config.yaml` — invalid for `otel/opentelemetry-collector-contrib:0.157.0`
> `Error: 'receivers' unknown type: "signalfx"`

## Pre-flight an upgrade

The reason this exists rather than `otelcol validate` in a container: you can ask what the *next*
version does to a config you have not deployed yet.

```yaml
- uses: OllyStack/validate-otel-config@v1
  with:
    config: otel-config.yaml
    version: "0.155.0"      # what you run
    upgrade-to: "0.157.0"   # what you are moving to
```

The job summary gets the list of what changes — component removed, field renamed — and the migrated
config with every automatic fix applied. Advisory by default; `fail-on-upgrade: true` gates on it.

## Inputs

| Input | Default | |
| --- | --- | --- |
| `config` | `otel-config.yaml` | File(s); newline/space separated, globs expanded. A pattern matching nothing fails. |
| `version` | distro default | Any published collector version. |
| `distro` | `otelcol-contrib` | `otelcol-core`, `managed`, `adot`, `splunk`, `edot`. |
| `upgrade-to` | — | Also report what breaks moving there. |
| `fail-on-upgrade` | `false` | Fail when the upgrade needs a human decision. |
| `fail-on-unavailable` | `true` | See below. |
| `feature-gates` | — | Comma-separated gates passed to `validate`. |
| `api-url` | `https://www.ollystack.com` | Point at a self-hosted portal. |

Outputs: `valid` (`"true"`/`"false"`) and `report` (path to the full JSON).

## Why `fail-on-unavailable` defaults to true

If the service cannot produce a verdict, this step **fails**. A validation step that goes green
because the validator was unreachable is worse than no step at all: it is a green tick that means
nothing, on the check people trust to catch exactly this. Set it to `false` if you would rather the
build continue.

Deprecated semantic-convention attribute names and guardrail findings are reported as **warnings**
and never fail the build — a step that fails on style is a step people delete.

## Notes

- Your config is not stored or logged by the service ([docs](https://www.ollystack.com/docs)).
- The public endpoint is rate limited; the action retries once on a 429.
- Needs `jq`, which GitHub-hosted runners already have.

## Development

`bash test_action.sh` runs the suite against a stub API — offline, in seconds. It asserts which
cases fail the build, which is the only thing an action is really judged on.

The action is a thin client: it posts your config to the validation API and shapes the result for
GitHub. The engine lives on the service side (`https://www.ollystack.com/api/v1/validate`), so the
action does not need updating when a new collector version is released.
