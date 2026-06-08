# Citum for LuaLaTeX

`citum` is a LuaLaTeX package that formats citations and bibliographies with
the Citum citation engine.

The package is pipe-only: it does not load a Rust shared library and has no FFI
mode. LuaLaTeX records citation commands during the document pass, sends one
`format_document` JSON-RPC request to `citum-server`, and caches the rendered
result for the next LaTeX pass.

## Requirements

- LuaLaTeX
- `citum-server` on `PATH`, `CITUM_SERVER_PATH`, or the package option
  `server=/path/to/citum-server`

Install `citum-server` from the Citum core release:

```sh
curl -fsSL https://github.com/citum/citum-core/releases/latest/download/install.sh | CITUM_COMPONENTS=citum-server sh
```

## Usage

```latex
\usepackage[
  style=apa-7th,
  bibfile=refs.bib
]{citum}
```

Then cite normally:

```latex
As \textcite{harrington1891} observed, bibliographic method was contested
\cite[p.~42]{chen2017}.
```

Print a full bibliography:

```latex
\printcitumbibliography
```

Or split the bibliography by reference type:

```latex
\subsection*{Primary Sources}
\printcitumbibliography[type=manuscript]

\subsection*{Secondary Sources}
\printcitumbibliography[not-type=manuscript]
```

The split bibliography is server-side behavior. The Lua package sends
`bibliography_blocks` to `citum-server`; entries rendered in an earlier block
are assigned and do not repeat in later blocks.

## Package Options

| Option | Description |
| --- | --- |
| `style` | Citum style path or style file name, extension optional |
| `bibfile` | `.bib` or Citum YAML bibliography path, extension optional |
| `locale` | Optional BCP 47 locale tag |
| `server` | Optional explicit path to `citum-server` |
| `backend` | `pipe` for direct LuaLaTeX spawning, `external` for script-driven compilation |

## Citation Commands

- `\cite[loc]{key}`
- `\textcite[loc]{key}`
- `\cites{k1, k2}`
- `\textcites{k1, k2}`
- `\citestart` / `\citeitem[loc]{key}` / `\citeend`
- `\printcitumbibliography[filter]`
- `\printbibliography` as an alias
- `\addbibresource{refs.bib}` when `bibfile` is not supplied
- `\parencite`, `\autocite`, and `\footcite` as narrow biblatex-style aliases

Supported bibliography filters in v1:

- `type=manuscript`
- `not-type=manuscript`

The biblatex compatibility surface is command-level only. It is meant to reduce
migration friction for simple documents; it does not implement Biber, biblatex
sorting/options semantics, or automatic mapping of biblatex style names.

## Demo

```sh
scripts/citum-lualatex demo/citum-example.tex
```

The script defaults to the external backend, so LuaLaTeX does not need
`--shell-escape`. It runs LuaLaTeX, passes the generated request to
`citum-server`, and reruns LuaLaTeX with the cached result.

Point at a locally built server:

```sh
scripts/citum-lualatex demo/citum-example.tex --server /path/to/citum-core/target/release/citum-server
```

For direct LuaLaTeX spawning, opt in to shell escape:

```sh
scripts/citum-lualatex demo/citum-example.tex --shell-escape
```

## Repository Layout

| Path | Purpose |
| --- | --- |
| `tex/latex/citum/citum.sty` | LaTeX package |
| `lua/citum/citum.lua` | LuaLaTeX adapter |
| `lua/citum/citum_json.lua` | Vendored JSON fallback |
| `scripts/citum-lualatex` | General compile driver |
| `demo/` | Demo document, style, references |

## Status

This is a pre-CTAN package candidate. It is designed around TeX distribution
constraints by avoiding runtime shared-library loading, but it has not yet been
submitted to CTAN or TeX Live.
