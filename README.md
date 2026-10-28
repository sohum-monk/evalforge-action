# NinjaEval change test: GitHub Action

Tests the change in a pull request against production with NinjaEval. It then:
- posts the verdict (ready or blocked) on the PR, with each regressed case, its cause and the suggested fix;
- writes the full report to the job summary;
- **fails the job when the release gate says blocked**.

```yaml
# .github/workflows/evalforge.yml
name: NinjaEval
on:
  pull_request:
    paths: ["prompts/**", "src/**"]        # only when the AI's behaviour can change
permissions:
  contents: read
  pull-requests: write                     # for the PR comment
jobs:
  change-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: sohum-monk/evalforge-action@v1
        with:
          api-key: ${{ secrets.EVALFORGE_API_KEY }}
          project: my-bot
          prompt-file: prompts/system.md   # optional: the prompt as changed in this PR
          # model: openai/gpt-oss-120b     # optional: test a different model
```

**Stage gates (smoke before merge, full suite before release).** Set up a stage in NinjaEval (*Scoring & gate →
Stage gates*, e.g. **smoke** = the cases tagged `smoke`, at least 80% pass), then run it on every pull request and the
full suite where you release:

```yaml
      - uses: sohum-monk/evalforge-action@v1
        with:
          api-key: ${{ secrets.EVALFORGE_API_KEY }}
          project: my-bot
          prompt-file: prompts/system.md
          stage: smoke                       # quick: only the smoke cases; blocks the PR if the stage is blocked
```

A stage run comments "smoke stage passed / blocked" (its own comment, separate from the full run's) and fails the job
when blocked, but it never ships: only a full run's verdict is a release decision.

**Setup (2 minutes)**
1. In [NinjaEval](https://ninjaeval.com), open your workspace, go to **⚙ Workspace & API keys**, and create a key.
2. In GitHub, open your repo → Settings → Secrets and variables → Actions, and add it as `EVALFORGE_API_KEY`.
3. Add the workflow above.

**What gets tested:** NinjaEval copies your production version, then applies what this PR changes:
- the prompt from `prompt-file`;
- `model` / `provider`;
- the commit SHA.

In **Your endpoint** mode, point a preview deployment at your endpoint, or test the commit behind the same URL.

| Input | Default | Meaning |
|---|---|---|
| `api-key` | (required) | Workspace API key |
| `project` | (required) | NinjaEval project id |
| `prompt-file` | none | System prompt file for this change |
| `model`, `provider` | production's | Model or provider to test |
| `trials` | `1` | Runs per case; the majority counts (use 3 for releases) |
| `fail-on-blocked` | `true` | Fail the job when blocked |
| `comment` | `true` | Post or update one PR comment |
| `timeout-minutes` | `20` | Stop waiting after this |

**Outputs:** `verdict` (`ready` or `blocked`), `test-id`, `report-url`.

Requires `curl`, `jq` and `gh`. All three are preinstalled on GitHub-hosted runners.
