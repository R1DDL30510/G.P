# Configuration and Artifact Management

## Environment-specific configuration
- `config/development.json` for development settings
- `config/production.json` for production settings

Secrets such as passwords should be supplied through environment variables or secret
vaults rather than committed directly to these files.

## Schema validation
Configuration files are validated against `config/schema.json` using
`scripts/validate_config.py`:

```bash
python scripts/validate_config.py config/development.json
```

## Configuration control
Treat configuration as code: keep files under version control, modularize large
files, and document each option. Changes should be tracked through pull requests
and reviewed for compliance. A CMDB (Configuration Management Database) can track
which configuration items apply to each environment.

## Artifact repository maintenance
Artifacts should be stored in a centralized repository with retention policies.
`scripts/deduplicate_artifacts.py` scans a JSON listing of artifacts for duplicate
identifiers and rewrites the file without the duplicates:

```bash
python scripts/deduplicate_artifacts.py artifacts/repository.json
```

## Continuous hygiene
Regularly inventory configuration and artifact data, categorize items, remove
redundant records, and monitor continuously to keep the environment tidy.
