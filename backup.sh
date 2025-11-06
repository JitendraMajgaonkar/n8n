#!/bin/bash
set -e

BACKUP_DIR="$HOME/n8n-backups"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "🔄 Creating backup: $DATE"

# Backup PostgreSQL database
echo "📦 Backing up PostgreSQL database..."
docker exec n8n-postgres pg_dump -U n8n n8n | gzip > "$BACKUP_DIR/n8n_db_$DATE.sql.gz"

# Backup n8n data directory (workflows, credentials, settings)
echo "📦 Backing up n8n data directory..."
docker run --rm \
  -v n8n_n8n-data:/data \
  -v "$BACKUP_DIR":/backup \
  alpine tar czf /backup/n8n_data_$DATE.tar.gz -C /data .

# Backup environment file
echo "📦 Backing up environment configuration..."
cp ~/n8n/.env "$BACKUP_DIR/env_$DATE.backup"

# Calculate backup sizes
DB_SIZE=$(du -h "$BACKUP_DIR/n8n_db_$DATE.sql.gz" | cut -f1)
DATA_SIZE=$(du -h "$BACKUP_DIR/n8n_data_$DATE.tar.gz" | cut -f1)

echo "✅ Database backup: $DB_SIZE"
echo "✅ Data backup: $DATA_SIZE"

# Keep only last 7 backups
echo "🧹 Cleaning old backups (keeping last 7)..."
cd "$BACKUP_DIR"
ls -t n8n_db_*.sql.gz | tail -n +8 | xargs -r rm
ls -t n8n_data_*.tar.gz | tail -n +8 | xargs -r rm
ls -t env_*.backup | tail -n +8 | xargs -r rm

# Show remaining backups
echo ""
echo "📊 Available backups:"
ls -lh "$BACKUP_DIR" | grep -E "(n8n_db_|n8n_data_|env_)" | awk '{print $9, "-", $5}'

echo ""
echo "✅ Backup completed successfully: $DATE"
echo "📁 Backup location: $BACKUP_DIR"

# Optional: Upload to Azure Blob Storage
# Uncomment and configure if you want cloud backups
# az storage blob upload --account-name YOUR_STORAGE --container-name backups --file "$BACKUP_DIR/n8n_db_$DATE.sql.gz"
