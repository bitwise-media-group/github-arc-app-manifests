# Working on the docs

This site is [Zensical](https://zensical.org), built with uv through the toolchain's python archetype. Its look comes
from the [flux-containers site](https://oss.bitwisemedia.uk/flux-containers/): the same `docs/stylesheets/extra.css`
tokens and header partials, with a landing page in `overrides/home.html`.

```sh
make serve        # http://localhost:8006, live reload for docs/ edits
make build        # render into site/
```

## Pages that embed live files

The module pages include each module's `README.md` verbatim with `--8<-- "modules/<name>/README.md"`, so the
terraform-docs input and output tables are always the committed ones. Edit the module README, not the page. The
[Tasks](tasks.md) page embeds `tasks.toml` the same way.

Snippet paths resolve against `docs/` and the repository root (`base_path` in `zensical.toml`). `pymdownx.snippets` runs
with `check_paths`, so a page that includes a file that doesn't exist fails the build loudly.

## The landing page

`overrides/home.html` renders the home page. Its module cards are read from the "Modules" nav section in
`zensical.toml`, and each card's blurb from that page's `description` front matter, so adding a module page to the nav
is all the landing needs.

## Linting

Prose under `docs/` follows the house prettier and markdownlint rules (`make lint`). `docs/.markdownlint.yaml` relaxes
the fenced-code rule, because admonition and tab bodies need indentation. `site/` is excluded.

## Publishing

The release workflow's docs job builds the site at each release tag and deploys it to GitHub Pages at
<https://oss.bitwisemedia.uk/github-arc-app-manifests/>. CI builds it on every pull request (`mise run build`), so a broken
page fails the PR. Pages must be set to **Settings → Pages → Source → GitHub Actions**.
