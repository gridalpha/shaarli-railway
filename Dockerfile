# Shaarli on Railway — one layer on top of the official image.
#
# `release` is upstream's floating alias for the newest release. `latest` is NOT the
# stable line here: .github/workflows/docker-latest.yml pushes it on every commit to
# master, with the version string replaced by the commit hash.
FROM ghcr.io/shaarli/shaarli:release

USER root

# headers-more rewrites the *request* header X-Forwarded-For, which no fastcgi_param
# can: nginx sends configured params before the auto-generated HTTP_* ones, so the
# original header always wins. Shaarli's session protection hashes that whole string.
RUN set -eux; \
    apk add --no-cache nginx-mod-http-headers-more; \
    mkdir -p /var/lib/shaarli /usr/local/share/shaarli

# Hand PHP the real client and the forwarded scheme. REMOTE_ADDR is what Shaarli's
# ban manager keys on and what $_SERVER['HTTPS'] decides the Secure cookie flag from;
# both are wrong behind Railway's edge until these two lines are rewritten.
RUN set -eux; \
    for f in /etc/nginx/fastcgi.conf /etc/nginx/fastcgi_params; do \
        sed -i -E 's|^([[:space:]]*fastcgi_param[[:space:]]+REMOTE_ADDR[[:space:]]+).*$|\1$real_client_ip;|' "$f"; \
        sed -i -E 's|^([[:space:]]*fastcgi_param[[:space:]]+HTTPS[[:space:]]+).*$|\1$https_flag if_not_empty;|' "$f"; \
    done; \
    grep -q 'REMOTE_ADDR *\$real_client_ip;' /etc/nginx/fastcgi.conf; \
    grep -q 'HTTPS *\$https_flag if_not_empty;' /etc/nginx/fastcgi.conf; \
    sed -E 's|^([[:space:]]*fastcgi_param[[:space:]]+SCRIPT_FILENAME[[:space:]]+).*$|\1/var/www/shaarli/healthz.php;|' \
        /etc/nginx/fastcgi.conf > /etc/nginx/fastcgi_healthz.conf; \
    grep -q 'SCRIPT_FILENAME */var/www/shaarli/healthz.php;' /etc/nginx/fastcgi_healthz.conf

# php-fpm's own error log defaults to a file nobody reads, so a fatal in the master
# never reaches `railway logs`. The pool already sets catch_workers_output.
RUN set -eux; \
    sed -i 's|^\[global\]$|[global]\nerror_log = /proc/self/fd/2|' /etc/php84/php-fpm.conf; \
    grep -q '^error_log = /proc/self/fd/2' /etc/php84/php-fpm.conf; \
    sed -i 's/^post_max_size.*/post_max_size = 100M/' /etc/php84/php.ini; \
    sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/' /etc/php84/php.ini; \
    grep -q '^upload_max_filesize = 100M' /etc/php84/php.ini; \
    php-fpm84 -t

# Shaarli calls the legacy three-argument session_set_cookie_params(), which leaves
# `secure` and `httponly` at their ini values — so these three lines do reach the
# session cookie. Railway's edge always serves the browser HTTPS.
RUN set -eux; \
    printf 'session.cookie_httponly = 1\nsession.cookie_secure = 1\nsession.cookie_samesite = Lax\n' \
        > /etc/php84/conf.d/99-railway-cookies.ini

# The stay-signed-in cookie is a year-long authentication token set through the
# four-argument setcookie(), which no ini value reaches. One line, and the grep makes
# the build fail — rather than the deployment silently regress — if upstream moves it.
RUN set -eux; \
    f=/var/www/shaarli/application/security/CookieManager.php; \
    test "$(grep -c 'setcookie(\$key, \$value, \$expires, \$path);' "$f")" = 1; \
    sed -i "s|setcookie(\$key, \$value, \$expires, \$path);|setcookie(\$key, \$value, ['expires' => \$expires, 'path' => \$path, 'secure' => true, 'httponly' => true, 'samesite' => 'Lax']);|" "$f"; \
    grep -q "'httponly' => true" "$f"; \
    php84 -l "$f"

COPY rootfs/s6/SIGTERM          /etc/services.d/.s6-svscan/SIGTERM
COPY rootfs/nginx.conf.template /etc/nginx/nginx.conf.template
COPY rootfs/bootstrap.php       /usr/local/share/shaarli/bootstrap.php
COPY rootfs/healthz.php         /var/www/shaarli/healthz.php
COPY rootfs/entrypoint.sh       /usr/local/bin/entrypoint.sh

# Fail the build, not a container, on a syntax error or a bad nginx directive.
RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh /etc/services.d/.s6-svscan/SIGTERM; \
    sh -n /etc/services.d/.s6-svscan/SIGTERM; \
    chown nginx:nginx /var/www/shaarli/healthz.php; \
    sh -n /usr/local/bin/entrypoint.sh; \
    php84 -l /usr/local/share/shaarli/bootstrap.php; \
    php84 -l /var/www/shaarli/healthz.php; \
    sed 's|${PORT}|8080|g' /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf; \
    nginx -t; \
    rm -f /etc/nginx/nginx.conf /var/run/nginx.pid

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
