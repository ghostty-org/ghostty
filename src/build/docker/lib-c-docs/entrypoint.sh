#!/bin/sh
if [ "$ADD_NOINDEX_HEADER" = "true" ]; then
    cat > /etc/nginx/conf.d/noindex.conf << 'EOF'
server {
    listen 80;
    location / {
        root /usr/share/nginx/html;
        index index.html;
        etag on;
        add_header Cache-Control "no-cache" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;" always;
    }
}
EOF
    # Remove default server config
    rm -f /etc/nginx/conf.d/default.conf
else
    cat > /etc/nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    location / {
        root /usr/share/nginx/html;
        index index.html;
        etag on;
        add_header Cache-Control "no-cache" always;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;" always;
    }
}
EOF
fi
exec nginx -g "daemon off;"
