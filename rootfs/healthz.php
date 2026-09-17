<?php

/**
 * Anonymous health endpoint for Railway.
 *
 * Railway's prober sends no credentials and `healthcheckPath` accepts no dots, so
 * Shaarli's own routes are unusable: `/` is a 302 once privacy.force_login is on.
 * This proves what actually matters — the volume is mounted, writable, and carries
 * a configuration the bootstrap seeded — rather than merely that PHP answers.
 */

declare(strict_types=1);

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

const DATA_DIR = '/var/www/shaarli/data';
const CONFIG_FILE = DATA_DIR . '/config.json.php';

/** @return string|null the failure reason, or null when healthy */
function shaarli_health(): ?string
{
    if (!is_dir(DATA_DIR)) {
        return 'data directory is missing';
    }
    if (!is_writable(DATA_DIR)) {
        return 'data directory is not writable';
    }
    if (!is_readable(CONFIG_FILE)) {
        return 'configuration file is missing';
    }

    $raw = file_get_contents(CONFIG_FILE);
    if ($raw === false) {
        return 'configuration file is unreadable';
    }

    $json = json_decode(trim(str_replace(['<?php /*', '*/ ?>'], '', $raw)), true);
    if (!is_array($json)) {
        return 'configuration file is not valid JSON';
    }
    if (empty($json['credentials']['hash']) || empty($json['credentials']['login'])) {
        return 'configuration file carries no administrator credential';
    }

    $datastore = DATA_DIR . '/datastore.php';
    if (file_exists($datastore) && !is_readable($datastore)) {
        return 'datastore is not readable';
    }

    return null;
}

$failure = shaarli_health();

if ($failure !== null) {
    http_response_code(503);
    echo 'unhealthy: ' . $failure . "\n";
    exit(1);
}

echo "ok\n";
