<?php
/**
 * nginx auth_request target for /rosbridge.
 * Always returns 200 so guests can open a read-only telemetry socket.
 * X-Robot-Writer is 1 only when the dashboard session is logged in.
 */
if (session_status() !== PHP_SESSION_ACTIVE) {
    session_start();
}
$logged_in = !empty($_SESSION['USER_LOGGED']);
header('X-Robot-Writer: ' . ($logged_in ? '1' : '0'));
header('Cache-Control: no-store');
http_response_code(200);
header('Content-Length: 0');
