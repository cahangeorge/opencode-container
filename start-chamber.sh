#!/bin/bash
# Start OpenCode serve and OpenChamber in the same container
# Used when running with --chamber flag

set -e

echo "Starting OpenCode + OpenChamber..."
echo "  OpenCode serve: http://0.0.0.0:4096"
echo "  OpenChamber UI: http://0.0.0.0:3000"

# Run supervisor which manages both processes
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
