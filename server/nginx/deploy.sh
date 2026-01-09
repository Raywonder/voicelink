#!/bin/bash
# VoiceLink Nginx Deployment Script
# Run on the server as root or with sudo

set -e

NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
CONFIG_NAME="voicelink.conf"

echo "=== VoiceLink Nginx Setup ==="

# Copy configuration
echo "1. Copying nginx configuration..."
cp voicelink.conf "$NGINX_AVAILABLE/$CONFIG_NAME"

# Enable site
echo "2. Enabling site..."
ln -sf "$NGINX_AVAILABLE/$CONFIG_NAME" "$NGINX_ENABLED/$CONFIG_NAME"

# Test configuration
echo "3. Testing nginx configuration..."
nginx -t

# Check if SSL certs exist, if not generate them
if [ ! -f "/etc/letsencrypt/live/devinecreations.net/fullchain.pem" ]; then
    echo "4. SSL certificate not found. Generate with:"
    echo "   certbot certonly --nginx -d voicelink.devinecreations.net -d voicelink.tappedin.fm"
else
    echo "4. SSL certificate found."
fi

# Reload nginx
echo "5. Reloading nginx..."
systemctl reload nginx

echo ""
echo "=== Setup Complete ==="
echo "VoiceLink should now be accessible at:"
echo "  - https://voicelink.devinecreations.net"
echo "  - https://voicelink.tappedin.fm"
echo ""
echo "Test with: curl -s https://voicelink.devinecreations.net/api/rooms"
