# Plan: Automated devhubdb setup via GitHub integration

## Context

Today, setting up the CFO requires manual steps:
1. `gh repo create` the devhubdb repo
2. Initialize with `fuzzing/data.json` = `[]`
3. Generate a PAT with `repo` scope
4. Export `DEVHUBDB_PAT` on the CFO machine

This is 4 steps that every framework user must do manually, correctly,
in the right order. If any step is wrong, the CFO silently fails to
push seeds. No web framework should require users to set up git repos
and PATs manually.

## Design

`tiger-web setup` creates the devhubdb repo and configures access
automatically:

```bash
tiger-web setup --github
```

This:
1. Authenticates via `gh auth` (already installed for most developers)
2. Creates `<user>/<project>-devhubdb` repo (public)
3. Initializes with `fuzzing/data.json` = `[]` and `fuzzing/logs/.gitkeep`
4. Creates a fine-grained PAT scoped to the devhubdb repo only
   (Contents: read+write) — or uses a GitHub App installation token
5. Stores the token in the project's `.env` or GitHub Actions secrets
6. Updates `cfo_supervisor.sh` with the correct repo URL

### GitHub App (preferred for teams)

A GitHub App installed on the user's account:
- Creates the devhubdb repo on install
- Provides installation tokens (no PAT management)
- The CFO uses the app token to push seeds
- Revocation is one-click (uninstall the app)

### CLI setup (for solo developers)

No GitHub App needed:
```bash
tiger-web setup --github
# Runs: gh repo create, gh api to create PAT, writes .env
```

Uses `gh` CLI which the developer already has. The PAT is scoped
to the devhubdb repo only.

## What this enables

- `tiger-web fuzz` + `tiger-web setup --github` = complete fuzzing
  infrastructure in 2 commands
- No manual repo creation, no manual PAT generation
- The framework handles the plumbing, the user writes handlers

## Implementation

### Phase 1: CLI setup command
- Add `setup` subcommand to `tiger-web` CLI
- `--github` flag triggers devhubdb creation
- Uses `gh` CLI for repo creation and PAT generation
- Writes `DEVHUBDB_PAT` to `.env` (gitignored)
- Prints the CFO start command

### Phase 2: GitHub App
- Register a GitHub App for tiger-web
- Installation creates devhubdb repo automatically
- App provides installation tokens for CFO
- No PAT management for the user

### Phase 3: GitHub Actions integration
- `tiger-web setup --github` also:
  - Adds `DEVHUBDB_PAT` as a repository secret
  - Creates `.github/workflows/ci.yml` if it doesn't exist
  - Adds a `devhub` job that runs on main (deploy dashboard)

## Relationship to framework-fuzzer plan

The setup command is the onboarding step. The experience:
```bash
tiger-web setup --github    # one-time: creates devhubdb, configures tokens
tiger-web fuzz              # run fuzzers locally
tiger-web fuzz --cfo        # start continuous 24/7 fuzzing
```

Three commands from zero to continuous fuzzing with seed persistence.
