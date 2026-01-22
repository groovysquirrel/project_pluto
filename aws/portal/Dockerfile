FROM nginx:alpine

COPY common/portal/html /usr/share/nginx/html

# Custom Nginx config to handle SPA routing if needed (though this is mostly a launcher)
# and ensuring caching headers are set correctly for static assets
RUN echo 'server { \
    listen 80; \
    server_name localhost; \
    location / { \
        root /usr/share/nginx/html; \
        index index.html; \
        try_files $uri $uri/ /index.html; \
    } \
}' > /etc/nginx/conf.d/default.conf

EXPOSE 80
