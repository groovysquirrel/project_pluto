# =============================================================================
# Portal - Static Landing Page (nginx)
# =============================================================================
# Simple nginx container serving the Project Pluto portal HTML/CSS/JS
# =============================================================================

FROM nginx:alpine

# Copy portal files
COPY common/portal/html /usr/share/nginx/html
COPY common/portal/nginx.conf /etc/nginx/conf.d/default.conf

# Expose port 80
EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
