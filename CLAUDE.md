# ScrollReader — repo notes

## Every change ships a release

Any change to the addon (`ScrollReader.lua`, `.toc`, `Bindings.xml`) must bump the version and build the release set in `releases/v<version>/`, committed and pushed with the change:

1. Bump `## Version:` in `ScrollReader.toc` and `VERSION` in `ScrollReader.lua`; bump `**Version:**` in `MANUAL.md`.
2. Add a `CHANGELOG.md` entry; update `MANUAL.md` and `NUTSHELL.md` for user-facing changes.
3. Run `python3 tools/build_release.py` (needs `pip install reportlab`). It writes:
   - `ScrollReader-v<version>.zip` (the `ScrollReader/` addon folder)
   - `ScrollReader Changelog.txt`
   - `ScrollReader Guide.pdf` (manual + full changelog)
   - `ScrollReader in a nutshell.pdf` (from `NUTSHELL.md`)
4. Never edit old release folders.
