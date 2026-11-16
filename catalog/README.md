# catalog

This directory holds the catalog of apps that SettleIn can install, one entry per app, along with the JSON Schema that describes an entry and the script that validates the catalog. [CONTRIBUTING.md](../CONTRIBUTING.md) explains how to add an entry, and [docs/catalog.md](../docs/catalog.md) lists the fields and the rules.

- `catalog.json` is the catalog. It holds the three test apps.
- `catalog.schema.json` is its JSON Schema.
- `validate.sh` checks the schema, then checks a catalog file against it.
- `fixtures/` holds test data with made-up values. `fixtures/invalid/` has one file per broken rule, and `fixtures/valid/` has a `perArch` example. They are not catalog entries.
