#!/bin/bash
set -e

# Read PostgreSQL password from secret file if it exists
if [ -f /run/secrets/postgres_password ]; then
    export DB_PASSWORD=$(cat /run/secrets/postgres_password)
fi

# Execute the main command
exec "$@"

