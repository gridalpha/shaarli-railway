<?php

/**
 * Seed Shaarli's configuration file so the container never serves the install wizard.
 *
 * Shaarli has no environment-variable configuration path at all, and its admin
 * credential is derived: `sha1(password . login . salt)` against a salt generated at
 * install time. No Railway variable can express that trio, so it is computed here.
 *
 * `InstallController::__construct` throws `AlreadyInstalledException` as soon as
 * `data/config.json.php` exists, so writing this file before the listener opens
 * closes the window in which a stranger could claim the instance on a public URL.
 *
 * Idempotent by construction: it writes nothing when the file already exists, so an
 * operator's later password or settings change in the admin UI survives every deploy.
 */

declare(strict_types=1);

const LANGUAGES = ['auto', 'de', 'en', 'fr', 'jp', 'ru', 'zh_CN'];

function env_str(string $name, string $default = ''): string
{
    $value = getenv($name);

    return ($value === false || $value === '') ? $default : $value;
}

function env_bool(string $name, bool $default): bool
{
    $value = strtolower(trim(env_str($name, $default ? 'true' : 'false')));

    return in_array($value, ['1', 'true', 'yes', 'on'], true);
}

function fail(string $message): void
{
    fwrite(STDERR, '[bootstrap] ' . $message . PHP_EOL);
    exit(1);
}

$configFile = env_str('SHAARLI_CONFIG_FILE', '/var/www/shaarli/data/config.json.php');

if (file_exists($configFile)) {
    fwrite(STDOUT, '[bootstrap] configuration already present, leaving it untouched' . PHP_EOL);
    exit(0);
}

$login = env_str('SHAARLI_USERNAME', 'admin');
$password = env_str('SHAARLI_PASSWORD');

if ($password === '') {
    fail('SHAARLI_PASSWORD is not set. Set it to the password you want for the first administrator.');
}
if (strlen($password) < 8) {
    fail('SHAARLI_PASSWORD must be at least 8 characters.');
}
if (trim($login) === '' || $login !== trim($login)) {
    fail('SHAARLI_USERNAME must not be empty or padded with whitespace.');
}

$timezone = env_str('SHAARLI_TIMEZONE', 'UTC');
if (!in_array($timezone, timezone_identifiers_list(), true)) {
    fwrite(STDOUT, '[bootstrap] unknown timezone "' . $timezone . '", falling back to UTC' . PHP_EOL);
    $timezone = 'UTC';
}

$thumbnails = env_str('SHAARLI_THUMBNAILS_MODE', 'all');
if (!in_array($thumbnails, ['all', 'common', 'none'], true)) {
    fwrite(STDOUT, '[bootstrap] unknown thumbnail mode "' . $thumbnails . '", falling back to all' . PHP_EOL);
    $thumbnails = 'all';
}

$language = env_str('SHAARLI_LANGUAGE', 'auto');
if (!in_array($language, LANGUAGES, true)) {
    fwrite(STDOUT, '[bootstrap] unknown language "' . $language . '", falling back to auto' . PHP_EOL);
    $language = 'auto';
}

// Same construction as Shaarli's own installer, with a CSPRNG in place of uniqid().
$salt = sha1(bin2hex(random_bytes(20)));
$hash = sha1($password . $login . $salt);
$apiSecret = str_shuffle(substr(hash_hmac('sha512', bin2hex(random_bytes(20)), $login), 10, 12));

$config = [
    'credentials' => [
        'login' => $login,
        'salt' => $salt,
        'hash' => $hash,
    ],
    'security' => [
        // Shaarli keys the session on REMOTE_ADDR plus the whole X-Forwarded-For
        // string. nginx collapses both to the true client before PHP sees them, so
        // this protection is usable here and stays on.
        'session_protection_disabled' => env_bool('SHAARLI_SESSION_PROTECTION_DISABLED', false),
        'open_shaarli' => false,
        'ban_after' => (int) env_str('SHAARLI_BAN_AFTER', '4'),
        'ban_duration' => (int) env_str('SHAARLI_BAN_DURATION', '1800'),
    ],
    'general' => [
        'title' => env_str('SHAARLI_TITLE', 'Shaarli'),
        'timezone' => $timezone,
        'header_link' => '/',
        'links_per_page' => 20,
        'retrieve_description' => true,
        'enable_async_metadata' => true,
    ],
    'privacy' => [
        'force_login' => env_bool('SHAARLI_FORCE_LOGIN', false),
        'default_private_links' => env_bool('SHAARLI_DEFAULT_PRIVATE_LINKS', false),
        'hide_public_links' => false,
    ],
    'api' => [
        'enabled' => env_bool('SHAARLI_ENABLE_API', true),
        'secret' => $apiSecret,
    ],
    'updates' => [
        'check_updates' => env_bool('SHAARLI_CHECK_UPDATES', true),
        'check_updates_interval' => 86400,
    ],
    'translation' => [
        'language' => $language,
    ],
    'thumbnails' => [
        'mode' => $thumbnails,
    ],
    'resource' => [
        // The one path that has to move: upstream puts the thumbnail cache in a
        // second volume, and Railway allows a service only one.
        'thumbnails_cache' => env_str('SHAARLI_THUMBNAILS_DIR', '/var/www/shaarli/data/.cache/thumbnails'),
    ],
];

$payload = '<?php /*' . json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . '*/ ?>';

$directory = dirname($configFile);
if (!is_dir($directory) && !mkdir($directory, 0o750, true)) {
    fail('could not create ' . $directory);
}

// Written with an exclusive create so two containers racing a first deploy cannot
// both claim the instance with different salts.
$handle = @fopen($configFile, 'xb');
if ($handle === false) {
    fwrite(STDOUT, '[bootstrap] configuration appeared concurrently, leaving it untouched' . PHP_EOL);
    exit(0);
}
if (fwrite($handle, $payload) === false) {
    fclose($handle);
    fail('could not write ' . $configFile);
}
fclose($handle);
chmod($configFile, 0o640);

fwrite(STDOUT, '[bootstrap] seeded configuration for administrator "' . $login . '"' . PHP_EOL);
