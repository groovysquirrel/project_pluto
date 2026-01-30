FROM nginx:alpine

COPY common/portal/html /usr/share/nginx/html

# Custom Nginx config to handle SPA routing if needed (though this is mostly a launcher)
# and ensuring caching headers are set correctly for static assets
# IMPORTANT: large_client_header_buffers handles AWS Cognito JWT tokens in cookies
# which can be 4KB-8KB+ and exceed nginx defaults
RUN echo 'server { \
    listen 80; \
    server_name localhost; \
    large_client_header_buffers 4 32k; \
    client_header_buffer_size 4k; \
    location / { \
        root /usr/share/nginx/html; \
        index index.html; \
        try_files $uri $uri/ /index.html; \
    } \
}' > /etc/nginx/conf.d/default.conf

EXPOSE 80
