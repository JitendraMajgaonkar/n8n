#!/bin/bash
set -e

echo "=================================="
echo "n8n Azure Deployment Script"
echo "Ultra Budget Setup - B1s VM"
echo "=================================="
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    echo "❌ Please do not run this script as root"
    exit 1
fi

# Update system
echo "📦 Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install required packages
echo "📦 Installing dependencies..."
sudo apt install -y curl apt-transport-https ca-certificates software-properties-common git

# Install Docker
echo "🐳 Installing Docker..."
if ! command -v docker &> /dev/null; then
    # Add Docker GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Add current user to docker group
    sudo usermod -aG docker $USER
    echo "✅ Docker installed successfully"
else
    echo "✅ Docker is already installed"
fi

# Verify Docker Compose
if ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose plugin not found. Installing..."
    sudo apt install -y docker-compose-plugin
fi

# Create n8n directory
echo "📁 Creating n8n directory..."
mkdir -p ~/n8n
cd ~/n8n

# Generate secure passwords
echo "🔐 Generating secure passwords..."
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
N8N_USER_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)

# Create .env file
echo "📝 Creating environment file..."
cat > .env << EOF
# Database Configuration
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_USER=n8n
POSTGRES_DB=n8n

# n8n Configuration
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=$N8N_USER_PASSWORD
N8N_PORT=5678
WEBHOOK_URL=http://$(curl -s ifconfig.me):5678
GENERIC_TIMEZONE=Europe/Amsterdam

# Database Connection
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=$POSTGRES_PASSWORD

# Redis Configuration (optional - uncomment to enable queue mode)
# EXECUTIONS_MODE=queue
# QUEUE_BULL_REDIS_HOST=redis
# QUEUE_BULL_REDIS_PORT=6379
EOF

# Create docker-compose.yml
echo "📝 Creating docker-compose.yml..."
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  postgres:
    image: postgres:16-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h localhost -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

  redis:
    image: redis:7-alpine
    container_name: n8n-redis
    restart: unless-stopped
    command: redis-server --maxmemory 64mb --maxmemory-policy allkeys-lru
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_BASIC_AUTH_ACTIVE=${N8N_BASIC_AUTH_ACTIVE}
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - N8N_PORT=${N8N_PORT}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE:-regular}
      - QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=${QUEUE_BULL_REDIS_PORT}
    volumes:
      - n8n-data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - n8n-network

volumes:
  postgres-data:
  redis-data:
  n8n-data:

networks:
  n8n-network:
    driver: bridge
EOF

# Create backup script
echo "📝 Creating backup script..."
cat > backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="$HOME/n8n-backups"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "Creating backup: $DATE"

# Backup PostgreSQL database
docker exec n8n-postgres pg_dump -U n8n n8n | gzip > "$BACKUP_DIR/n8n_db_$DATE.sql.gz"

# Backup n8n data directory
docker run --rm -v n8n_n8n-data:/data -v "$BACKUP_DIR":/backup alpine tar czf /backup/n8n_data_$DATE.tar.gz -C /data .

# Keep only last 7 backups
cd "$BACKUP_DIR"
ls -t n8n_db_*.sql.gz | tail -n +8 | xargs -r rm
ls -t n8n_data_*.tar.gz | tail -n +8 | xargs -r rm

echo "✅ Backup completed: $DATE"
EOF

chmod +x backup.sh

# Configure firewall
echo "🔥 Configuring firewall..."
if command -v ufw &> /dev/null; then
    sudo ufw allow 5678/tcp
    sudo ufw --force enable
    echo "✅ Firewall configured (port 5678 opened)"
fi

# Start services
echo "🚀 Starting n8n services..."
docker compose up -d

# Wait for services to be ready
echo "⏳ Waiting for services to start (30 seconds)..."
sleep 30

# Show status
echo ""
echo "=================================="
echo "✅ Deployment Complete!"
echo "=================================="
echo ""
echo "📊 Service Status:"
docker compose ps
echo ""
echo "🔐 Your Credentials:"
echo "   Username: admin"
echo "   Password: $N8N_USER_PASSWORD"
echo ""
echo "🌐 Access n8n at:"
echo "   http://$(curl -s ifconfig.me):5678"
echo ""
echo "💾 IMPORTANT - Save these credentials:"
echo "   PostgreSQL Password: $POSTGRES_PASSWORD"
echo "   Encryption Key: $N8N_ENCRYPTION_KEY"
echo "   n8n Password: $N8N_USER_PASSWORD"
echo ""
echo "📝 Credentials saved in: ~/n8n/.env"
echo "💾 Backup script created: ~/n8n/backup.sh"
echo ""
echo "📖 Useful Commands:"
echo "   View logs: cd ~/n8n && docker compose logs -f"
echo "   Restart: cd ~/n8n && docker compose restart"
echo "   Stop: cd ~/n8n && docker compose down"
echo "   Backup: cd ~/n8n && ./backup.sh"
echo ""
echo "⚠️  IMPORTANT: Open port 5678 in Azure NSG!"
echo "=================================="
