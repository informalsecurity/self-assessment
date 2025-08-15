#!/bin/bash

# BloodHound Community Edition SSL/HTTPS Setup Script
# This script sets up SSL/TLS protection for BloodHound using multiple methods

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
BLOODHOUND_DIR="/opt/bloodhound"
NGINX_SITES="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
SSL_DIR="/etc/ssl/bloodhound"

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

# Display banner
echo -e "${PURPLE}"
cat << 'EOF'
  ____  _                 _ _   _                       _   
 |  _ \| |               | | | | |                     | |  
 | |_) | | ___   ___   __| | |_| | ___  _   _ _ __   __| |  
 |  _ <| |/ _ \ / _ \ / _` |  _  |/ _ \| | | | '_ \ / _` |  
 | |_) | | (_) | (_) | (_| | | | | (_) | |_| | | | | (_| |  
 |____/|_|\___/ \___/ \__,_\_| |_/\___/ \__,_|_| |_|\__,_|  
                                                           
            SSL/HTTPS Setup Utility                        
                                                           
EOF
echo -e "${NC}"

log "BloodHound SSL/HTTPS Setup Utility"

# Check if BloodHound is installed
if [ ! -d "$BLOODHOUND_DIR" ]; then
    error "BloodHound directory not found: $BLOODHOUND_DIR"
fi

# Main menu
echo ""
echo "Choose your SSL setup method:"
echo ""
echo "1) Nginx Reverse Proxy with Let's Encrypt (Recommended - Free SSL)"
echo "2) Nginx Reverse Proxy with Self-Signed Certificate (Quick Setup)"
echo "3) Configure BloodHound Native SSL (Direct SSL in BloodHound)"
echo "4) Nginx Proxy Manager (GUI-based management)"
echo "5) Remove SSL Configuration"
echo "6) Exit"
echo ""
read -p "Choose an option (1-6): " choice

case $choice in
    1)
        log "Setting up Nginx Reverse Proxy with Let's Encrypt..."
        
        # Install required packages
        log "Installing Nginx and Certbot..."
        apt update
        apt install -y nginx certbot python3-certbot-nginx
        
        # Get domain name
        read -p "Enter your domain name (e.g., bloodhound.example.com): " DOMAIN_NAME
        if [ -z "$DOMAIN_NAME" ]; then
            error "Domain name is required for Let's Encrypt"
        fi
        
        # Create Nginx configuration
        log "Creating Nginx configuration for $DOMAIN_NAME..."
        cat > "$NGINX_SITES/bloodhound-ssl" << EOF
# Redirect HTTP to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;
    return 301 https://\$server_name\$request_uri;
}

# HTTPS configuration
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME;

    # SSL Configuration (will be auto-configured by certbot)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Proxy to BloodHound
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        proxy_redirect off;
        
        # File upload limits (remove limits for large SharpHound files)
        client_max_body_size 0;
        client_body_timeout 300s;
        proxy_request_buffering off;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts for large uploads
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        proxy_buffering off;
    }

    # Optional: Proxy Neo4j browser (comment out if not needed)
    location /neo4j/ {
        proxy_pass http://127.0.0.1:7474/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Logging
    access_log /var/log/nginx/bloodhound_access.log;
    error_log /var/log/nginx/bloodhound_error.log;
}
EOF

        # Enable site
        ln -sf "$NGINX_SITES/bloodhound-ssl" "$NGINX_ENABLED/"
        
        # Remove default site if it exists
        rm -f "$NGINX_ENABLED/default"
        
        # Test nginx configuration
        nginx -t
        
        # Restart nginx
        systemctl restart nginx
        
        # Get SSL certificate
        log "Obtaining SSL certificate from Let's Encrypt..."
        echo "Note: Make sure your domain $DOMAIN_NAME points to this server's IP address"
        read -p "Press Enter when DNS is configured, or Ctrl+C to cancel..."
        
        certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "admin@$DOMAIN_NAME"
        
        # Configure BloodHound to bind to localhost only
        log "Securing BloodHound to localhost only..."
        cd "$BLOODHOUND_DIR"
        sed -i 's/BLOODHOUND_HOST=0.0.0.0/BLOODHOUND_HOST=127.0.0.1/' .env
        
        # Restart BloodHound
        docker-compose restart bloodhound
        
        # Update firewall
        log "Updating firewall rules..."
        ufw allow 'Nginx Full'
        ufw delete allow 8080/tcp 2>/dev/null || true
        
        log "✅ Let's Encrypt SSL setup complete!"
        echo "🌐 Access BloodHound at: https://$DOMAIN_NAME"
        echo "🔒 SSL certificate will auto-renew via certbot"
        ;;

    2)
        log "Setting up Nginx Reverse Proxy with Self-Signed Certificate..."
        
        # Install Nginx
        apt update
        apt install -y nginx openssl
        
        # Get server details
        read -p "Enter server name/IP (default: $(hostname -I | awk '{print $1}')): " SERVER_NAME
        SERVER_NAME=${SERVER_NAME:-$(hostname -I | awk '{print $1}')}
        
        # Create SSL directory
        mkdir -p "$SSL_DIR"
        
        # Generate self-signed certificate
        log "Generating self-signed SSL certificate..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SSL_DIR/bloodhound.key" \
            -out "$SSL_DIR/bloodhound.crt" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$SERVER_NAME"
        
        # Generate DH parameters
        log "Generating Diffie-Hellman parameters (this may take a while)..."
        openssl dhparam -out "$SSL_DIR/dhparam.pem" 2048
        
        # Create Nginx configuration
        log "Creating Nginx configuration..."
        cat > "$NGINX_SITES/bloodhound-ssl" << EOF
# Redirect HTTP to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME;
    return 301 https://\$server_name\$request_uri;
}

# HTTPS configuration
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $SERVER_NAME;

    # SSL Configuration
    ssl_certificate $SSL_DIR/bloodhound.crt;
    ssl_certificate_key $SSL_DIR/bloodhound.key;
    ssl_dhparam $SSL_DIR/dhparam.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_timeout 10m;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Proxy to BloodHound
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        proxy_redirect off;
        
        # File upload limits (remove limits for large SharpHound files)
        client_max_body_size 0;
        client_body_timeout 300s;
        proxy_request_buffering off;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts for large uploads
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        proxy_buffering off;
    }

    # Logging
    access_log /var/log/nginx/bloodhound_access.log;
    error_log /var/log/nginx/bloodhound_error.log;
}
EOF

        # Enable site
        ln -sf "$NGINX_SITES/bloodhound-ssl" "$NGINX_ENABLED/"
        rm -f "$NGINX_ENABLED/default"
        
        # Test and restart nginx
        nginx -t
        systemctl restart nginx
        
        # Configure BloodHound to bind to localhost only
        log "Securing BloodHound to localhost only..."
        cd "$BLOODHOUND_DIR"
        sed -i 's/BLOODHOUND_HOST=0.0.0.0/BLOODHOUND_HOST=127.0.0.1/' .env
        docker-compose restart bloodhound
        
        # Update firewall
        ufw allow 'Nginx Full'
        ufw delete allow 8080/tcp 2>/dev/null || true
        
        log "✅ Self-signed SSL setup complete!"
        echo "🌐 Access BloodHound at: https://$SERVER_NAME"
        warn "⚠️  Browser will show security warning (accept the self-signed certificate)"
        ;;

    3)
        log "Setting up BloodHound Native SSL..."
        
        # Get server details
        read -p "Enter server name/IP (default: $(hostname -I | awk '{print $1}')): " SERVER_NAME
        SERVER_NAME=${SERVER_NAME:-$(hostname -I | awk '{print $1}')}
        
        # Create SSL directory
        mkdir -p "$SSL_DIR"
        
        # Generate certificate
        log "Generating SSL certificate for BloodHound..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SSL_DIR/bloodhound.key" \
            -out "$SSL_DIR/bloodhound.crt" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$SERVER_NAME"
        
        # Create BloodHound SSL configuration
        log "Creating BloodHound SSL configuration..."
        cd "$BLOODHOUND_DIR"
        
        # Create custom BloodHound config
        cat > bloodhound-ssl.config.json << EOF
{
  "version": "v2",
  "server": {
    "bind_addr": "0.0.0.0:8443",
    "tls": {
      "cert_file": "$SSL_DIR/bloodhound.crt",
      "key_file": "$SSL_DIR/bloodhound.key"
    },
    "metrics_port": "2112",
    "read_timeout": "30s",
    "read_header_timeout": "10s",
    "write_timeout": "30s",
    "idle_timeout": "30s",
    "graceful_shutdown_timeout": "30s"
  },
  "logging": {
    "level": "INFO",
    "format": "text"
  }
}
EOF

        # Update docker-compose to use SSL config and port
        cp docker-compose.yml docker-compose.yml.backup
        
        # Modify docker-compose to use SSL
        sed -i 's/8080:8080/8443:8443/' docker-compose.yml
        sed -i '/# volumes:/,/# /{s/# //}' docker-compose.yml
        sed -i 's|./bloodhound.config.json:/bloodhound.config.json:ro|./bloodhound-ssl.config.json:/bloodhound.config.json:ro|' docker-compose.yml
        
        # Restart BloodHound
        docker-compose down
        docker-compose up -d
        
        # Update firewall
        ufw allow 8443/tcp
        ufw delete allow 8080/tcp 2>/dev/null || true
        
        log "✅ BloodHound native SSL setup complete!"
        echo "🌐 Access BloodHound at: https://$SERVER_NAME:8443"
        warn "⚠️  Browser will show security warning (accept the self-signed certificate)"
        ;;

    4)
        log "Setting up Nginx Proxy Manager..."
        
        # Create directory for NPM
        mkdir -p /opt/nginx-proxy-manager
        cd /opt/nginx-proxy-manager
        
        # Create docker-compose for NPM
        cat > docker-compose.yml << 'EOF'
version: '3.8'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF

        # Start NPM
        docker-compose up -d
        
        # Configure BloodHound to localhost only
        cd "$BLOODHOUND_DIR"
        sed -i 's/BLOODHOUND_HOST=0.0.0.0/BLOODHOUND_HOST=127.0.0.1/' .env
        docker-compose restart bloodhound
        
        # Update firewall
        ufw delete allow 8080/tcp 2>/dev/null || true
        
        SERVER_IP=$(hostname -I | awk '{print $1}')
        
        log "✅ Nginx Proxy Manager setup complete!"
        echo ""
        echo "🌐 Access Nginx Proxy Manager at: http://$SERVER_IP:81"
        echo "📋 Default login: admin@example.com / changeme"
        echo ""
        echo "To configure SSL for BloodHound:"
        echo "1. Login to Nginx Proxy Manager"
        echo "2. Add new Proxy Host:"
        echo "   - Domain: your-domain.com"
        echo "   - Forward Hostname/IP: 127.0.0.1"
        echo "   - Forward Port: 8080"
        echo "3. Enable SSL tab and request Let's Encrypt certificate"
        ;;

    5)
        log "Removing SSL configuration..."
        
        # Remove Nginx configuration
        rm -f "$NGINX_ENABLED/bloodhound-ssl"
        rm -f "$NGINX_SITES/bloodhound-ssl"
        
        # Restore BloodHound to external access
        cd "$BLOODHOUND_DIR"
        if [ -f docker-compose.yml.backup ]; then
            mv docker-compose.yml.backup docker-compose.yml
        fi
        sed -i 's/BLOODHOUND_HOST=127.0.0.1/BLOODHOUND_HOST=0.0.0.0/' .env
        docker-compose restart bloodhound
        
        # Restore firewall
        ufw allow 8080/tcp
        ufw delete allow 443/tcp 2>/dev/null || true
        ufw delete allow 8443/tcp 2>/dev/null || true
        
        # Restart nginx if installed
        if systemctl is-active --quiet nginx; then
            systemctl restart nginx
        fi
        
        log "✅ SSL configuration removed"
        echo "🌐 BloodHound is now accessible at: http://$(hostname -I | awk '{print $1}'):8080"
        ;;

    6)
        log "Exiting SSL setup utility"
        exit 0
        ;;

    *)
        error "Invalid option. Please choose 1-6."
        ;;
esac

# Create SSL management script
log "Creating SSL management utility..."
cat > /usr/local/bin/bloodhound-ssl << 'EOF'
#!/bin/bash

# BloodHound SSL Management Utility

BLOODHOUND_DIR="/opt/bloodhound"

case "$1" in
    status)
        echo "🔍 SSL Status Check:"
        echo ""
        
        # Check if Nginx is running
        if systemctl is-active --quiet nginx; then
            echo "✅ Nginx: Running"
            if [ -f /etc/nginx/sites-enabled/bloodhound-ssl ]; then
                echo "✅ SSL Config: Active"
            else
                echo "❌ SSL Config: Not found"
            fi
        else
            echo "❌ Nginx: Not running"
        fi
        
        # Check BloodHound binding
        cd "$BLOODHOUND_DIR" 2>/dev/null || { echo "❌ BloodHound directory not found"; exit 1; }
        if grep -q "BLOODHOUND_HOST=127.0.0.1" .env 2>/dev/null; then
            echo "✅ BloodHound: Secured (localhost only)"
        elif grep -q "BLOODHOUND_HOST=0.0.0.0" .env 2>/dev/null; then
            echo "⚠️  BloodHound: Exposed (all interfaces)"
        else
            echo "❓ BloodHound: Unknown configuration"
        fi
        
        # Check open ports
        echo ""
        echo "🌐 Open Ports:"
        netstat -tlnp | grep -E "(80|443|8080|8443)" || echo "No relevant ports found"
        ;;
        
    renew)
        echo "🔄 Renewing SSL certificates..."
        if command -v certbot &> /dev/null; then
            certbot renew --dry-run
            echo "✅ Certificate renewal test completed"
        else
            echo "❌ Certbot not installed"
        fi
        ;;
        
    logs)
        echo "📋 SSL-related logs:"
        if [ -f /var/log/nginx/bloodhound_error.log ]; then
            echo "Last 10 lines of Nginx error log:"
            tail -10 /var/log/nginx/bloodhound_error.log
        else
            echo "No Nginx logs found"
        fi
        ;;
        
    *)
        echo "Usage: $0 {status|renew|logs}"
        echo ""
        echo "Commands:"
        echo "  status - Check SSL configuration status"
        echo "  renew  - Test SSL certificate renewal"
        echo "  logs   - Show SSL-related logs"
        ;;
esac
EOF

chmod +x /usr/local/bin/bloodhound-ssl

echo ""
echo -e "${GREEN}=================================================================${NC}"
echo -e "${PURPLE}🔒 BloodHound SSL Setup Complete! 🔒${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo ""
echo -e "${CYAN}📋 SSL Management Commands:${NC}"
echo "   bloodhound-ssl status    # Check SSL status"
echo "   bloodhound-ssl renew     # Test certificate renewal"
echo "   bloodhound-ssl logs      # View SSL logs"
echo ""
echo -e "${YELLOW}⚠️  Security Notes:${NC}"
echo "   • Always use strong passwords"
echo "   • Keep SSL certificates updated"
echo "   • Monitor access logs regularly"
echo "   • Consider IP whitelisting for production"
echo ""
echo -e "${GREEN}✅ Your BloodHound instance is now secured with SSL/TLS!${NC}"
echo -e "${GREEN}=================================================================${NC}"
